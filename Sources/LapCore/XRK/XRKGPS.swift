// XRKGPS.swift - GPS (u-blox NAV-SOL) decoding, GPS timing-bug correction,
// ECEF/LLA conversion and GPS start/finish lap detection.
//
// Format reference: libxrk (https://github.com/m3rlin45/libxrk), MIT License.
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Port of crates/libxrk/src/gps/{processing,timing,utils}.rs and gps.py.
//
// Each GPS record is 56 bytes: a 4-byte logger timecode followed by a 52-byte
// NAV-SOL payload (iTOW, fTOW, week, gpsFix, flags, ecefX/Y/Z [cm], pAcc,
// ecefVX/VY/VZ [cm/s], sAcc, pDOP, reserved, numSV, reserved).

import Foundation

struct XRKGPSChannelDef {
    let name: String
    let units: String
    let decimals: Int
    let interpolate: Bool
}

/// The synthesized GPS channels, in libxrk's order.
enum XRKGPSChannels {
    static let defs: [XRKGPSChannelDef] = [
        XRKGPSChannelDef(name: "GPS Speed", units: "m/s", decimals: 1, interpolate: true),
        XRKGPSChannelDef(name: "GPS Latitude", units: "deg", decimals: 4, interpolate: true),
        XRKGPSChannelDef(name: "GPS Longitude", units: "deg", decimals: 4, interpolate: true),
        XRKGPSChannelDef(name: "GPS Altitude", units: "m", decimals: 1, interpolate: true),
        XRKGPSChannelDef(name: "GPS_Satellites", units: "", decimals: 0, interpolate: false),
        XRKGPSChannelDef(name: "GPS_Fix", units: "", decimals: 0, interpolate: false),
        XRKGPSChannelDef(name: "GPS_pDOP", units: "", decimals: 2, interpolate: false),
        XRKGPSChannelDef(name: "GPS_Position_Accuracy", units: "m", decimals: 2, interpolate: true),
        XRKGPSChannelDef(name: "GPS_Velocity_Accuracy", units: "m/s", decimals: 2, interpolate: true),
        XRKGPSChannelDef(name: "GPS_InlineAcc", units: "g", decimals: 2, interpolate: true),
        XRKGPSChannelDef(name: "GPS_LateralAcc", units: "g", decimals: 2, interpolate: true),
        XRKGPSChannelDef(name: "GPS_Yaw_Rate", units: "deg/s", decimals: 1, interpolate: true),
        XRKGPSChannelDef(name: "GPS_ITOW", units: "ms", decimals: 0, interpolate: false),
        XRKGPSChannelDef(name: "GPS_Week", units: "", decimals: 0, interpolate: false),
    ]

    static var names: [String] { return defs.map { $0.name } }
}

struct XRKGPSResult {
    /// ms since session start, after timecode reconstruction and gap correction.
    var timecodes: [Int64]
    /// One value array per entry of `XRKGPSChannels.defs`, same order.
    var values: [[Double]]

    var latitude: [Double] { return values[1] }
    var longitude: [Double] { return values[2] }
}

enum XRKGPS {
    static let recordSize: Int = 56

