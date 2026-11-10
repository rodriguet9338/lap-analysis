// XRKStream.swift - the streaming scanner: finds data messages ((G (S (M (c)
// and header messages (<h), accumulates raw samples per channel/group, then
// decodes them to millisecond timecodes and Double values.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Port of crates/libxrk/src/parser.rs (prescan, scan_stream, try_parse_*,
// resolve_c_variants, finalize, decode_all_channels).
//
// Differences from the reference, all in the direction of not failing:
// - Nested CNF/ENF containers are followed at most `maxDepth` levels deep.
// - A channel that has both S/c and M data uses the S/c data (the Cython
//   backend's behaviour) instead of failing the whole file (Rust backend).
// - If a row's sample bytes run past the end of the accumulated buffer, the
//   channel stops at that row so times and values always have equal counts.

import Foundation

/// Raw per-channel (or per-group) accumulator.
struct XRKAccum {
    var lastTimecode: Int32 = -1
    /// Message size for G/S/c (data size + framing), sample size for M.
    var addHelper: Int = 1
    /// M-message sample period, ms.
    var mms: UInt32 = 0
    /// G/S: tc(4)+index(2)+data rows. c: tc(4)+data rows. M: packed samples.
    var data: [UInt8] = []
    /// M-message timecodes (one per sample).
    var timecodes: [Int32] = []
}

struct XRKChannelInfo {
    var def: XRKChannelDef
    var groupIndex: UInt16?
    var groupOffset: Int?
}

/// One buffered V2/V3 (c)-message sample awaiting channel resolution.
struct XRKVariantSample {
    let timecode: Int32
    let b0: UInt8
    let b1: UInt8
    let priority: UInt8
}

/// A decoded CHS channel: ms timecodes relative to the session start.
struct XRKDecodedChannel {
    var timecodes: [Int64]
    var values: [Double]
}

final class XRKStreamState {
    static let maxDepth: Int = 8

    // [0] G (groups), [1] S, [2] c (expansion), [3] M
    var gAcc: [XRKAccum] = []
    var sAcc: [XRKAccum] = []
    var cAcc: [XRKAccum] = []
    var mAcc: [XRKAccum] = []

    var channels: [UInt16: XRKChannelInfo] = [:]
    var groups: [UInt16: XRKGroupDef] = [:]
    var channelSizes: [UInt16: UInt8] = [:]
    var messages: [UInt32: [XRKMessage]] = [:]
    var gpsData: [UInt8] = []
    var gnfiData: [UInt8] = []
    var lapTimeOffset: Int64? = nil
    var lapLastTime: Int64? = nil
    /// Header messages of each ENF (expansion device) container, in file order.
    var enfMessages: [[UInt32: [XRKMessage]]] = []

    var variantSamples: [UInt16: [XRKVariantSample]] = [:]
    var lastV2Base: [UInt16: (Int32, UInt32)] = [:]
    var lastV2Plus4: [UInt16: (Int32, UInt32)] = [:]
    var variantPosition: UInt32 = 0

    /// Number of header messages accepted by the main scan (for format detection).
    var headerCount: Int = 0

    init() {}

    // MARK: - Registration

    private static func ensure(_ arr: inout [XRKAccum], _ idx: Int) {
        if arr.count <= idx {
            arr.reserveCapacity(idx + 1)
            while arr.count <= idx {
                arr.append(XRKAccum())
            }
        }
    }

    func registerChannel(_ def: XRKChannelDef) {
        let idx: Int = Int(def.index)
        // A later re-definition wins on names only.
        if var existing = channels[def.index] {
            existing.def.shortName = def.shortName
            existing.def.longName = def.longName
            channels[def.index] = existing
        }
        channelSizes[def.index] = def.dataSize
        let size: Int = Int(def.dataSize)
        XRKStreamState.ensure(&sAcc, idx)
        sAcc[idx].addHelper = size + 9
        XRKStreamState.ensure(&cAcc, idx)
        cAcc[idx].addHelper = size + 12
        XRKStreamState.ensure(&mAcc, idx)
        mAcc[idx].addHelper = size
        mAcc[idx].mms = def.mms
        if channels[def.index] == nil {
            channels[def.index] = XRKChannelInfo(def: def, groupIndex: nil, groupOffset: nil)
        }
    }

