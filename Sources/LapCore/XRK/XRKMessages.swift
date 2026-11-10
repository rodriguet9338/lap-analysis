// XRKMessages.swift - `<h ... >` header message framing and payload structs.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Port of crates/libxrk/src/messages.rs and payloads/*.rs.
//
// Wire format of a header message:
//   "<h"  token:u32  payload_len:i32  version:u8  ">"  payload  "<"  token:u32  checksum:u16  ">"
// checksum = sum of payload bytes, truncated to 16 bits. 3-character tokens
// carry a trailing space (0x20) that is stripped.

import Foundation

enum XRKTok {
    static let gps: UInt32 = xrkToken("GPS")
    static let gps1: UInt32 = xrkToken("GPS1")
    static let gnfi: UInt32 = xrkToken("GNFI")
    static let chs: UInt32 = xrkToken("CHS")
    static let grp: UInt32 = xrkToken("GRP")
    static let lap: UInt32 = xrkToken("LAP")
    static let idn: UInt32 = xrkToken("idn")
    static let trk: UInt32 = xrkToken("TRK")
    static let gpsr: UInt32 = xrkToken("GPSR")
    static let cal: UInt32 = xrkToken("CAL")
    static let odo: UInt32 = xrkToken("ODO")
    static let cnf: UInt32 = xrkToken("CNF")
    static let enf: UInt32 = xrkToken("ENF")
    static let islv: UInt32 = xrkToken("iSLV")
    static let src: UInt32 = xrkToken("SRC")
    static let racm: UInt32 = xrkToken("RACM")
    static let vet: UInt32 = xrkToken("VET")
    static let rcr: UInt32 = xrkToken("RCR")
    static let veh: UInt32 = xrkToken("VEH")
    static let cmp: UInt32 = xrkToken("CMP")
    static let vty: UInt32 = xrkToken("VTY")
    static let ndv: UInt32 = xrkToken("NDV")
    static let tmd: UInt32 = xrkToken("TMD")
    static let tmt: UInt32 = xrkToken("TMT")
    static let nte: UInt32 = xrkToken("NTE")
    static let dbun: UInt32 = xrkToken("DBUN")
    static let dbut: UInt32 = xrkToken("DBUT")
    static let dver: UInt32 = xrkToken("DVER")
    static let manl: UInt32 = xrkToken("MANL")
    static let modl: UInt32 = xrkToken("MODL")
}

/// Location of a validated header message inside the byte buffer.
struct XRKHeaderFrame {
    let token: UInt32
    let version: UInt8
    let payloadStart: Int
    let payloadEnd: Int
    /// Total bytes from the opening "<h" to the closing ">".
    let consumed: Int
}

/// A stored header message (payload copied out of the stream).
struct XRKMessage {
    let token: UInt32
    let version: UInt8
    let payload: [UInt8]
}

enum XRKFraming {
    /// Validate a header message at `pos` (bytes up to `end` are available).
    /// Returns nil on any framing, length, token or checksum mismatch.
    static func parseHeader(_ b: [UInt8], _ pos: Int, _ end: Int) -> XRKHeaderFrame? {
        guard pos >= 0, end <= b.count, pos < end else { return nil }
        let remaining: Int = end - pos
        // 2 op + 4 tok + 4 len + 1 ver + 1 '>' + 1 '<' + 4 tok + 2 sum + 1 '>'
        if remaining < 20 { return nil }
        if b[pos] != 0x3C || b[pos + 1] != 0x68 { return nil }
        let wireToken: UInt32 = xrkU32(b, pos + 2)
        let payloadLen32: Int32 = xrkI32(b, pos + 6)
        let version: UInt8 = b[pos + 10]
        if b[pos + 11] != 0x3E { return nil }
        if payloadLen32 < 0 { return nil }
        let payloadLen: Int = Int(payloadLen32)
        // remaining >= 20 and payloadLen <= Int32.max, so these cannot overflow.
        if payloadLen > remaining - 20 { return nil }
        let payloadStart: Int = pos + 12
        let payloadEnd: Int = payloadStart + payloadLen
        // Footer: '<' token checksum '>'
        if b[payloadEnd] != 0x3C { return nil }
        if b[payloadEnd + 7] != 0x3E { return nil }
        if xrkU32(b, payloadEnd + 1) != wireToken { return nil }
        let footerSum: UInt16 = xrkU16(b, payloadEnd + 5)
        var sum: UInt16 = 0
        var i: Int = payloadStart
        while i < payloadEnd {
            sum = sum &+ UInt16(b[i])
            i += 1
        }
        if sum != footerSum { return nil }
        var token: UInt32 = wireToken
        if (wireToken >> 24) == 0x20 {
            token = wireToken - (UInt32(0x20) << 24)
        }
        return XRKHeaderFrame(token: token, version: version,
                              payloadStart: payloadStart, payloadEnd: payloadEnd,
                              consumed: payloadEnd + 8 - pos)
    }
}

// MARK: - Payloads

/// CHS: channel definition (112 bytes).
struct XRKChannelDef {
    var index: UInt16
    var hardwareID: UInt16
    var sourceChannelID: UInt16
    var hardwareRef: UInt32
    var unitType: UInt8
    var displayFormat: UInt8
    var configFlags: UInt16
    var sourceType: UInt8
    var decoderType: UInt8
    var shortName: String
    var longName: String
    var samplePeriodMicros: UInt32
    var dataSize: UInt8
    var calValue1: Float
    var calValue2: Float
    var displayRangeMin: Float
    var displayRangeMax: Float