    /// Decode the concatenated GPS payloads. A trailing partial record is
    /// ignored (libxrk rejects the whole file in that case).
    static func decode(_ g: [UInt8], timeOffset: Int64) -> XRKGPSResult? {
        let n: Int = g.count / recordSize
        if n == 0 { return nil }

        var raw: [Int32] = []
        raw.reserveCapacity(n)
        var i: Int = 0
        while i < n {
            raw.append(xrkI32(g, i * recordSize))
            i += 1
        }
        fixTimecodes(&raw)

        var timecodes: [Int64] = []
        timecodes.reserveCapacity(n)
        for t in raw {
            timecodes.append(Int64(t) - timeOffset)
        }

        var speed: [Double] = []
        var lat: [Double] = []
        var lon: [Double] = []
        var alt: [Double] = []
        var sats: [Double] = []
        var fix: [Double] = []
        var pdop: [Double] = []
        var posAcc: [Double] = []
        var velAcc: [Double] = []
        var itow: [Double] = []
        var week: [Double] = []
        var heading: [Double] = []
        speed.reserveCapacity(n)
        lat.reserveCapacity(n)
        lon.reserveCapacity(n)
        alt.reserveCapacity(n)
        sats.reserveCapacity(n)
        fix.reserveCapacity(n)
        pdop.reserveCapacity(n)
        posAcc.reserveCapacity(n)
        velAcc.reserveCapacity(n)
        itow.reserveCapacity(n)
        week.reserveCapacity(n)
        heading.reserveCapacity(n)

        let degPerRad: Double = 180.0 / Double.pi
        let radPerDeg: Double = Double.pi / 180.0
        i = 0
        while i < n {
            let o: Int = i * recordSize
            let x: Double = Double(xrkI32(g, o + 16)) / 100.0
            let y: Double = Double(xrkI32(g, o + 20)) / 100.0
            let z: Double = Double(xrkI32(g, o + 24)) / 100.0
            let lla: (Double, Double, Double) = ecefToLLA(x, y, z)
            lat.append(lla.0)
            lon.append(lla.1)
            alt.append(lla.2)

            let vx: Double = Double(xrkI32(g, o + 32))
            let vy: Double = Double(xrkI32(g, o + 36))
            let vz: Double = Double(xrkI32(g, o + 40))
            let sp: Double = (vx * vx + vy * vy + vz * vz).squareRoot() / 100.0
            speed.append(sp)

            let enu: (Double, Double) = ecefVelocityToENU(vx, vy, vz, lla.0 * radPerDeg, lla.1 * radPerDeg)
            heading.append(atan2(enu.0, enu.1) * degPerRad)

            // float32 channels: computed in Double, stored as Float like libxrk.
            sats.append(Double(Float(g[o + 51])))
            fix.append(Double(Float(g[o + 14])))
            pdop.append(Double(Float(Double(xrkU16(g, o + 48)) / 100.0)))
            posAcc.append(Double(Float(Double(xrkU32(g, o + 28)) / 100.0)))
            velAcc.append(Double(Float(Double(xrkU32(g, o + 44)) / 100.0)))
            itow.append(Double(xrkU32(g, o + 4)))
            week.append(Double(Float(xrkU16(g, o + 12))))
            i += 1
        }

        // Derived channels use the reconstructed logger timecodes (before
        // the session offset and the gap correction), as libxrk does.
        var inline: [Double] = [0.0]
        var yaw64: [Double] = [0.0]
        inline.reserveCapacity(n)
        yaw64.reserveCapacity(n)
        i = 1
        while i < n {
            var dt: Double = Double(Int64(raw[i]) - Int64(raw[i - 1])) / 1000.0
            if !(dt > 0.0) {
                dt = Double.infinity
            }
            let dv: Double = speed[i] - speed[i - 1]
            inline.append(Double(Float(dv / dt / 9.81)))
            var dh: Double = heading[i] - heading[i - 1]
            if dh > 180.0 { dh -= 360.0 }
            if dh < -180.0 { dh += 360.0 }
            yaw64.append(dh / dt)
            i += 1
        }
        var yaw: [Double] = []
        var lateral: [Double] = []
        yaw.reserveCapacity(n)
        lateral.reserveCapacity(n)
        i = 0
        while i < n {
            yaw.append(Double(Float(yaw64[i])))
            lateral.append(Double(Float(((speed[i] * yaw64[i]) * radPerDeg) / 9.81)))
            i += 1
        }

        let values: [[Double]] = [speed, lat, lon, alt, sats, fix, pdop, posAcc, velAcc,
                                  inline, lateral, yaw, itow, week]
        return XRKGPSResult(timecodes: timecodes, values: values)
    }

    /// Phase-unwrap timecodes whose upper 16 bits were corrupted by old
    /// firmware: each step is folded into [-32768, 32767] ms. Only applied
    /// when the stream goes backwards somewhere.
    static func fixTimecodes(_ t: inout [Int32]) {
        if t.count < 2 { return }
        var backwards: Bool = false
        var i: Int = 1
        while i < t.count {
            if t[i] < t[i - 1] {
                backwards = true
                break
            }
            i += 1
        }
        if !backwards { return }
        i = 1
        while i < t.count {
            let diff: UInt32 = UInt32(bitPattern: t[i]) &- UInt32(bitPattern: t[i - 1])
            let low: Int32 = Int32(diff & 0xFFFF)
            let delta: Int32 = (low ^ 0x8000) - 0x8000
            t[i] = t[i - 1] &+ delta
            i += 1
        }
    }