    func registerGroup(_ grp: XRKGroupDef) {
        let idx: Int = Int(grp.index)
        var size: Int = 0
        for ch in grp.channelIndices {
            size += Int(channelSizes[ch] ?? 0)
        }
        XRKStreamState.ensure(&gAcc, idx)
        gAcc[idx].addHelper = 9 + size
        var offset: Int = 6
        for ch in grp.channelIndices {
            if var info = channels[ch] {
                info.groupIndex = grp.index
                info.groupOffset = offset
                offset += Int(info.def.dataSize)
                channels[ch] = info
            }
        }
        groups[grp.index] = grp
    }

    // MARK: - Prescan

    /// First pass: learn channel/group layout from header messages so data
    /// messages can be framed even if they precede their definitions, and
    /// reserve accumulator capacity.
    func prescan(_ b: [UInt8], _ start: Int, _ end: Int) {
        var dataBytes: [[Int]] = [[], [], [], []]
        var mCounts: [Int] = []
        var gpsBytes: Int = 0
        var gnfiBytes: Int = 0

        func addBytes(_ cat: Int, _ idx: Int, _ n: Int) {
            if dataBytes[cat].count <= idx {
                dataBytes[cat].append(contentsOf: [Int](repeating: 0, count: idx + 1 - dataBytes[cat].count))
            }
            dataBytes[cat][idx] += n
        }

        var pos: Int = start
        while pos < end {
            if pos + 3 > end {
                pos += 1
                continue
            }
            let op0: UInt8 = b[pos]
            let op1: UInt8 = b[pos + 1]
            if op0 == 0x28 { // '('
                if op1 == 0x47 || op1 == 0x53 { // 'G' / 'S'
                    let isG: Bool = op1 == 0x47
                    if pos + 9 <= end {
                        let index: Int = Int(xrkU16(b, pos + 6))
                        let count: Int = isG ? gAcc.count : sAcc.count
                        if index < count {
                            let total: Int = isG ? gAcc[index].addHelper : sAcc[index].addHelper
                            if total > 3 && pos + total <= end && b[pos + total - 1] == 0x29 {
                                addBytes(isG ? 0 : 1, index, total - 3)
                                pos += total
                                continue
                            }
                        }
                    }
                } else if op1 == 0x4D { // 'M'
                    if pos + 11 <= end {
                        let index: Int = Int(xrkU16(b, pos + 6))
                        let count: Int = Int(xrkU16(b, pos + 8))
                        if index < mAcc.count {
                            let sampleSize: Int = mAcc[index].addHelper
                            let mms: UInt32 = mAcc[index].mms
                            if mms > 0 && sampleSize > 0 {
                                let total: Int = 10 + sampleSize * count + 1
                                if pos + total <= end && b[pos + total - 1] == 0x29 {
                                    addBytes(3, index, sampleSize * count)
                                    if mCounts.count <= index {
                                        mCounts.append(contentsOf: [Int](repeating: 0, count: index + 1 - mCounts.count))
                                    }
                                    mCounts[index] += count
                                    pos += total
                                    continue
                                }
                            }
                        }
                    }
                } else if op1 == 0x63 { // 'c'
                    if pos + 7 <= end {
                        let unk1: UInt8 = b[pos + 2]
                        let field: UInt16 = xrkU16(b, pos + 3)
                        let unk3: UInt8 = b[pos + 5]
                        let unk4: UInt8 = b[pos + 6]
                        if unk3 == 0x84 {
                            if unk1 == 0 && unk4 == 6 && (field & 7) == 4 {
                                let index: Int = Int(field >> 3)
                                if index < cAcc.count {
                                    let total: Int = cAcc[index].addHelper
                                    if total > 8 && pos + total <= end && b[pos + total - 1] == 0x29 {
                                        addBytes(2, index, total - 8)
                                        pos += total
                                        continue
                                    }
                                }
                            }
                            if unk1 == 0 && unk4 == 8 && pos + 16 <= end && b[pos + 15] == 0x29 {
                                pos += 16
                                continue
                            }
                            if unk1 == 1 && unk4 == 2 && pos + 10 <= end && b[pos + 9] == 0x29 {
                                pos += 10
                                continue
                            }
                        }
                    }
                }
            } else if op0 == 0x3C && op1 == 0x68 { // "<h"
                if let frame = XRKFraming.parseHeader(b, pos, end) {
                    prescanHeader(b, frame, &gpsBytes, &gnfiBytes)
                    pos += frame.consumed
                    continue
                }
            }
            pos += 1
        }

        // Capacity hints (over-counting is harmless).
        let cats: Int = 4
        var cat: Int = 0
        while cat < cats {
            let hints: [Int] = dataBytes[cat]
            var idx: Int = 0
            while idx < hints.count {
                let n: Int = hints[idx]
                if n > 0 {
                    switch cat {
                    case 0: if idx < gAcc.count { gAcc[idx].data.reserveCapacity(n) }
                    case 1: if idx < sAcc.count { sAcc[idx].data.reserveCapacity(n) }
                    case 2: if idx < cAcc.count { cAcc[idx].data.reserveCapacity(n) }
                    default: if idx < mAcc.count { mAcc[idx].data.reserveCapacity(n) }
                    }
                }
                idx += 1
            }
            cat += 1
        }
        var idx: Int = 0
        while idx < mCounts.count {
            if mCounts[idx] > 0 && idx < mAcc.count {
                mAcc[idx].timecodes.reserveCapacity(mCounts[idx])
            }
            idx += 1
        }
        gpsData.reserveCapacity(gpsBytes)
        gnfiData.reserveCapacity(gnfiBytes)
    }

