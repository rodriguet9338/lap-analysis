// XRKMetadata.swift - session metadata from header messages.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Port of crates/libxrk/src/metadata.rs / `_get_metadata` in _aim_xrk_cy.pyx.
//
// Keys of `SessionMetadata.extra` are libxrk's metadata keys. Values are
// rendered the way Python's str() renders libxrk's values, so they compare
// equal to `str(log.metadata[key])`: floats use the shortest round-trip form
// ("1029.448"), and list values (Calibrations, Expansion Devices) use Python
// list/dict repr. libxrk keys that are promoted to typed fields (Driver,
// Vehicle, Venue, Device Name, Logger ID) are not repeated in `extra`, and
// "Logger Model" is omitted when libxrk would report None.

import Foundation

enum XRKMetadataBuilder {

    static func build(state: XRKStreamState,
                      dataChannelIndices: [UInt16],
                      displayNames: [UInt16: String]) -> SessionMetadata {
        var meta: SessionMetadata = SessionMetadata()
        var extra: [String: String] = [:]
        let msgs: [UInt32: [XRKMessage]] = state.messages

        func lastString(_ token: UInt32) -> String? {
            guard let m = msgs[token]?.last else { return nil }
            return xrkNullTermString(m.payload, 0, m.payload.count)
        }

        if let s = lastString(XRKTok.rcr) { meta.driver = s }
        if let s = lastString(XRKTok.veh) { meta.vehicle = s }
        if let s = lastString(XRKTok.tmd) { extra["Log Date"] = s }
        if let s = lastString(XRKTok.tmt) { extra["Log Time"] = s }
        if let s = lastString(XRKTok.vty) { extra["Session"] = s }
        if let s = lastString(XRKTok.cmp) { extra["Series"] = s }
        if let s = lastString(XRKTok.nte) { extra["Long Comment"] = s }

        if let m = msgs[XRKTok.trk]?.last, let trk = XRKTrackRecord(m.payload) {
            meta.venue = trk.name
        }

        if let m = msgs[XRKTok.odo]?.last {
            for rec in XRKOdometerRecord.parseAll(m.payload) {
                let km: Double = Double(rec.meters) / 1000.0
                extra["Odo/\(rec.name) Distance (km)"] = pyFloat(km)
                let h: UInt32 = rec.seconds / 3600
                let mi: UInt32 = (rec.seconds / 60) % 60
                let se: UInt32 = rec.seconds % 60
                extra["Odo/\(rec.name) Time"] = "\(h):\(twoDigits(mi)):\(twoDigits(se))"
            }
        }

        if let m = msgs[XRKTok.idn]?.last, let idn = XRKIdentity(m.payload) {
            meta.loggerID = String(idn.loggerID)
            extra["Logger Model ID"] = String(idn.modelID)
            if let model = XRKTables.loggerModelName(idn.modelID) {
                extra["Logger Model"] = model
            }
        }

        if let s = lastString(XRKTok.ndv) { meta.deviceName = s }

        if let m = msgs[XRKTok.gpsr]?.last, let gpsr = XRKGPSReceiver(m.payload) {
            extra["GPS Receiver"] = gpsr.type
        }

        // Expansion devices (ENF containers), enriched positionally with iSLV ids.
        if !state.enfMessages.isEmpty {
            var devices: [[(String, String)]] = []
            let keys: [(UInt32, String)] = [(XRKTok.dbun, "Bus Unit"), (XRKTok.dbut, "Bus Type"),
                                             (XRKTok.dver, "Version"), (XRKTok.manl, "Manufacturer"),
                                             (XRKTok.modl, "Model")]
            for enf in state.enfMessages {
                var device: [(String, String)] = []
                for (tok, key) in keys {
                    if let m = enf[tok]?.last {
                        device.append((key, pyRepr(xrkNullTermString(m.payload, 0, m.payload.count))))
                    }
                }
                if !device.isEmpty {
                    devices.append(device)
                }
            }
            var slaves: [XRKIdentity] = []
            for m in msgs[XRKTok.islv] ?? [] {
                if let idn = XRKIdentity.embedded(m.payload, minimumLength: 16) {
                    slaves.append(idn)
                }
            }
            var k: Int = 0
            while k < devices.count && k < slaves.count {
                devices[k].append(("Logger ID", String(slaves[k].loggerID)))
                devices[k].append(("Model ID", String(slaves[k].modelID)))
                k += 1
            }
            if !devices.isEmpty {
                extra["Expansion Devices"] = "[" + devices.map { XRKMetadataBuilder.pyDict($0) }.joined(separator: ", ") + "]"
            }
        }

        for m in msgs[XRKTok.racm] ?? [] where m.payload.count > 1 {
            extra["Race Mode"] = xrkNullTermString(m.payload, 0, m.payload.count)
        }

        if let m = msgs[XRKTok.vet]?.last {
            if m.payload.count > 1 {
                extra["Vehicle Electronics Type"] = xrkNullTermString(m.payload, 0, m.payload.count)
            } else if let first = m.payload.first {
                extra["Vehicle Electronics Type"] = String(first)
            } else {
                extra["Vehicle Electronics Type"] = "0"
            }
        }

        // Calibrations, attributed to the data-bearing channel whose CHS
        // carries the same (cal_value_1, cal_value_2); later index wins.
        if let cals = msgs[XRKTok.cal], !cals.isEmpty {
            var calToChannel: [CalKey: String] = [:]
            for idx in dataChannelIndices {
                guard let info = state.channels[idx] else { continue }
                if let key = CalKey(info.def.calValue1, info.def.calValue2) {
                    calToChannel[key] = displayNames[idx] ?? info.def.longName
                }
            }
            var items: [String] = []
            for m in cals {
                guard let cal = XRKCalibration(m.payload) else { continue }
                var pairs: [(String, String)] = [("type", String(cal.calType)),
                                                 ("raw_1", pyFloat(Double(cal.raw1))),
                                                 ("raw_2", pyFloat(Double(cal.raw2)))]
                if let o1 = cal.output1, let o2 = cal.output2 {
                    pairs.append(("output_1", pyFloat(Double(o1))))
                    pairs.append(("output_2", pyFloat(Double(o2))))
                }
                if let key = CalKey(cal.raw1, cal.raw2), let ch = calToChannel[key] {
                    pairs.append(("channel", pyRepr(ch)))
                }
                items.append(pyDict(pairs))
            }
            if !items.isEmpty {
                extra["Calibrations"] = "[" + items.joined(separator: ", ") + "]"
            }
        }

        meta.date = parseLogDate(extra["Log Date"], extra["Log Time"])
        meta.extra = extra
        return meta
    }