    // MARK: - Timing bug (docs/gps_timing_bug.md)

    struct GapCorrection {
        let gapTime: Int64
        let correction: Int64
    }

    static let overflowBugMs: Int64 = 65533
    static let overflowGapMin: Int64 = 60000
    static let overflowGapMax: Int64 = 70000

    /// Detect the firmware's ~65533 ms GPS timecode jump. Preference order:
    /// GNFI end-time comparison, then direct 60-70 s gaps, then GPS running
    /// 60-70 s past every other channel.
    static func detectGapCorrections(gps: [Int64], gnfi: [Int64], nonGPSMaxEnd: Int64?,
                                     expectedDtMs: Double = 40.0) -> [GapCorrection] {
        if gps.count < 2 { return [] }
        let threshold: Double = expectedDtMs * 10.0
        var gapIndices: [Int] = []
        var i: Int = 0
        while i < gps.count - 1 {
            if Double(gps[i + 1] - gps[i]) > threshold {
                gapIndices.append(i)
            }
            i += 1
        }
        if gapIndices.isEmpty { return [] }
        let expected: Int64 = Int64(expectedDtMs)

        // 1. GNFI (logger clock) reference.
        if gnfi.count >= 2, let gpsEnd = gps.last, let gnfiEnd = gnfi.last {
            let tolerance: Int64 = 5000
            let offset: Int64 = gpsEnd - gnfiEnd
            if offset >= overflowBugMs - tolerance && offset <= overflowBugMs + tolerance {
                var bestIdx: Int? = nil
                var bestSize: Int64 = 0
                for g in gapIndices {
                    let size: Int64 = gps[g + 1] - gps[g]
                    if size > bestSize {
                        bestSize = size
                        bestIdx = g
                    }
                }
                if let idx = bestIdx {
                    let correction: Int64
                    if bestSize >= overflowBugMs - tolerance && bestSize <= overflowBugMs + tolerance {
                        correction = bestSize - expected
                    } else {
                        correction = overflowBugMs
                    }
                    return [GapCorrection(gapTime: gps[idx], correction: correction)]
                }
            }
        }

        // 2. Direct gaps of 60-70 s.
        var corrections: [GapCorrection] = []
        for g in gapIndices {
            let size: Int64 = gps[g + 1] - gps[g]
            if size >= overflowGapMin && size <= overflowGapMax {
                corrections.append(GapCorrection(gapTime: gps[g], correction: size - expected))
            }
        }
        if !corrections.isEmpty { return corrections }

        // 3. GPS ends 60-70 s after every other channel: the bug hid in a
        //    signal-loss gap; correct at the largest gap.
        if let nonGPSEnd = nonGPSMaxEnd, let gpsEnd = gps.last {
            let endOffset: Int64 = gpsEnd - nonGPSEnd
            if endOffset >= overflowGapMin && endOffset <= overflowGapMax {
                var best: Int = gapIndices[0]
                for g in gapIndices {
                    if gps[g + 1] - gps[g] > gps[best + 1] - gps[best] {
                        best = g
                    }
                }
                corrections.append(GapCorrection(gapTime: gps[best], correction: overflowBugMs))
            }
        }
        return corrections
    }

    static func applyCorrections(_ t: inout [Int64], _ corrections: [GapCorrection]) {
        if corrections.isEmpty { return }
        var i: Int = 0
        while i < t.count {
            for c in corrections {
                if t[i] > c.gapTime {
                    t[i] -= c.correction
                }
            }
            i += 1
        }
    }

    // MARK: - Geodesy (WGS84)

    static let wgsA: Double = 6378137.0
    static let wgsE: Double = 8.181919084261345e-2