    private func prescanHeader(_ b: [UInt8], _ frame: XRKHeaderFrame, _ gpsBytes: inout Int, _ gnfiBytes: inout Int) {
        let token: UInt32 = frame.token
        if token == XRKTok.gps || token == XRKTok.gps1 {
            gpsBytes += frame.payloadEnd - frame.payloadStart
            return
        }
        if token == XRKTok.gnfi {
            gnfiBytes += frame.payloadEnd - frame.payloadStart
            return
        }
        if token == XRKTok.cnf {
            let sub: XRKStreamState = XRKStreamState()
            sub.scan(b, frame.payloadStart, frame.payloadEnd, depth: 1)
            for key in sub.channels.keys.sorted() {
                if channels[key] == nil, let info = sub.channels[key] {
                    registerChannel(info.def)
                }
            }
            for key in sub.groups.keys.sorted() {
                if groups[key] == nil, let grp = sub.groups[key] {
                    registerGroup(grp)
                }
            }
            return
        }
        if token == XRKTok.chs {
            if let def = XRKChannelDef(b, frame.payloadStart, frame.payloadEnd) {
                registerChannel(def)
            }
        } else if token == XRKTok.grp {
            if let grp = XRKGroupDef(b, frame.payloadStart, frame.payloadEnd) {
                registerGroup(grp)
            }
        }
    }

    // MARK: - Main scan

    func scan(_ b: [UInt8], _ start: Int, _ end: Int, depth: Int) {
        var pos: Int = start
        while pos < end {
            if pos + 3 > end {
                pos += 1
                continue
            }
            let op0: UInt8 = b[pos]
            let op1: UInt8 = b[pos + 1]
            var consumed: Int = 0
            if op0 == 0x28 { // '('
                switch op1 {
                case 0x47: consumed = XRKStreamState.parseFixed(b, pos, end, &gAcc)   // G
                case 0x53: consumed = XRKStreamState.parseFixed(b, pos, end, &sAcc)   // S
                case 0x4D: consumed = XRKStreamState.parseM(b, pos, end, &mAcc)       // M
                case 0x63: consumed = parseC(b, pos, end)                             // c
                default: consumed = 0
                }
            } else if op0 == 0x3C && op1 == 0x68 { // "<h"
                if let frame = XRKFraming.parseHeader(b, pos, end) {
                    handleHeader(b, frame, depth: depth)
                    consumed = frame.consumed
                }
            }
            // Unrecognised byte: resynchronise one byte at a time.
            pos += consumed > 0 ? consumed : 1
        }
    }

