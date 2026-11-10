// XRKParserTests.swift - tests for the XRK/XRZ parser (LapCore/XRK).
//
// The parser ports libxrk (https://github.com/m3rlin45/libxrk), MIT License,
// Copyright (c) 2024 Scott Smith; Copyright (c) 2025 Christopher Dewan.
// Expected values for the synthetic file below were produced by running
// libxrk's Rust crate on the same bytes.

import XCTest
import Foundation
import LapCore

final class XRKParserTests: XCTestCase {

    // MARK: - Known differences from the golden file
    //
    // ek9_motegi.golden.json was generated with libxrk 0.13.0 from PyPI. The
    // parser follows the newer libxrk source that is the format reference,
    // which differs from 0.13.0 in exactly these ways on this file (checked by
    // running both on the fixture):
    //  - unit type 8 maps to "m" (0.13.0 reported no unit), and
    //  - two extra synthesized GPS channels, GPS_ITOW and GPS_Week.
    // Everything else (names, rows, times, values, laps) is identical.
    private static let goldenUnitOverrides: [String: String] = [
        "Distance Lap": "m",
        "Distance Lap Int": "m",
    ]
    private static let channelsNewerThanGolden: [String] = ["GPS_ITOW", "GPS_Week"]
    /// libxrk reports None here; the port leaves the key out.
    private static let metadataKeysNotPorted: Set<String> = ["Logger Model"]
    /// libxrk metadata keys that the port exposes as typed fields.
    private static let promotedMetadataKeys: Set<String> = ["Driver", "Vehicle", "Venue", "Device Name", "Logger ID"]

    // MARK: - Helpers

