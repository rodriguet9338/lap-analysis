import Foundation

public struct SplitResult: Sendable {
    public var index: Int
    public var startDistance: Double
    public var endDistance: Double
    public var time: Double

    public init(index: Int, startDistance: Double, endDistance: Double, time: Double) {
        self.index = index
        self.startDistance = startDistance
        self.endDistance = endDistance
        self.time = time
    }
}

public enum Splits {
    /// Split times for a lap given split boundaries in metres (ascending, exclusive of 0 and lap end).
    public static func times(trace: LapTrace, boundaries: [Double]) -> [SplitResult] {
        let length: Double = trace.length
        var valid: [Double] = []
        for b in boundaries where b.isFinite && b > 0 && b < length {
            valid.append(b)
        }
        valid.sort()

        var edges: [Double] = [0]
        edges.append(contentsOf: valid)
        edges.append(length)

        var edgeTimes: [Double] = []
        for e in edges {
            edgeTimes.append(timeAt(distance: e, trace: trace))
        }

        var results: [SplitResult] = []
        for i in 0..<(edges.count - 1) {
            results.append(SplitResult(index: i,
                                       startDistance: edges[i],
                                       endDistance: edges[i + 1],
                                       time: edgeTimes[i + 1] - edgeTimes[i]))
        }
        return results
    }

    /// n equal-distance boundaries (n interior boundaries, giving n + 1 splits).
    public static func equalBoundaries(length: Double, count: Int) -> [Double] {
        guard count >= 1, length > 0 else { return [] }
        var out: [Double] = []
        for i in 1...count {
            out.append(length * Double(i) / Double(count + 1))
        }
        return out
    }

    /// Sum of the best time per split across laps ("theoretical best").
    public static func theoreticalBest(_ perLap: [[SplitResult]]) -> Double? {
        guard let first = perLap.first else { return nil }
        let splitCount: Int = first.count
        if splitCount == 0 { return nil }
        for lap in perLap where lap.count != splitCount { return nil }
        var total: Double = 0
        for s in 0..<splitCount {
            var best: Double = perLap[0][s].time
            for lap in perLap where lap[s].time < best {
                best = lap[s].time
            }
            total += best
        }
        return total
    }

    /// Lap time (seconds since lap start) at a distance. The stretch between
    /// the last grid point and the lap end is interpolated so the final
    /// edge lands exactly on lap.duration.
    static func timeAt(distance d: Double, trace: LapTrace) -> Double {
        if d <= 0 { return 0 }
        if d >= trace.length { return trace.lap.duration }
        guard let lastD = trace.distance.last, let lastT = trace.time.last else {
            return trace.lap.duration * d / trace.length
        }
        if d <= lastD {
            return GridInterp.value(xs: trace.distance, ys: trace.time, at: d)
        }
        let span: Double = trace.length - lastD
        if span <= 0 { return trace.lap.duration }
        let f: Double = (d - lastD) / span
        return lastT + f * (trace.lap.duration - lastT)
    }
}