    /// (G and (S messages: "(" op tc:i32 index:u16 data ")" with a size fixed per index.
    private static func parseFixed(_ b: [UInt8], _ pos: Int, _ end: Int, _ accs: inout [XRKAccum]) -> Int {
        if pos + 9 > end { return 0 }
        let timecode: Int32 = xrkI32(b, pos + 2)
        let index: Int = Int(xrkU16(b, pos + 6))
        if index >= accs.count { return 0 }
        let total: Int = accs[index].addHelper
        if total < 3 || pos + total > end { return 0 }
        if b[pos + total - 1] != 0x29 { return 0 }
        if timecode > accs[index].lastTimecode {
            accs[index].lastTimecode = timecode
            accs[index].data.append(contentsOf: b[(pos + 2)..<(pos + total - 1)])
        }
        return total
    }

    /// (M messages: "(M" tc:i32 index:u16 count:u16 samples ")"; sample i is at tc + i*mms.
    private static func parseM(_ b: [UInt8], _ pos: Int, _ end: Int, _ accs: inout [XRKAccum]) -> Int {
        if pos + 11 > end { return 0 }
        let timecode: Int32 = xrkI32(b, pos + 2)
        let index: Int = Int(xrkU16(b, pos + 6))
        let count: Int = Int(xrkU16(b, pos + 8))
        if index >= accs.count { return 0 }
        let sampleSize: Int = accs[index].addHelper
        let mms: UInt32 = accs[index].mms
        if mms == 0 { return 0 }
        let total: Int = 10 + sampleSize * count + 1
        if pos + total > end { return 0 }
        if b[pos + total - 1] != 0x29 { return 0 }

        let last: Int32 = accs[index].lastTimecode
        var skip: Int = 0
        if timecode <= last {
            let diff: Int64 = Int64(last) - Int64(timecode)
            skip = Int(diff / Int64(mms)) + 1
        }
        if skip < count {
            let tc64: Int64 = Int64(timecode)
            let mms64: Int64 = Int64(mms)
            accs[index].lastTimecode = Int32(truncatingIfNeeded: tc64 + Int64(count - 1) * mms64)
            var m: Int = skip
            while m < count {
                accs[index].timecodes.append(Int32(truncatingIfNeeded: tc64 + Int64(m) * mms64))
                m += 1
            }
            let dataStart: Int = pos + 10 + skip * sampleSize
            let dataEnd: Int = pos + 10 + count * sampleSize
            if dataEnd > dataStart {
                accs[index].data.append(contentsOf: b[dataStart..<dataEnd])
            }
        }
        return total
    }

