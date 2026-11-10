import XCTest
import LapCore

final class AnalysisTests: XCTestCase {

    private func makeSession(speed: Double, duration: Double, rate: Double = 10) -> Session {
        let n: Int = Int(duration * rate)
        var times: [Double] = []
        var values: [Double] = []
        for i in 0...n {
            times.append(Double(i) / rate)
            values.append(speed)
        }
        let ch = Channel(name: ChannelName.gpsSpeed, units: "m/s", times: times, values: values)
        return Session(channels: [ch], laps: [Lap(number: 1, start: 0, end: duration)])
    }

    private func makeTrace(speed: Double, duration: Double) -> LapTrace {
        let session = makeSession(speed: speed, duration: duration)
        let trace = LapResampler.trace(session: session, lap: session.laps[0])
        XCTAssertNotNil(trace)
        return trace!
    }

    func testConstantSpeedTrace() {
        let trace = makeTrace(speed: 20, duration: 10)
        XCTAssertEqual(trace.length, 200, accuracy: 1e-6)
        XCTAssertEqual(trace.distance.count, 201)
        XCTAssertEqual(trace.time.count, 201)
        XCTAssertEqual(trace.distance[100], 100, accuracy: 1e-9)
        XCTAssertEqual(trace.time[0], 0, accuracy: 1e-9)
        XCTAssertEqual(trace.time[100], 5.0, accuracy: 1e-6)
        XCTAssertEqual(trace.time[200], 10.0, accuracy: 1e-6)
        XCTAssertEqual(trace.label, "L1 0:10.000")
        XCTAssertEqual(trace.channels[ChannelName.gpsSpeed]?.count, 201)
        XCTAssertEqual(trace.channels[ChannelName.gpsSpeed]?[50] ?? 0, 20, accuracy: 1e-9)
    }

    func testTraceNilWithoutGPSSpeed() {
        let ch = Channel(name: "RPM", times: [0, 1, 2], values: [1000, 2000, 3000])
        let session = Session(channels: [ch], laps: [Lap(number: 1, start: 0, end: 2)])
        XCTAssertNil(LapResampler.trace(session: session, lap: session.laps[0]))
    }

    func testDeltaSignAndGrowth() {
        let fast = makeTrace(speed: 20, duration: 10)   // 200 m in 10 s
        let slow = makeTrace(speed: 10, duration: 20)   // 200 m in 20 s
        let delta = LapDelta.timeDelta(reference: fast, lap: slow)
        XCTAssertEqual(delta.count, fast.distance.count)
        XCTAssertEqual(delta[0], 0, accuracy: 1e-9)
        XCTAssertEqual(delta[100], 5.0, accuracy: 1e-6)
        XCTAssertEqual(delta[200], 10.0, accuracy: 1e-6)
        XCTAssertGreaterThan(delta[150], delta[50])
        let reverse = LapDelta.timeDelta(reference: slow, lap: fast)
        XCTAssertLessThan(reverse[100], 0)
    }

    func testDeltaScalesForDifferentLengths() {
        let reference = makeTrace(speed: 20, duration: 10)  // 200 m
        let shorter = makeTrace(speed: 10, duration: 10)    // 100 m, same elapsed time
        let delta = LapDelta.timeDelta(reference: reference, lap: shorter)
        for d in delta {
            XCTAssertEqual(d, 0, accuracy: 1e-6)
        }
    }

    func testSplitTimesSumToLapDuration() {
        let trace = makeTrace(speed: 20, duration: 10)
        let splits = Splits.times(trace: trace, boundaries: [50, 150])
        XCTAssertEqual(splits.count, 3)
        XCTAssertEqual(splits[0].time, 2.5, accuracy: 1e-6)
        XCTAssertEqual(splits[1].time, 5.0, accuracy: 1e-6)
        XCTAssertEqual(splits[2].time, 2.5, accuracy: 1e-6)
        XCTAssertEqual(splits[2].startDistance, 150, accuracy: 1e-9)
        XCTAssertEqual(splits[2].endDistance, trace.length, accuracy: 1e-9)
        let sum = splits.reduce(0.0) { $0 + $1.time }
        XCTAssertEqual(sum, trace.lap.duration, accuracy: 1e-9)
    }

    func testSplitSumWhenLengthIsNotGridAligned() {
        let trace = makeTrace(speed: 15.3, duration: 7)   // 107.1 m, grid ends at 107
        XCTAssertEqual(trace.length, 107.1, accuracy: 1e-6)
        XCTAssertEqual(trace.distance.last ?? 0, 107, accuracy: 1e-9)
        let splits = Splits.times(trace: trace, boundaries: [0, 50, 107.5, 500])
        XCTAssertEqual(splits.count, 2)
        let sum = splits.reduce(0.0) { $0 + $1.time }
        XCTAssertEqual(sum, 7.0, accuracy: 1e-9)
    }