    init?(_ b: [UInt8], _ start: Int, _ end: Int) {
        guard start >= 0, end <= b.count, end - start >= 112 else { return nil }
        let o: Int = start
        index = xrkU16(b, o)
        hardwareID = xrkU16(b, o + 4)
        sourceChannelID = xrkU16(b, o + 6)
        hardwareRef = xrkU32(b, o + 8)
        unitType = b[o + 12]
        displayFormat = b[o + 13]
        configFlags = xrkU16(b, o + 14)
        sourceType = b[o + 16]
        decoderType = b[o + 20]
        shortName = xrkNullTermString(b, o + 24, o + 32)
        longName = xrkNullTermString(b, o + 32, o + 56)
        samplePeriodMicros = xrkU32(b, o + 64)
        dataSize = b[o + 72]
        calValue1 = xrkF32(b, o + 96)
        calValue2 = xrkF32(b, o + 100)
        displayRangeMin = xrkF32(b, o + 104)
        displayRangeMax = xrkF32(b, o + 108)
    }

    /// M-message sample period in ms.
    var mms: UInt32 { return samplePeriodMicros / 1000 }

    var units: String { return XRKTables.resolveUnit(unitType) }

    var decimals: Int { return XRKTables.unitMap(unitType).1 }
}

/// GRP: group definition.
struct XRKGroupDef {
    let index: UInt16
    let channelIndices: [UInt16]

    init?(_ b: [UInt8], _ start: Int, _ end: Int) {
        guard start >= 0, end <= b.count, end - start >= 4 else { return nil }
        index = xrkU16(b, start)
        let count: Int = Int(xrkU16(b, start + 2))
        guard end - start >= 4 + count * 2 else { return nil }
        var indices: [UInt16] = []
        indices.reserveCapacity(count)
        var k: Int = 0
        while k < count {
            indices.append(xrkU16(b, start + 4 + k * 2))
            k += 1
        }
        channelIndices = indices
    }

    init(index: UInt16, channelIndices: [UInt16]) {
        self.index = index
        self.channelIndices = channelIndices
    }
}

/// LAP: 20 bytes (v0/v1, end time at [16:20]) or 32 bytes (v2, end time at [28:32]).
struct XRKLapRecord {
    let segment: UInt8
    let lapNumber: UInt16
    let duration: UInt32
    let endTime: UInt32

    init?(_ p: [UInt8]) {
        guard p.count >= 20 else { return nil }
        segment = p[1]
        lapNumber = xrkU16(p, 2)
        duration = xrkU32(p, 4)
        if p.count >= 32 {
            endTime = xrkU32(p, 28)
        } else {
            endTime = xrkU32(p, 16)
        }
    }
}

/// TRK: track name and start/finish coordinates (>= 44 bytes).
struct XRKTrackRecord {
    let name: String
    let sfLatitude: Double
    let sfLongitude: Double

    init?(_ p: [UInt8]) {
        guard p.count >= 44 else { return nil }
        name = xrkNullTermString(p, 0, 32)
        sfLatitude = Double(xrkI32(p, 36)) / 1e7
        sfLongitude = Double(xrkI32(p, 40)) / 1e7
    }
}

/// idn: logger identity (>= 10 bytes).
struct XRKIdentity {
    let modelID: UInt16
    let loggerID: UInt32

    init?(_ p: [UInt8], offset: Int = 0) {
        guard offset >= 0, p.count - offset >= 10 else { return nil }
        modelID = xrkU16(p, offset)
        loggerID = xrkU32(p, offset + 6)
    }

    /// iSLV embeds "idn" + version + length (6 bytes) followed by an idn payload.
    static func embedded(_ p: [UInt8], minimumLength: Int) -> XRKIdentity? {
        guard p.count >= minimumLength, p.count >= 16 else { return nil }
        guard p[0] == 0x69, p[1] == 0x64, p[2] == 0x6E else { return nil } // "idn"
        return XRKIdentity(p, offset: 6)
    }
}

/// CAL: calibration record (>= 40 bytes).
struct XRKCalibration {
    let calType: UInt32
    let raw1: Float
    let raw2: Float
    let output1: Float?
    let output2: Float?

    init?(_ p: [UInt8]) {
        guard p.count >= 40 else { return nil }
        calType = xrkU32(p, 20)
        raw1 = xrkF32(p, 24)
        raw2 = xrkF32(p, 28)
        if calType == 1 {
            output1 = xrkF32(p, 32)
            output2 = xrkF32(p, 36)
        } else {
            output1 = nil
            output2 = nil
        }
    }
}

/// ODO: n x 64-byte odometer records; "Fuel*" records are skipped.
struct XRKOdometerRecord {
    let name: String
    let seconds: UInt32
    let meters: UInt32

    static func parseAll(_ p: [UInt8]) -> [XRKOdometerRecord] {
        var out: [XRKOdometerRecord] = []
        var offset: Int = 0
        while offset + 64 <= p.count {
            let name: String = xrkNullTermString(p, offset, offset + 16)
            if !name.hasPrefix("Fuel") {
                out.append(XRKOdometerRecord(name: name,
                                             seconds: xrkU32(p, offset + 16),
                                             meters: xrkU32(p, offset + 20)))
            }
            offset += 64
        }
        return out
    }
}

/// GPSR: GPS receiver description (>= 36 bytes).
struct XRKGPSReceiver {
    let type: String

    init?(_ p: [UInt8]) {
        guard p.count >= 36 else { return nil }
        type = xrkNullTermString(p, 4, 8)
    }
}