    /// (c expansion messages: three variants keyed on (unk1, unk4).
    private func parseC(_ b: [UInt8], _ pos: Int, _ end: Int) -> Int {
        if pos + 7 > end { return 0 }
        let unk1: UInt8 = b[pos + 2]
        let field: UInt16 = xrkU16(b, pos + 3)
        let unk3: UInt8 = b[pos + 5]
        let unk4: UInt8 = b[pos + 6]
        if unk3 != 0x84 { return 0 }

        if unk1 == 0 && unk4 == 6 {
            // V1: CHS-sized payload, channel index = field >> 3.
            if pos + 12 > end { return 0 }
            if (field & 7) != 4 { return 0 }
            let timecode: Int32 = xrkI32(b, pos + 7)
            let index: Int = Int(field >> 3)
            if index >= cAcc.count { return 0 }
            let total: Int = cAcc[index].addHelper
            if total < 12 || pos + total > end { return 0 }
            if b[pos + total - 1] != 0x29 { return 0 }
            if timecode > cAcc[index].lastTimecode {
                cAcc[index].lastTimecode = timecode
                cAcc[index].data.append(contentsOf: b[(pos + 7)..<(pos + total - 1)])
            }
            return total
        }

        if unk1 == 0 && unk4 == 8 {
            // V2 long: 16 bytes, two fp16 samples.
            //   base field (low nibble 0/8): samples at (tc, tc-4), priority 3
            //   +4 field   (low nibble 4/c): samples at (tc-2, tc-4), priority 1
            if pos + 16 > end || b[pos + 15] != 0x29 { return 0 }
            let timecode: Int32 = xrkI32(b, pos + 7)
            let low: UInt16 = field & 0xF
            let order: UInt32 = variantPosition
            variantPosition = variantPosition &+ 1
            // `[key, default:]` mutates in place (no copy of the per-field list).
            if low == 0 || low == 8 {
                variantSamples[field, default: []].append(
                    XRKVariantSample(timecode: timecode, b0: b[pos + 11], b1: b[pos + 12], priority: 3))
                variantSamples[field, default: []].append(
                    XRKVariantSample(timecode: timecode &- 4, b0: b[pos + 13], b1: b[pos + 14], priority: 3))
                lastV2Base[field] = (timecode, order)
            } else {
                variantSamples[field, default: []].append(
                    XRKVariantSample(timecode: timecode &- 2, b0: b[pos + 11], b1: b[pos + 12], priority: 1))
                variantSamples[field, default: []].append(
                    XRKVariantSample(timecode: timecode &- 4, b0: b[pos + 13], b1: b[pos + 14], priority: 1))
                lastV2Plus4[field] = (timecode, order)
            }
            return 16
        }

        if unk1 == 1 && unk4 == 2 {
            // V3 short: 10 bytes, one fp16 sample, timecode synthesised from
            // the most recent V2 on the same pair (in file order).
            if pos + 10 > end || b[pos + 9] != 0x29 { return 0 }
            let baseEntry: (Int32, UInt32)? = lastV2Base[field ^ 0x4]
            let plus4Entry: (Int32, UInt32)? = lastV2Plus4[field]
            var synth: Int32? = nil
            if let be = baseEntry, let pe = plus4Entry {
                synth = be.1 >= pe.1 ? (be.0 &- 2) : (pe.0 &+ 2)
            } else if let be = baseEntry {
                synth = be.0 &- 2
            } else if let pe = plus4Entry {
                synth = pe.0 &+ 2
            }
            if let tc = synth {
                variantSamples[field, default: []].append(
                    XRKVariantSample(timecode: tc, b0: b[pos + 7], b1: b[pos + 8], priority: 2))
            }
            variantPosition = variantPosition &+ 1
            return 10
        }

        // Unknown variant: let the resync logic skip it byte by byte.
        return 0
    }

    // MARK: - Header messages

    private func handleHeader(_ b: [UInt8], _ frame: XRKHeaderFrame, depth: Int) {
        headerCount += 1
        let token: UInt32 = frame.token

        if token == XRKTok.gps || token == XRKTok.gps1 {
            gpsData.append(contentsOf: b[frame.payloadStart..<frame.payloadEnd])
            return
        }
        if token == XRKTok.gnfi {
            gnfiData.append(contentsOf: b[frame.payloadStart..<frame.payloadEnd])
            return
        }
        if token == XRKTok.cnf {
            // Timecodes may restart across CNF boundaries.
            XRKStreamState.resetLastTimecodes(&gAcc)
            XRKStreamState.resetLastTimecodes(&sAcc)
            XRKStreamState.resetLastTimecodes(&cAcc)
            XRKStreamState.resetLastTimecodes(&mAcc)
            if depth >= XRKStreamState.maxDepth { return }
            let sub: XRKStreamState = XRKStreamState()
            sub.scan(b, frame.payloadStart, frame.payloadEnd, depth: depth + 1)
            for key in sub.channels.keys.sorted() {
                guard let info = sub.channels[key] else { continue }
                if var existing = channels[key] {
                    existing.def.shortName = info.def.shortName
                    existing.def.longName = info.def.longName
                    channels[key] = existing
                } else {
                    registerChannel(info.def)
                }
            }
            for key in sub.groups.keys.sorted() {
                if groups[key] == nil, let grp = sub.groups[key] {
                    registerGroup(grp)
                }
            }
            // Other messages inside CNF are discarded, as in libxrk.
            return
        }
        if token == XRKTok.enf {
            if depth >= XRKStreamState.maxDepth { return }
            let sub: XRKStreamState = XRKStreamState()
            sub.scan(b, frame.payloadStart, frame.payloadEnd, depth: depth + 1)
            enfMessages.append(sub.messages)
            return
        }

        let payload: [UInt8] = Array(b[frame.payloadStart..<frame.payloadEnd])

        if token == XRKTok.chs {
            if let def = XRKChannelDef(payload, 0, payload.count) {
                registerChannel(def)
            }
        } else if token == XRKTok.grp {
            if let grp = XRKGroupDef(payload, 0, payload.count) {
                registerGroup(grp)
            }
        } else if token == XRKTok.lap {
            if let lap = XRKLapRecord(payload) {
                if lapTimeOffset == nil {
                    lapTimeOffset = Int64(lap.endTime) - Int64(lap.duration)
                }
                lapLastTime = Int64(lap.endTime)
            }
        } else if token == XRKTok.src {
            // SRC embeds an idn payload; libxrk also files it under "idn".
            if XRKIdentity.embedded(payload, minimumLength: 62) != nil {
                let idnPayload: [UInt8] = Array(payload[6...])
                appendMessage(XRKMessage(token: XRKTok.idn, version: frame.version, payload: idnPayload))
            }
        }

        appendMessage(XRKMessage(token: token, version: frame.version, payload: payload))
    }