    /// ECEF (m) -> (lat deg, lon deg, alt m), Vermeille 2003. Operation order
    /// mirrors libxrk so results agree to a few ulp.
    static func ecefToLLA(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        let a: Double = wgsA
        let e: Double = wgsE
        let e2: Double = pow(e, 2.0)
        let e4: Double = pow(e, 4.0)

        let p: Double = (x * x + y * y) * (1.0 / (a * a))
        let q: Double = (((1.0 - e * e) / (a * a)) * z) * z
        let r: Double = (p + q - e4) * (1.0 / 6.0)
        let s: Double = (((e4 / 4.0) * p) * q) / pow(r, 3.0)
        let t: Double = cbrt(1.0 + s + (s * (2.0 + s)).squareRoot())
        let u0: Double = r * (1.0 + t + 1.0 / t)
        let v: Double = (u0 * u0 + e4 * q).squareRoot()
        let u: Double = u0 + v
        let w: Double = ((e2 / 2.0) * (u - q)) / v
        let k: Double = (u + w * w).squareRoot() - w
        let d: Double = (k * (x * x + y * y).squareRoot()) / (k + e2)
        let rtDDzz: Double = (d * d + z * z).squareRoot()

        let lat: Double = ((180.0 / Double.pi) * 2.0) * atan2(z, d + rtDDzz)
        let lon: Double = (180.0 / Double.pi) * atan2(y, x)
        let altitude: Double = ((k + e2 - 1.0) / k) * rtDDzz
        return (lat, lon, altitude)
    }

    /// (lat deg, lon deg, alt m) -> ECEF (m).
    static func llaToECEF(_ latDeg: Double, _ lonDeg: Double, _ alt: Double) -> (Double, Double, Double) {
        let a: Double = wgsA
        let eSq: Double = wgsE * wgsE
        let lat: Double = latDeg * (Double.pi / 180.0)
        let lon: Double = lonDeg * (Double.pi / 180.0)
        let clat: Double = cos(lat)
        let slat: Double = sin(lat)
        let nRad: Double = a / (1.0 - eSq * slat * slat).squareRoot()
        let x: Double = (nRad + alt) * clat * cos(lon)
        let y: Double = (nRad + alt) * clat * sin(lon)
        let z: Double = ((1.0 - eSq) * nRad + alt) * slat
        return (x, y, z)
    }

    /// ECEF velocity -> (east, north).
    static func ecefVelocityToENU(_ dx: Double, _ dy: Double, _ dz: Double,
                                  _ latRad: Double, _ lonRad: Double) -> (Double, Double) {
        let sinLat: Double = sin(latRad)
        let cosLat: Double = cos(latRad)
        let sinLon: Double = sin(lonRad)
        let cosLon: Double = cos(lonRad)
        let east: Double = -sinLon * dx + cosLon * dy
        let north: Double = -sinLat * cosLon * dx - sinLat * sinLon * dy + cosLat * dz
        return (east, north)
    }

    // MARK: - GPS lap detection

    @inline(__always)
    private static func dot(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        return a.0 * b.0 + a.1 * b.1 + a.2 * b.2
    }

