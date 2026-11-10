import Foundation

public struct HistogramBin: Sendable {
    public var lower: Double
    public var upper: Double
    public var seconds: Double
    public var fraction: Double

    public init(lower: Double, upper: Double, seconds: Double, fraction: Double) {
        self.lower = lower
        self.upper = upper
        self.seconds = seconds
        self.fraction = fraction
    }
}

public enum Histogram {
    /// Time-weighted histogram of a channel within [start, end] (session seconds).
    public static func bins(channel: Channel, start: Double, end: Double, binCount: Int) -> [HistogramBin] {
        guard binCount >= 1 else { return [] }
        let segments: [WindowSegment] = WindowSampling.segments(channel: channel, start: start, end: end)
        if segments.isEmpty { return [] }

        var lo: Double = segments[0].minValue
        var hi: Double = segments[0].maxValue
        var totalSeconds: Double = 0
        for s in segments {
            lo = Swift.min(lo, s.minValue)
            hi = Swift.max(hi, s.maxValue)
            totalSeconds += s.duration
        }
        if totalSeconds <= 0 { return [] }

        if hi <= lo {
            return [HistogramBin(lower: lo, upper: lo, seconds: totalSeconds, fraction: 1.0)]
        }

        let width: Double = (hi - lo) / Double(binCount)
        var seconds: [Double] = [Double](repeating: 0, count: binCount)
        for s in segments {
            var idx: Int = Int(((s.mid - lo) / width).rounded(.down))
            if idx < 0 { idx = 0 }
            if idx > binCount - 1 { idx = binCount - 1 }
            seconds[idx] += s.duration
        }
        var out: [HistogramBin] = []
        for i in 0..<binCount {
            out.append(HistogramBin(lower: lo + Double(i) * width,
                                    upper: lo + Double(i + 1) * width,
                                    seconds: seconds[i],
                                    fraction: seconds[i] / totalSeconds))
        }
        return out
    }
}