    private func appendMessage(_ msg: XRKMessage) {
        if messages[msg.token] == nil {
            messages[msg.token] = [msg]
        } else {
            messages[msg.token]?.append(msg)
        }
    }

    private static func resetLastTimecodes(_ arr: inout [XRKAccum]) {
        var i: Int = 0
        while i < arr.count {
            arr[i].lastTimecode = -1
            i += 1
        }
    }

    // MARK: - V2/V3 expansion resolution

    /// Map V2/V3 channel fields to CHS channels and migrate their samples into
    /// the c accumulators (same tc(4)+data(2) row layout as V1).
    func resolveCVariants() {
        if variantSamples.isEmpty { return }

        // Phase 1: partition observed fields into (base, base|4) pairs and orphans.
        let fields: [UInt16] = variantSamples.keys.sorted()
        let fieldSet: Set<UInt16> = Set(fields)
        var pairs: [(UInt16, UInt16)] = []
        var orphans: [UInt16] = []
        var processed: Set<UInt16> = []
        for cf in fields {
            if processed.contains(cf) { continue }
            let low: UInt16 = cf & 0xF
            if (low == 0x0 || low == 0x8) && fieldSet.contains(cf | 0x4) {
                pairs.append((cf, cf | 0x4))
                processed.insert(cf)
                processed.insert(cf | 0x4)
            } else if (low == 0x4 || low == 0xC) && fieldSet.contains(cf & ~UInt16(0x4)) {
                continue
            } else {
                orphans.append(cf)
                processed.insert(cf)
            }
        }

        // Phase 2: CHS candidates (expansion fp16 channels with a hardware id),
        // split by sample period, sorted by (hardware_ref, source_channel_id, index).
        var paired: [(UInt32, UInt16, UInt16)] = []
        var orphanCandidates: [(UInt32, UInt16, UInt16)] = []
        for key in channels.keys.sorted() {
            guard let info = channels[key] else { continue }
            let def: XRKChannelDef = info.def
            if def.decoderType != 20 || def.sourceType != 1 || def.hardwareID == 0 { continue }
            let mms: UInt32 = def.mms
            let entry: (UInt32, UInt16, UInt16) = (def.hardwareRef, def.sourceChannelID, key)
            if mms <= 5 {
                paired.append(entry)
            } else if mms <= 15 {
                orphanCandidates.append(entry)
            }
        }
        let tupleLess: ((UInt32, UInt16, UInt16), (UInt32, UInt16, UInt16)) -> Bool = { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.2 < b.2
        }
        paired.sort(by: tupleLess)
        orphanCandidates.sort(by: tupleLess)

        // Phase 3: field -> channel index.
        var fieldToChannel: [UInt16: UInt16] = [:]
        var i: Int = 0
        while i < pairs.count && i < paired.count {
            fieldToChannel[pairs[i].0] = paired[i].2
            fieldToChannel[pairs[i].1] = paired[i].2
            i += 1
        }
        i = 0
        while i < orphans.count && i < orphanCandidates.count {
            fieldToChannel[orphans[i]] = orphanCandidates[i].2
            i += 1
        }

        // Phase 4: per-channel samples; higher priority wins on a timecode
        // collision, first seen wins on a tie.
        var perChannel: [UInt16: [Int32: XRKVariantSample]] = [:]
        for cf in fields {
            guard let ch = fieldToChannel[cf], let entries = variantSamples[cf] else { continue }
            var bucket: [Int32: XRKVariantSample] = perChannel[ch] ?? [:]
            for s in entries {
                if let existing = bucket[s.timecode] {
                    if s.priority > existing.priority {
                        bucket[s.timecode] = s
                    }
                } else {
                    bucket[s.timecode] = s
                }
            }
            perChannel[ch] = bucket
        }

        // Phase 5: migrate in strictly increasing timecode order.
        for ch in perChannel.keys.sorted() {
            let idx: Int = Int(ch)
            guard idx < cAcc.count, let bucket = perChannel[ch] else { continue }
            for tc in bucket.keys.sorted() {
                guard let s = bucket[tc] else { continue }
                if tc <= cAcc[idx].lastTimecode { continue }
                cAcc[idx].lastTimecode = tc
                xrkAppendI32(tc, to: &cAcc[idx].data)
                cAcc[idx].data.append(s.b0)
                cAcc[idx].data.append(s.b1)
            }
        }
        variantSamples = [:]
    }