    func testEqualBoundaries() {
        let b = Splits.equalBoundaries(length: 100, count: 3)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b[0], 25, accuracy: 1e-9)
        XCTAssertEqual(b[2], 75, accuracy: 1e-9)
    }

    func testTheoreticalBest() {
        let lapA: [SplitResult] = [
            SplitResult(index: 0, startDistance: 0, endDistance: 50, time: 10),
            SplitResult(index: 1, startDistance: 50, endDistance: 100, time: 12),
        ]
        let lapB: [SplitResult] = [
            SplitResult(index: 0, startDistance: 0, endDistance: 50, time: 11),
            SplitResult(index: 1, startDistance: 50, endDistance: 100, time: 9),
        ]
        XCTAssertEqual(Splits.theoreticalBest([lapA, lapB]) ?? -1, 19, accuracy: 1e-9)
        XCTAssertNil(Splits.theoreticalBest([]))
        XCTAssertNil(Splits.theoreticalBest([lapA, [lapB[0]]]))
    }

    func testHistogramRampFractions() {
        var times: [Double] = []
        var values: [Double] = []
        for i in 0...10 {
            times.append(Double(i))
            values.append(Double(i))
        }
        let ch = Channel(name: "Ramp", times: times, values: values)
        let bins = Histogram.bins(channel: ch, start: 0, end: 10, binCount: 5)
        XCTAssertEqual(bins.count, 5)
        let total = bins.reduce(0.0) { $0 + $1.fraction }
        XCTAssertEqual(total, 1.0, accuracy: 1e-9)
        for b in bins {
            XCTAssertEqual(b.fraction, 0.2, accuracy: 1e-9)
            XCTAssertEqual(b.seconds, 2.0, accuracy: 1e-9)
        }
        XCTAssertEqual(bins[0].lower, 0, accuracy: 1e-9)
        XCTAssertEqual(bins[4].upper, 10, accuracy: 1e-9)
    }

    func testHistogramStepSignal() {
        // 0 for the first 3 s, 10 for the last 7 s (step channel, forward-filled).
        let ch = Channel(name: "Step", interpolate: false,
                         times: [0, 3, 10], values: [0, 10, 10])
        let bins = Histogram.bins(channel: ch, start: 0, end: 10, binCount: 2)
        XCTAssertEqual(bins.count, 2)
        XCTAssertEqual(bins[0].fraction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(bins[1].fraction, 0.7, accuracy: 1e-9)
        XCTAssertEqual(bins[0].fraction + bins[1].fraction, 1.0, accuracy: 1e-9)
    }

    func testHistogramEdgeCases() {
        let flat = Channel(name: "Flat", times: [0, 5, 10], values: [4, 4, 4])
        let bins = Histogram.bins(channel: flat, start: 0, end: 10, binCount: 8)
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins[0].fraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(bins[0].seconds, 10.0, accuracy: 1e-9)
        XCTAssertTrue(Histogram.bins(channel: Channel(name: "Empty"), start: 0, end: 10, binCount: 4).isEmpty)
        XCTAssertTrue(Histogram.bins(channel: flat, start: 5, end: 5, binCount: 4).isEmpty)
    }

    func testStatsOnRamp() {
        var times: [Double] = []
        var values: [Double] = []
        for i in 0...10 {
            times.append(Double(i))
            values.append(Double(i))
        }
        let ch = Channel(name: "Ramp", times: times, values: values)
        let all = Stats.stats(channel: ch, start: 0, end: 10)
        XCTAssertNotNil(all)
        XCTAssertEqual(all?.min ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(all?.max ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(all?.mean ?? -1, 5, accuracy: 1e-9)
        let part = Stats.stats(channel: ch, start: 2.5, end: 6.5)
        XCTAssertEqual(part?.min ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertEqual(part?.max ?? -1, 6.5, accuracy: 1e-9)
        XCTAssertEqual(part?.mean ?? -1, 4.5, accuracy: 1e-9)
        XCTAssertNil(Stats.stats(channel: Channel(name: "Empty"), start: 0, end: 1))
    }

    func testHaversineOneDegreeLatitude() {
        let d = Geo.haversine(lat1: 0, lon1: 0, lat2: 1, lon2: 0)
        XCTAssertEqual(d, 111_200, accuracy: 300)
        XCTAssertEqual(Geo.haversine(lat1: 10, lon1: 20, lat2: 10, lon2: 20), 0, accuracy: 1e-9)
    }

    func testProjectScale() {
        let pts = Geo.project(latitude: [32.0, 32.001], longitude: [-117.0, -117.0])
        XCTAssertEqual(pts.count, 2)
        XCTAssertEqual(pts[1].y - pts[0].y, 111.19, accuracy: 0.1)
        XCTAssertEqual(pts[1].x - pts[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y + pts[1].y, 0, accuracy: 1e-9)   // centred on the mean
        XCTAssertTrue(Geo.project(latitude: [], longitude: []).isEmpty)
    }
}
