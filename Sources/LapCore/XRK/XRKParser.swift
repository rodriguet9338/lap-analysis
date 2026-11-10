// XRKParser.swift - public entry point: AiM .xrk/.xrz bytes -> Session.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Port of `read_xrk_with_options` (crates/libxrk/src/lib.rs) plus lap
// processing from parser.rs. libxrk's integer milliseconds become seconds.

import Foundation

public enum XRKError: Error {
    case notXRK
    case truncated
    case decompressionFailed
    case malformed(String)
}

public enum XRKParser {

    /// Accepts .xrk or .xrz bytes (xrz = zlib-compressed xrk, detected by content).
    public static func parse(_ data: Data) throws -> Session {
        var bytes: [UInt8] = [UInt8](data)
        if XRKZlib.looksCompressed(bytes) {
            let inflated: [UInt8] = XRKZlib.inflate(bytes)
            if inflated.isEmpty {
                throw XRKError.decompressionFailed
            }
            bytes = inflated
        }
        return try parseBytes(bytes)
    }

    public static func parse(contentsOf url: URL) throws -> Session {
        let data: Data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data)
    }

    // MARK: - Pipeline

    static func parseBytes(_ bytes: [UInt8]) throws -> Session {
        if bytes.isEmpty { throw XRKError.notXRK }

        let state: XRKStreamState = XRKStreamState()
        state.prescan(bytes, 0, bytes.count)
        state.scan(bytes, 0, bytes.count, depth: 0)
        state.resolveCVariants()

        if state.headerCount == 0 {
            throw XRKError.notXRK
        }
        if state.channels.isEmpty && state.gpsData.count < XRKGPS.recordSize {
            throw XRKError.malformed("no channel definitions or GPS data")
        }

        let timeOffset: Int64 = state.computeTimeOffset()
        let decoded: [UInt16: XRKDecodedChannel] = state.decodeChannels(timeOffset: timeOffset)
        let hasGPS: Bool = state.gpsData.count >= XRKGPS.recordSize

        // Display names: duplicates become "<name> dup <k>" in channel-index
        // order; the synthesized GPS names are reserved when GPS is present.
        let displayNames: [UInt16: String] = channelDisplayNames(state.channels,
                                                                 reserved: hasGPS ? XRKGPSChannels.names : [])

        var channels: [Channel] = []
        let dataIndices: [UInt16] = decoded.keys.sorted()
        var nonGPSMaxEnd: Int64? = nil
        for idx in dataIndices {
            guard let d = decoded[idx], let info = state.channels[idx] else { continue }
            if let last = d.timecodes.last {
                if let cur = nonGPSMaxEnd {
                    if last > cur { nonGPSMaxEnd = last }
                } else {
                    nonGPSMaxEnd = last
                }
            }
            let def: XRKChannelDef = info.def
            let manual: Bool = XRKTables.isManualDecoder(def.longName)
            let interpolate: Bool = manual ? false : (XRKTables.decoderInfo(def.decoderType)?.interpolate ?? false)
            // libxrk reports no units for 1-byte channels.
            let units: String = def.dataSize == 1 ? "" : def.units
            channels.append(Channel(name: displayNames[idx] ?? def.longName,
                                    units: units,
                                    decimals: def.decimals,
                                    interpolate: interpolate,
                                    times: millisToSeconds(d.timecodes),
                                    values: d.values))
        }

        // GPS channels, with the firmware timing-gap correction.
        var gps: XRKGPSResult? = nil
        if hasGPS {
            gps = XRKGPS.decode(state.gpsData, timeOffset: timeOffset)
        }
        if var g = gps {
            var gnfi: [Int64] = []
            let gnfiCount: Int = state.gnfiData.count
            if gnfiCount > 0 && gnfiCount % 32 == 0 {
                gnfi.reserveCapacity(gnfiCount / 32)
                var k: Int = 0
                while k < gnfiCount / 32 {
                    gnfi.append(Int64(xrkI32(state.gnfiData, k * 32)) - timeOffset)
                    k += 1
                }
            }
            let corrections: [XRKGPS.GapCorrection] = XRKGPS.detectGapCorrections(
                gps: g.timecodes, gnfi: gnfi, nonGPSMaxEnd: nonGPSMaxEnd)
            XRKGPS.applyCorrections(&g.timecodes, corrections)
            gps = g

            let times: [Double] = millisToSeconds(g.timecodes)
            var k: Int = 0
            while k < XRKGPSChannels.defs.count && k < g.values.count {
                let def: XRKGPSChannelDef = XRKGPSChannels.defs[k]
                channels.append(Channel(name: def.name, units: def.units, decimals: def.decimals,
                                        interpolate: def.interpolate, times: times, values: g.values[k]))
                k += 1
            }
        }

        if channels.isEmpty {
            // Definitions but no samples: the recording was cut before any data.
            throw XRKError.truncated
        }

        let laps: [Lap] = buildLaps(state: state, timeOffset: timeOffset, gps: gps)
        let metadata: SessionMetadata = XRKMetadataBuilder.build(state: state,
                                                                 dataChannelIndices: dataIndices,
                                                                 displayNames: displayNames)
        return Session(metadata: metadata, channels: channels, laps: laps)
    }

    static func millisToSeconds(_ ms: [Int64]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(ms.count)
        for v in ms {
            out.append(Double(v) / 1000.0)
        }
        return out
    }

    static func channelDisplayNames(_ channels: [UInt16: XRKChannelInfo], reserved: [String]) -> [UInt16: String] {
        var seen: [String: Int] = [:]
        for name in reserved {
            seen[name] = 1
        }
        var out: [UInt16: String] = [:]
        for idx in channels.keys.sorted() {
            guard let info = channels[idx] else { continue }
            let base: String = info.def.longName
            let k: Int = (seen[base] ?? 0) + 1
            seen[base] = k
            out[idx] = k > 1 ? "\(base) dup \(k)" : base
        }
        return out
    }

    // MARK: - Laps

    /// Laps from LAP messages (segment 0, de-duplicated, single missing lap
    /// inferred, renumbered from 0). Falls back to GPS start/finish crossings
    /// when there are no usable LAP messages.
    static func buildLaps(state: XRKStreamState, timeOffset: Int64, gps: XRKGPSResult?) -> [Lap] {
        var nums: [Int] = []
        var starts: [Int64] = []
        var ends: [Int64] = []
        var valid: Bool = true

        for m in state.messages[XRKTok.lap] ?? [] {
            guard let lap = XRKLapRecord(m.payload) else { continue }
            let endTime: Int64 = Int64(lap.endTime) - timeOffset
            let duration: Int64 = Int64(lap.duration)
            let num: Int = Int(lap.lapNumber)
            if lap.segment != 0 { continue }
            if let lastNum = nums.last {
                if lastNum == num {
                    continue
                } else if lastNum + 2 == num {
                    let inferredStart: Int64 = ends.last ?? 0
                    nums.append(num - 1)
                    starts.append(inferredStart)
                    ends.append(endTime - duration)
                } else if lastNum + 1 != num {
                    // libxrk raises here; we drop LAP-based laps instead.
                    valid = false
                    break
                }
            }
            nums.append(num)
            starts.append(endTime - duration)
            ends.append(endTime)
        }

        var laps: [Lap] = []
        if valid, let minNum = nums.min() {
            var i: Int = 0
            while i < nums.count {
                laps.append(Lap(number: nums[i] - minNum,
                                start: Double(starts[i]) / 1000.0,
                                end: Double(ends[i]) / 1000.0))
                i += 1
            }
            var i2: Int = 0
            while i2 < nums.count {
                if starts[i2] < 0 || ends[i2] <= starts[i2] {
                    laps = []
                    break
                }
                i2 += 1
            }
        }
        if !laps.isEmpty { return laps }

        // GPS fallback: needs a TRK start/finish marker.
        guard let g = gps,
              let trkMsg = state.messages[XRKTok.trk]?.last,
              let trk = XRKTrackRecord(trkMsg.payload) else {
            return []
        }
        let lat: [Double] = g.latitude
        let lon: [Double] = g.longitude
        let n: Int = min(lat.count, lon.count, g.timecodes.count)
        var xyz: [(Double, Double, Double)] = []
        xyz.reserveCapacity(n)
        var i: Int = 0
        while i < n {
            xyz.append(XRKGPS.llaToECEF(lat[i], lon[i], 0.0))
            i += 1
        }
        var markers: [Double] = XRKGPS.findLaps(xyz: xyz, timecodes: Array(g.timecodes.prefix(n)),
                                                marker: (trk.sfLatitude, trk.sfLongitude))
        if markers.isEmpty { return [] }
        markers.append(Double(g.timecodes.last ?? 0))
        var out: [Lap] = []
        i = 0
        while i + 1 < markers.count {
            if let s = xrkInt64(markers[i]), let e = xrkInt64(markers[i + 1]) {
                out.append(Lap(number: i, start: Double(s) / 1000.0, end: Double(e) / 1000.0))
            }
            i += 1
        }
        return out
    }
}