    // MARK: - Finalize

    /// Session time offset: the earliest of the first LAP start and the first
    /// timecode of every accumulator and of the GPS stream.
    func computeTimeOffset() -> Int64 {
        var best: Int64? = lapTimeOffset
        func consider(_ v: Int64) {
            if let cur = best {
                if v < cur { best = v }
            } else {
                best = v
            }
        }
        let fixedCats: [([XRKAccum], Int)] = [(gAcc, 3), (sAcc, 3), (cAcc, 8)]
        for (accs, overhead) in fixedCats {
            for acc in accs where !acc.data.isEmpty {
                let stride: Int = acc.addHelper - overhead
                if stride <= 0 { continue }
                if acc.data.count >= 4 {
                    consider(Int64(xrkI32(acc.data, 0)))
                }
            }
        }
        for acc in mAcc {
            if let first = acc.timecodes.first {
                consider(Int64(first))
            }
        }
        if gpsData.count >= 56 {
            consider(Int64(xrkI32(gpsData, 0)))
        }
        return best ?? 0
    }

    /// Decode every CHS channel that has samples. Keyed by channel index.
    func decodeChannels(timeOffset: Int64) -> [UInt16: XRKDecodedChannel] {
        var result: [UInt16: XRKDecodedChannel] = [:]
        for key in channels.keys.sorted() {
            guard let info = channels[key] else { continue }
            let def: XRKChannelDef = info.def
            let name: String = def.longName
            if XRKTables.isHiddenChannel(name) { continue }
            let manual: Bool = XRKTables.isManualDecoder(name)
            let decoder: XRKTables.DecoderInfo? = XRKTables.decoderInfo(def.decoderType)
            if !manual && decoder == nil { continue }
            let sampleSize: Int = manual ? 8 : (decoder?.byteSize ?? 0)
            if sampleSize <= 0 { continue }
            let isVolts: Bool = def.units == "V"

            var decoded: XRKDecodedChannel? = nil
            if let gIdx = info.groupIndex {
                let g: Int = Int(gIdx)
                if groups[gIdx] != nil && g < gAcc.count && !gAcc[g].data.isEmpty {
                    let offset: Int = info.groupOffset ?? 6
                    decoded = XRKStreamState.decodeRows(gAcc[g].data, stride: gAcc[g].addHelper - 3,
                                                        valueOffset: offset, sampleSize: sampleSize,
                                                        decoder: decoder, manual: manual,
                                                        isVolts: isVolts,
                                                        timeOffset: timeOffset)
                }
            } else {
                let idx: Int = Int(key)
                if idx < sAcc.count && !sAcc[idx].data.isEmpty {
                    decoded = XRKStreamState.decodeRows(sAcc[idx].data, stride: sAcc[idx].addHelper - 3,
                                                        valueOffset: 6, sampleSize: sampleSize,
                                                        decoder: decoder, manual: manual,
                                                        isVolts: isVolts,
                                                        timeOffset: timeOffset)
                } else if idx < cAcc.count && !cAcc[idx].data.isEmpty {
                    decoded = XRKStreamState.decodeRows(cAcc[idx].data, stride: cAcc[idx].addHelper - 8,
                                                        valueOffset: 4, sampleSize: sampleSize,
                                                        decoder: decoder, manual: manual,
                                                        isVolts: isVolts,
                                                        timeOffset: timeOffset)
                } else if idx < mAcc.count && !mAcc[idx].timecodes.isEmpty {
                    decoded = XRKStreamState.decodeM(mAcc[idx], sampleSize: sampleSize,
                                                     decoder: decoder, manual: manual,
                                                     isVolts: isVolts,
                                                     timeOffset: timeOffset)
                }
            }
            if let d = decoded, !d.timecodes.isEmpty {
                result[key] = d
            }
        }
        return result
    }