    /// Times (ms, fractional) at which the trajectory crosses the vertical
    /// start/finish plane through `marker` (lat, lon deg) within 30 m, moving
    /// at least 4 m/s. Port of libxrk `find_laps`.
    static func findLaps(xyz: [(Double, Double, Double)], timecodes: [Int64],
                         marker: (Double, Double)) -> [Double] {
        let n: Int = min(xyz.count, timecodes.count)
        if n < 2 { return [] }
        let so: (Double, Double, Double) = llaToECEF(marker.0, marker.1, 0.0)
        let top: (Double, Double, Double) = llaToECEF(marker.0, marker.1, 1000.0)
        let sd: (Double, Double, Double) = (top.0 - so.0, top.1 - so.1, top.2 - so.2)
        let nSeg: Int = n - 1

        var o: [(Double, Double, Double)] = []
        var d: [(Double, Double, Double)] = []
        var minSpeed: [Bool] = []
        o.reserveCapacity(nSeg)
        d.reserveCapacity(nSeg)
        minSpeed.reserveCapacity(nSeg)
        var i: Int = 0
        while i < nSeg {
            let p0: (Double, Double, Double) = xyz[i]
            let p1: (Double, Double, Double) = xyz[i + 1]
            o.append((p0.0 - so.0, p0.1 - so.1, p0.2 - so.2))
            let di: (Double, Double, Double) = (p1.0 - p0.0, p1.1 - p0.1, p1.2 - p0.2)
            d.append(di)
            let dtm: Double = Double(timecodes[i + 1] - timecodes[i]) * (4.0 / 1000.0)
            minSpeed.append(dot(di, di) > dtm * dtm)
            i += 1
        }

        let markerSizeSq: Double = 30.0 * 30.0
        let sdDotSd: Double = dot(sd, sd)
        var sn: [(Double, Double, Double)] = []
        sn.reserveCapacity(nSeg)
        i = 0
        while i < nSeg {
            let sdDotD: Double = dot(sd, d[i])
            sn.append((sdDotSd * d[i].0 - sdDotD * sd.0,
                       sdDotSd * d[i].1 - sdDotD * sd.1,
                       sdDotSd * d[i].2 - sdDotD * sd.2))
            i += 1
        }

        func computeT(_ normal: (Double, Double, Double), _ k: Int) -> Double {
            let snDotD: Double = dot(normal, d[k])
            if abs(snDotD) < 1e-30 { return 0.0 }
            return max(-dot(normal, o[k]) / snDotD, 0.0)
        }
        func computeDist(_ tv: Double, _ k: Int) -> Double {
            let p: (Double, Double, Double) = (o[k].0 + tv * d[k].0, o[k].1 + tv * d[k].1, o[k].2 + tv * d[k].2)
            return dot(p, p)
        }
        func picks(_ t: [Double], _ dist: [Double]) -> [Bool] {
            var out: [Bool] = []
            if nSeg < 2 { return out }
            out.reserveCapacity(nSeg - 1)
            var k: Int = 0
            while k < nSeg - 1 {
                out.append(t[k + 1] <= 1.0 && t[k] > 1.0 && dist[k + 1] < markerSizeSq)
                k += 1
            }
            return out
        }

        // First pass: per-segment normals.
        var t: [Double] = []
        var dist: [Double] = []
        t.reserveCapacity(nSeg)
        dist.reserveCapacity(nSeg)
        i = 0
        while i < nSeg {
            let tv: Double = computeT(sn[i], i)
            t.append(tv)
            dist.append(computeDist(tv, i))
            i += 1
        }
        var pick: [Bool] = picks(t, dist)

        // One velocity-weighted normal for all crossings.
        var avg: (Double, Double, Double) = (0.0, 0.0, 0.0)
        i = 0
        while i < pick.count {
            if pick[i] && minSpeed[i + 1] {
                avg.0 += sn[i + 1].0
                avg.1 += sn[i + 1].1
                avg.2 += sn[i + 1].2
            }
            i += 1
        }

        // Second pass with the averaged normal.
        i = 0
        while i < nSeg {
            let tv: Double = computeT(avg, i)
            t[i] = tv
            dist[i] = computeDist(tv, i)
            i += 1
        }
        pick = picks(t, dist)

        var markers: [Double] = [0.0]
        i = 0
        while i < pick.count {
            if !pick[i] {
                i += 1
                continue
            }
            var idx: Int = i + 1
            let tcAtIdx: Double = Double(timecodes[idx])
            if let lastMarker = markers.last, tcAtIdx <= lastMarker {
                i += 1
                continue
            }
            if !minSpeed[idx] {
                var j: Int = idx
                var found: Int? = nil
                while j < nSeg {
                    if minSpeed[j] {
                        found = j
                        break
                    }
                    j += 1
                }
                guard let f = found else {
                    i += 1
                    continue
                }
                idx = f
            }
            if idx + 1 >= n {
                i += 1
                continue
            }
            let markerTime: Double = Double(timecodes[idx]) + t[idx] * Double(timecodes[idx + 1] - timecodes[idx])
            markers.append(markerTime)
            i += 1
        }
        return Array(markers.dropFirst())
    }
}