    /// Float pair compared like Python floats: -0.0 == 0.0, NaN never matches.
    struct CalKey: Hashable {
        let a: UInt32
        let b: UInt32

        init?(_ x: Float, _ y: Float) {
            if x.isNaN || y.isNaN { return nil }
            a = (x == 0 ? Float(0) : x).bitPattern
            b = (y == 0 ? Float(0) : y).bitPattern
        }
    }

    // MARK: - Date

    /// "Log Date" + "Log Time" as logger wall-clock time, interpreted in the
    /// current time zone (the file carries no zone). Dates are MM/DD/YYYY on
    /// the loggers seen so far (checked against GPS week/iTOW on the fixture);
    /// a first field above 12 is taken as DD/MM/YYYY.
    static func parseLogDate(_ date: String?, _ time: String?) -> Date? {
        guard let date = date else { return nil }
        let dParts: [Int] = date.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard dParts.count == 3 else { return nil }
        var month: Int = dParts[0]
        var day: Int = dParts[1]
        var year: Int = dParts[2]
        if month > 12 && day <= 12 {
            let tmp: Int = month
            month = day
            day = tmp
        }
        if year < 100 { year += 2000 }
        guard (1...12).contains(month), (1...31).contains(day), (1970...2200).contains(year) else { return nil }

        var hour: Int = 0
        var minute: Int = 0
        var second: Int = 0
        if let time = time {
            let tParts: [Int] = time.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if tParts.count >= 2 {
                hour = tParts[0]
                minute = tParts[1]
                second = tParts.count >= 3 ? tParts[2] : 0
            }
        }
        guard (0...23).contains(hour), (0...59).contains(minute), (0...60).contains(second) else { return nil }

        var comps: DateComponents = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        var cal: Calendar = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.date(from: comps)
    }

    // MARK: - Python-style rendering

    static func twoDigits(_ v: UInt32) -> String {
        return v < 10 ? "0\(v)" : "\(v)"
    }

    /// Python repr()/str() of a float: shortest round-trip digits.
    static func pyFloat(_ v: Double) -> String {
        if v.isNaN { return "nan" }
        if v.isInfinite { return v < 0 ? "-inf" : "inf" }
        // Swift's description is also shortest round-trip; it differs from
        // Python only in exponent formatting (both use "e+XX"/"e-XX").
        return v.description
    }

    /// Python repr() of a str.
    static func pyRepr(_ s: String) -> String {
        let quote: Character = (s.contains("'") && !s.contains("\"")) ? "\"" : "'"
        var out: String = String(quote)
        for ch in s.unicodeScalars {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if Character(ch) == quote {
                    out += "\\" + String(quote)
                } else if ch.value < 0x20 || ch.value == 0x7F {
                    let hex: String = String(ch.value, radix: 16)
                    out += "\\x" + (hex.count < 2 ? "0" + hex : hex)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out.append(quote)
        return out
    }

    /// Python repr() of a dict whose values are already rendered.
    static func pyDict(_ pairs: [(String, String)]) -> String {
        return "{" + pairs.map { "\(XRKMetadataBuilder.pyRepr($0.0)): \($0.1)" }.joined(separator: ", ") + "}"
    }
}