    private static func decodeRows(_ data: [UInt8], stride: Int, valueOffset: Int, sampleSize: Int,
                                   decoder: XRKTables.DecoderInfo?, manual: Bool,
                                   isVolts: Bool,
                                   timeOffset: Int64) -> XRKDecodedChannel? {
        if stride <= 0 { return nil }
        let rows: Int = data.count / stride
        var tcs: [Int64] = []
        var vals: [Double] = []
        tcs.reserveCapacity(rows)
        vals.reserveCapacity(rows)
        var row: Int = 0
        while row < rows {
            let rowStart: Int = row * stride
            let sampleStart: Int = rowStart + valueOffset
            if rowStart + 4 > data.count || sampleStart < 0 || sampleStart + sampleSize > data.count {
                break
            }
            tcs.append(Int64(xrkI32(data, rowStart)) - timeOffset)
            vals.append(decodeValue(data, sampleStart, decoder: decoder, manual: manual,
                                    isVolts: isVolts))
            row += 1
        }
        return XRKDecodedChannel(timecodes: tcs, values: vals)
    }

    private static func decodeM(_ acc: XRKAccum, sampleSize: Int,
                                decoder: XRKTables.DecoderInfo?, manual: Bool,
                                isVolts: Bool,
                                timeOffset: Int64) -> XRKDecodedChannel {
        let n: Int = acc.timecodes.count
        var tcs: [Int64] = []
        var vals: [Double] = []
        tcs.reserveCapacity(n)
        vals.reserveCapacity(n)
        var i: Int = 0
        while i < n {
            let start: Int = i * sampleSize
            if start + sampleSize > acc.data.count { break }
            tcs.append(Int64(acc.timecodes[i]) - timeOffset)
            vals.append(decodeValue(acc.data, start, decoder: decoder, manual: manual,
                                    isVolts: isVolts))
            i += 1
        }
        return XRKDecodedChannel(timecodes: tcs, values: vals)
    }

    /// Decode one sample. Caller guarantees `o + sampleSize <= d.count`.
    @inline(__always)
    private static func decodeValue(_ d: [UInt8], _ o: Int, decoder: XRKTables.DecoderInfo?, manual: Bool,
                                    isVolts: Bool) -> Double {
        if manual {
            let v: UInt64 = xrkU64(d, o)
            let gear: UInt64 = (v & 0x80000) != 0 ? 0 : ((v >> 16) & 7)
            let value: Double = Double(gear)
            return isVolts ? value / 1000.0 : value
        }
        guard let dec = decoder else { return 0 }
        switch dec.kind {
        case .float32:
            let f: Float = xrkF32(d, o)
            // libxrk divides float channels in Float32 (numpy float32 / int).
            return isVolts ? Double(f / Float(1000)) : Double(f)
        case .float16:
            let f: Float = XRKTables.halfToFloat(xrkU16(d, o))
            return isVolts ? Double(f / Float(1000)) : Double(f)
        case .int32:
            let v: Double = Double(xrkI32(d, o))
            return isVolts ? v / 1000.0 : v
        case .uint16:
            let v: Double = Double(xrkU16(d, o))
            return isVolts ? v / 1000.0 : v
        case .int16:
            let v: Double = Double(xrkI16(d, o))
            return isVolts ? v / 1000.0 : v
        case .uint8:
            let v: Double = Double(d[o])
            return isVolts ? v / 1000.0 : v
        case .gear16:
            let v: Double = Double(XRKTables.gearLookup(xrkU16(d, o)))
            return isVolts ? v / 1000.0 : v
        }
    }
}