    private func fixtureURL(_ name: String, _ ext: String) throws -> URL {
        return try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
                             "missing fixture \(name).\(ext)")
    }

    private func ms(_ seconds: Double) -> Int {
        return Int((seconds * 1000.0).rounded())
    }

    private func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    private func assertClose(_ actual: Double, _ expected: Double, rel: Double,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        if actual == expected { return }
        let tol: Double = rel * max(abs(expected), 1e-12)
        XCTAssertLessThanOrEqual(abs(actual - expected), tol, message, file: file, line: line)
    }

    private func assertThrowsXRKError(_ data: Data, _ message: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try XRKParser.parse(data), message, file: file, line: line) { error in
            XCTAssertTrue(error is XRKError, "\(message): unexpected error \(error)", file: file, line: line)
        }
    }

    /// Structural invariants every parsed session must satisfy.
    private func assertWellFormed(_ session: Session, _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(session.channels.isEmpty, message, file: file, line: line)
        for ch in session.channels {
            XCTAssertEqual(ch.times.count, ch.values.count, "\(message): \(ch.name)", file: file, line: line)
        }
        for lap in session.laps {
            XCTAssertTrue(lap.start.isFinite && lap.end.isFinite, message, file: file, line: line)
        }
    }

    /// Deterministic xorshift64* generator for fuzz inputs.
    private struct SeededBytes {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt8 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return UInt8(truncatingIfNeeded: (state &* 0x2545F4914F6CDD1D) >> 56)
        }
        mutating func bytes(_ n: Int) -> [UInt8] {
            var out: [UInt8] = []
            out.reserveCapacity(n)
            for _ in 0..<n { out.append(next()) }
            return out
        }
    }

    // MARK: - Golden fixture (truncated .xrz from an AiM Solo 2)

    func testGoldenFixture() throws {
        let session: Session = try XRKParser.parse(contentsOf: try fixtureURL("ek9_motegi", "xrz"))
        let goldenURL: URL = try fixtureURL("ek9_motegi.golden", "json")
        let goldenData: Data = try Data(contentsOf: goldenURL)
        let golden: [String: Any] = try XCTUnwrap(try JSONSerialization.jsonObject(with: goldenData) as? [String: Any])

        // Laps
        let goldenLaps: [[String: Any]] = try XCTUnwrap(golden["laps"] as? [[String: Any]])
        XCTAssertEqual(session.laps.count, goldenLaps.count)
        for (i, gl) in goldenLaps.enumerated() where i < session.laps.count {
            let lap: Lap = session.laps[i]
            XCTAssertEqual(lap.number, Int(number(gl["num"]) ?? -1), "lap \(i) number")
            XCTAssertEqual(ms(lap.start), Int(number(gl["start_ms"]) ?? -1), "lap \(i) start")
            XCTAssertEqual(ms(lap.end), Int(number(gl["end_ms"]) ?? -1), "lap \(i) end")
        }

        // Channel set and order (golden order = order of keys in the JSON text).
        let goldenChannels: [String: Any] = try XCTUnwrap(golden["channels"] as? [String: Any])
        let goldenText: String = String(decoding: goldenData, as: UTF8.self)
        let goldenOrder: [String] = goldenChannels.keys.sorted { a, b in
            let ra: Int = goldenText.range(of: "\"\(a)\": {").map { goldenText.distance(from: goldenText.startIndex, to: $0.lowerBound) } ?? Int.max
            let rb: Int = goldenText.range(of: "\"\(b)\": {").map { goldenText.distance(from: goldenText.startIndex, to: $0.lowerBound) } ?? Int.max
            return ra < rb
        }
        let names: [String] = session.channels.map { $0.name }
        XCTAssertEqual(Set(names), Set(goldenOrder).union(XRKParserTests.channelsNewerThanGolden))
        XCTAssertEqual(names.filter { goldenChannels[$0] != nil }, goldenOrder, "channel order")
        XCTAssertEqual(Array(names.suffix(14)).prefix(12).map { $0 }, Array(goldenOrder.suffix(12)), "GPS channels last")

        for name in goldenOrder {
            guard let gc = goldenChannels[name] as? [String: Any] else {
                XCTFail("bad golden entry \(name)")
                continue
            }
            guard let ch = session.channel(name) else {
                XCTFail("missing channel \(name)")
                continue
            }
            let rows: Int = Int(number(gc["rows"]) ?? -1)
            XCTAssertEqual(ch.values.count, rows, "\(name) rows")
            XCTAssertEqual(ch.times.count, rows, "\(name) time rows")
            let goldenUnits: String = gc["units"] as? String ?? "?"
            XCTAssertEqual(ch.units, XRKParserTests.goldenUnitOverrides[name] ?? goldenUnits, "\(name) units")

            let samples: [[String: Any]] = gc["samples"] as? [[String: Any]] ?? []
            XCTAssertFalse(samples.isEmpty, "\(name) has golden samples")
            for s in samples {
                let i: Int = Int(number(s["i"]) ?? -1)
                guard i >= 0 && i < ch.values.count else {
                    XCTFail("\(name) sample index \(i) out of range")
                    continue
                }
                XCTAssertEqual(ms(ch.times[i]), Int(number(s["t_ms"]) ?? -1), "\(name)[\(i)] time")
                assertClose(ch.values[i], number(s["v"]) ?? Double.nan, rel: 1e-6, "\(name)[\(i)] value")
            }
        }

        // Every channel: times in seconds, non-decreasing.
        for ch in session.channels {
            XCTAssertEqual(ch.times.count, ch.values.count, ch.name)
            var ok: Bool = true
            var k: Int = 1
            while k < ch.times.count {
                if ch.times[k] < ch.times[k - 1] { ok = false; break }
                k += 1
            }
            XCTAssertTrue(ok, "\(ch.name) times non-decreasing")
        }

        // Metadata
        let gm: [String: String] = try XCTUnwrap(golden["metadata"] as? [String: String])
        let meta: SessionMetadata = session.metadata
        XCTAssertEqual(meta.driver, gm["Driver"])
        XCTAssertEqual(meta.venue, gm["Venue"])
        XCTAssertEqual(meta.driver, "CMD")
        XCTAssertEqual(meta.venue, "Motegi")
        XCTAssertEqual(meta.vehicle, gm["Vehicle"])
        XCTAssertEqual(meta.deviceName, gm["Device Name"])
        XCTAssertEqual(meta.loggerID, gm["Logger ID"])
        var expectedExtraKeys: Set<String> = []
        for (key, value) in gm {
            if XRKParserTests.promotedMetadataKeys.contains(key) || XRKParserTests.metadataKeysNotPorted.contains(key) {
                continue
            }
            expectedExtraKeys.insert(key)
            XCTAssertEqual(meta.extra[key], value, "metadata \(key)")
        }
        XCTAssertEqual(Set(meta.extra.keys), expectedExtraKeys)

        // Log Date "08/02/2025" is MM/DD/YYYY (GPS week/iTOW in the file put the
        // session on 2 Aug 2025); Log Time is logger wall-clock time.
        let date: Date = try XCTUnwrap(meta.date)
        var cal: Calendar = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c: DateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(c.year, 2025)
        XCTAssertEqual(c.month, 8)
        XCTAssertEqual(c.day, 2)
        XCTAssertEqual(c.hour, 10)
        XCTAssertEqual(c.minute, 42)
        XCTAssertEqual(c.second, 36)

        // Model conveniences
        // Three laps: bestLap ignores the out and in laps, leaving lap 1.
        let best: Lap = try XCTUnwrap(session.bestLap)
        XCTAssertEqual(best.number, 1)
        XCTAssertEqual(best.duration, 156.127, accuracy: 1e-9)
        let speed: Channel = try XCTUnwrap(session.channel(ChannelName.gpsSpeed))
        XCTAssertEqual(speed.units, "m/s")
        XCTAssertLessThan(speed.values.max() ?? 0, 80.0, "GPS speed is in m/s")
    }

    func testGoldenFixtureFromDataMatchesURL() throws {
        let url: URL = try fixtureURL("ek9_motegi", "xrz")
        let a: Session = try XRKParser.parse(contentsOf: url)
        let b: Session = try XRKParser.parse(try Data(contentsOf: url))
        XCTAssertEqual(a.channels.count, b.channels.count)
        XCTAssertEqual(a.laps, b.laps)
        XCTAssertEqual(a.metadata, b.metadata)
    }

    // MARK: - Synthetic file
    //
    // Hand-built XRK exercising paths the fixture does not: (G group messages
    // with an out-of-order duplicate, (c V1/V2/V3 expansion messages, (M
    // overlap skipping, gear decoders 15 and Calculated_Gear, mV->V with an
    // int16 decoder, a 1-byte channel, duplicate names, a lap gap that libxrk
    // infers, garbage bytes, and a GPS stream split across two messages with
    // the firmware's 65533 ms timecode jump.

    private struct Expected {
        let name: String
        let units: String
        let decimals: Int
        let interpolate: Bool
        let ms: [Int]
        let values: [Double]
    }

    private static let syntheticXRK: String = """
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
"""

    private static let syntheticXRZ: String = """
eNrF1gtoW1UYB/Bzm1dfzsxkpYjoBYumIi7N6ha7a5qm760toenK8IFNHzSyEmPXaXEwg1YpMrcKnW46RkEZY1asdTrRIpVJmQ+k
zFcZMsWWEXFInVLrVlv/38256YmcWioDL4ST+33f79wv99ycRIs0ljeqNsaY4mvq2N3T0c00ijye4dMizZU1qllPlYcRp9M8BfGm
+go1R4+7vRvdno0et+duplH012S6Sc3S00XukmJPyabNlGxSX6NkQ0WzatGTO6IP9zCNzocoUd5QpVZZKIH3NSE1phcx4TDx0YpX
dXesjAnjSof99uRo/rciFi813ml06W9NaT0oQuUhtjwfrh1gwrhaDxlr6SFiTutBtLfw8Xq6dgdWRhivaQ+3pfdgEiqNe+LEq7I3
1lwkjCsdasN/6OHN9B7ovltw9XaMubwP6iEUeaRtlzCudEzaVu2Bru9Pfx4saT1YJGtBR3m4q21PV7jHGDvaH5IuS/BMcsxcy334
IzutB6tQmSOsScWemP7eGFc6hp5V1r4WdelrYfs/eqhP70G8h+uFXurLI/p7Y7ym34vc9P0hS6g01uU6vKq6wp1MGFe7D8qange6
D9WNQTWb75MmfYYMplHQynwabaj9YdqPG7erdyZ3+O5dRWyVI794YoM//1BII/aJ/knL6lRX2m4sduqUfmtABpnPVZ1IbRoj5gZW
6GpjN7E+azJa6Kq+zNPjpW+Zi1LpBYoWI73A037/qNmTSttpE/AibeW7+oD/bfMWJtRPBJLzJ+sLqKwEaTuvH/efEprxUlRD+kae
nvW/IzRTR9F7kS7gaXvZu0IzLRT1IX0XT7vKTuvNJNM9FC2lMzvry9Q/rsb8dO7E+Ryd17J6nCs4z/A3G5VXTPr9DBiViziP1/pT
lcFUZQZdIcAqjEr9pmyLpypbUpXZlKlglUblOpzHt42nKmOoDNHSWFJLjADdFUvq1xeBOh7INgJErMxm5KzY2LizsSyjIItZCl31
9C4TU11dWlj6awmBBR5oY4tLS0uFTOkMd7eGOztcIaZF6sqCqjP14P0uPHXfoQGN0t/Q3wWxTmE7he9ycSave4n9o87EBoT5mnJ4
3W9UVx0Mqe4MqruA9ma3VOq7fG2WicXt0UT8+WkHq34yrwqxH/Ehf0FlLrqnn6MXGFunbwOI53uX3SjcMbhLVUl3CfmfJI4eIr/g
ZuDG4Ka4m0N+RuKaEY8ILm99NHEe7mPuaMG+l7h9cAOCq4GbhxvhLhvuvMQdh3tPcE/A5R2Ydhzlzgn3tcR9AfeD4IbhiuH6ubsZ
blLi6HNn3rPsLsA1wvVw54L7TOJoPrfg7DdEEzG4Fu48yE9IHP0R3Sm4ANwBuDruNOQ/kjiNHp3Le/kzRHuD4ouiNi7M1YO5hjGX
l89F1xqTzPUi4icEdxzuU7gC7oLIn5a4DywKmxTcFFwCzs7dfXCjEjcNNy+4bEc0YT047VioTLp2uDckLseqMLVk2WlwBXAJ7ujz
n5C4TXA1govCBeC+4q4X7lWJux8uJrghuBa4ce6egjsmcU/DHRbcObh9cMPc7Yc7InGvw40LzuyMJo7CHeaO1mlQ4r6ESwhuM9z7
cH3cDcEdlLircPatyy4CNwUX4+4k3HMSd6tNYV7BvQw3B/cAd6fgnpG47XAtgvsczjkw7ajh7kN6fiVuN1y/4BbhPHDF3J2F2ytx
r8CNCM69IZoIwqncnYN7TOLOwE0JrhUuCpfLHf0mPCpxP8MxbdkNwu2Hm69IuotwXRLnyFSYS3ATcCfhZribheuUuK1wQcHNw52F
m+TuClyrxLXB9Qrujrxo4iLcGHdm/Ld8cKU9Z8efvr8BxER9nw==
"""

    private static let syntheticExpected: [Expected] = [
        Expected(name: "GrpA", units: "g", decimals: 2, interpolate: true,
                 ms: [10, 20, 30, 40, 50, 60, 70, 80],
                 values: [0.0, 1.5, 3.0, 4.5, 6.0, 7.5, 9.0, 10.5]),
        Expected(name: "GrpB", units: "V", decimals: 1, interpolate: false,
                 ms: [10, 20, 30, 40, 50, 60, 70, 80],
                 values: [1.2, 1.201, 1.202, 1.203, 1.204, 1.205, 1.206, 1.207]),
        Expected(name: "Gear", units: "gear", decimals: 0, interpolate: false,
                 ms: [10, 20, 30, 40, 50, 60, 70, 80],
                 values: [0.0, 1.0, 2.0, 55.0, 0.0, 1.0, 2.0, 55.0]),
        Expected(name: "ExpV1", units: "%", decimals: 2, interpolate: true,
                 ms: [10, 30, 50, 70, 90, 110, 130, 150],
                 values: [0.0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75]),
        Expected(name: "Shock", units: "mm", decimals: 0, interpolate: true,
                 ms: [16, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 50],
                 values: [2.0, 1.0, 10.0, 3.0, 100.0, 2.0, 11.0, 4.0, 101.0, 3.0, 12.0, 5.0, 102.0, 4.0, 13.0, 103.0]),
        Expected(name: "Calculated_Gear", units: "gear", decimals: 0, interpolate: false,
                 ms: [10, 60, 110],
                 values: [1.0, 3.0, 0.0]),
        Expected(name: "Dup", units: "#", decimals: 0, interpolate: true,
                 ms: [10, 110],
                 values: [7.0, 8.0]),
        Expected(name: "Dup dup 2", units: "#", decimals: 0, interpolate: true,
                 ms: [60],
                 values: [9.0]),
        Expected(name: "MCh", units: "C", decimals: 1, interpolate: false,
                 ms: [10, 20, 30, 40, 50],
                 values: [-5.0, -4.0, -3.0, -2.0, -1.0]),
        Expected(name: "Flag", units: "", decimals: 0, interpolate: false,
                 ms: [10],
                 values: [5.0]),
    ]

    private static let gpsNames: [String] = [
        "GPS Speed", "GPS Latitude", "GPS Longitude", "GPS Altitude", "GPS_Satellites", "GPS_Fix",
        "GPS_pDOP", "GPS_Position_Accuracy", "GPS_Velocity_Accuracy", "GPS_InlineAcc",
        "GPS_LateralAcc", "GPS_Yaw_Rate", "GPS_ITOW", "GPS_Week",
    ]

    private func syntheticData(_ b64: String) throws -> Data {
        return try XCTUnwrap(Data(base64Encoded: b64, options: .ignoreUnknownCharacters))
    }

    func testSyntheticXRK() throws {
        let data: Data = try syntheticData(XRKParserTests.syntheticXRK)
        XCTAssertEqual(data.count, 4043)
        let session: Session = try XRKParser.parse(data)
        assertWellFormed(session, "synthetic")

        let expectedNames: [String] = XRKParserTests.syntheticExpected.map { $0.name } + XRKParserTests.gpsNames
        XCTAssertEqual(session.channels.map { $0.name }, expectedNames)

        for e in XRKParserTests.syntheticExpected {
            guard let ch = session.channel(e.name) else {
                XCTFail("missing \(e.name)")
                continue
            }
            XCTAssertEqual(ch.units, e.units, "\(e.name) units")
            XCTAssertEqual(ch.decimals, e.decimals, "\(e.name) decimals")
            XCTAssertEqual(ch.interpolate, e.interpolate, "\(e.name) interpolate")
            XCTAssertEqual(ch.times.map { ms($0) }, e.ms, "\(e.name) times")
            XCTAssertEqual(ch.values.count, e.values.count, "\(e.name) count")
            for (i, v) in e.values.enumerated() where i < ch.values.count {
                assertClose(ch.values[i], v, rel: 1e-12, "\(e.name)[\(i)]")
            }
        }

        // GPS: 30 records at 25 Hz; the 65533 ms jump after record 11 is removed.
        let speed: Channel = try XCTUnwrap(session.channel("GPS Speed"))
        XCTAssertEqual(speed.times.map { ms($0) }, (0..<30).map { $0 * 40 })
        let spots: [(String, [Double])] = [
            ("GPS Speed", [15.41103500742244, 15.468112360595264, 16.133815419794537, 17.284747611695117]),
            ("GPS Latitude", [36.292331832083, 36.29233138807211, 36.292326503929196, 36.29231895562508]),
            ("GPS Longitude", [139.84167293835117, 139.84166682874468, 139.8415996230437, 139.84149575958162]),
            ("GPS Altitude", [33813.643652517145, 33813.373208450284, 33810.39832688601, 33805.800794023984]),
            ("GPS_InlineAcc", [0.0, 0.14545707404613495, 9.835328091867268e-05, 0.1819080412387848]),
            ("GPS_LateralAcc", [0.0, 0.18876297771930695, 0.00011596128751989454, 0.19125805795192719]),
            ("GPS_Yaw_Rate", [0.0, 6.859163284301758, 0.004039871972054243, 6.219398021697998]),
        ]
        let spotIndices: [Int] = [0, 1, 12, 29]
        for (name, values) in spots {
            let ch: Channel = try XCTUnwrap(session.channel(name), name)
            XCTAssertEqual(ch.values.count, 30, name)
            for (k, idx) in spotIndices.enumerated() where idx < ch.values.count {
                assertClose(ch.values[idx], values[k], rel: 1e-9, "\(name)[\(idx)]")
            }
        }
        let pdop: Channel = try XCTUnwrap(session.channel("GPS_pDOP"))
        assertClose(pdop.values[0], 1.4500000476837158, rel: 1e-12, "pDOP")
        XCTAssertEqual(pdop.interpolate, false)
        XCTAssertEqual(session.channel("GPS_Satellites")?.values.first, 14.0)
        XCTAssertEqual(session.channel("GPS_ITOW")?.values.last, 524631160.0)
        XCTAssertEqual(session.channel("GPS_Week")?.values.first, 2377.0)

        // LAP messages 0, 1, 3 (lap 2 inferred); times relative to the
        // earliest timecode in the file (the first GPS record).
        XCTAssertEqual(session.laps.map { $0.number }, [0, 1, 2, 3])
        XCTAssertEqual(session.laps.map { ms($0.start) }, [10, 510, 1110, 1510])
        XCTAssertEqual(session.laps.map { ms($0.end) }, [510, 1110, 1510, 1910])

        let meta: SessionMetadata = session.metadata
        XCTAssertEqual(meta.driver, "Tester")
        XCTAssertEqual(meta.vehicle, "Car")
        XCTAssertEqual(meta.venue, "Trk1")
        XCTAssertEqual(meta.deviceName, "Unit")
        XCTAssertEqual(meta.loggerID, "")
        XCTAssertEqual(meta.extra["Log Date"], "08/02/2025")
        XCTAssertEqual(meta.extra["Log Time"], "10:42:36")
        XCTAssertEqual(meta.extra["Calibrations"], "[{'type': 20, 'raw_1': 0.5, 'raw_2': 2.0, 'channel': 'Shock'}]")
        XCTAssertNotNil(meta.date)
    }

    func testSyntheticXRZMatchesXRK() throws {
        let raw: Session = try XRKParser.parse(try syntheticData(XRKParserTests.syntheticXRK))
        let compressed: Data = try syntheticData(XRKParserTests.syntheticXRZ)
        XCTAssertEqual(compressed.first, 0x78)
        let fromXRZ: Session = try XRKParser.parse(compressed)
        XCTAssertEqual(fromXRZ, raw)
    }

    // MARK: - Robustness

    func testEmptyAndGarbageInputThrows() {
        assertThrowsXRKError(Data(), "empty")
        assertThrowsXRKError(Data([0x78]), "one byte")
        assertThrowsXRKError(Data([0x78, 0x9C]), "bare zlib header")
        assertThrowsXRKError(Data("<h".utf8), "lone opcode")
        var rng: SeededBytes = SeededBytes(seed: 42)
        for size in [1, 2, 19, 20, 64, 1000, 65_536, 1_000_000] {
            assertThrowsXRKError(Data(rng.bytes(size)), "random \(size) bytes")
        }
        for size in [3, 100, 10_000] {
            var bytes: [UInt8] = [0x78, 0x9C]
            bytes.append(contentsOf: rng.bytes(size))
            assertThrowsXRKError(Data(bytes), "zlib magic + \(size) random bytes")
        }
        // Plausible-looking framing with nothing valid inside.
        var framed: [UInt8] = []
        for _ in 0..<2000 {
            let sOpen: [UInt8] = [0x28, 0x53]
            let sClose: [UInt8] = [0x29]
            let hOpen: [UInt8] = [0x3C, 0x68]
            let hClose: [UInt8] = [0x3E]
            framed.append(contentsOf: sOpen + rng.bytes(9) + sClose)
            framed.append(contentsOf: hOpen + rng.bytes(10) + hClose)
        }
        assertThrowsXRKError(Data(framed), "random framed messages")
    }

    func testTruncatedFixtureXRZ() throws {
        let full: Data = try Data(contentsOf: try fixtureURL("ek9_motegi", "xrz"))
        // Too short to inflate anything useful.
        for n in [2, 3, 100] {
            assertThrowsXRKError(full.prefix(n), "xrz prefix \(n)")
        }
        // Header block only, no samples yet.
        assertThrowsXRKError(full.prefix(1000), "xrz prefix 1000")
        // Longer prefixes recover whatever was logged before the cut.
        for n in [54_321, full.count / 2] {
            let s: Session = try XRKParser.parse(full.prefix(n))
            assertWellFormed(s, "xrz prefix \(n)")
            XCTAssertNotNil(s.channel("InlineAcc"))
        }
        let half: Session = try XRKParser.parse(full.prefix(full.count / 2))
        XCTAssertEqual(half.laps.count, 1)
        XCTAssertEqual(half.channel("InlineAcc")?.values.first, 0.044189453125)
    }

    func testEveryPrefixOfSyntheticFileIsHandled() throws {
        let bytes: [UInt8] = [UInt8](try syntheticData(XRKParserTests.syntheticXRK))
        var parsed: Int = 0
        for n in 0...bytes.count {
            if let s = try? XRKParser.parse(Data(bytes[0..<n])) {
                assertWellFormed(s, "prefix \(n)")
                parsed += 1
            }
        }
        XCTAssertGreaterThan(parsed, 0)
        let xrz: [UInt8] = [UInt8](try syntheticData(XRKParserTests.syntheticXRZ))
        for n in 0...xrz.count {
            if let s = try? XRKParser.parse(Data(xrz[0..<n])) {
                assertWellFormed(s, "xrz prefix \(n)")
            }
        }
    }

    func testCorruptedBytesDoNotCrash() throws {
        let bytes: [UInt8] = [UInt8](try syntheticData(XRKParserTests.syntheticXRK))
        var rng: SeededBytes = SeededBytes(seed: 7)
        for i in 0..<bytes.count {
            var copy: [UInt8] = bytes
            copy[i] ^= 0xFF
            if let s = try? XRKParser.parse(Data(copy)) {
                assertWellFormed(s, "flip at \(i)")
            }
            if i % 3 == 0 {
                var noisy: [UInt8] = bytes
                noisy[i] = rng.next()
                if i + 1 < noisy.count { noisy[i + 1] = rng.next() }
                if let s = try? XRKParser.parse(Data(noisy)) {
                    assertWellFormed(s, "noise at \(i)")
                }
            }
        }
        let xrz: [UInt8] = [UInt8](try syntheticData(XRKParserTests.syntheticXRZ))
        for i in 2..<xrz.count {
            var copy: [UInt8] = xrz
            copy[i] ^= 0x5A
            if let s = try? XRKParser.parse(Data(copy)) {
                assertWellFormed(s, "xrz flip at \(i)")
            }
        }
    }
}
