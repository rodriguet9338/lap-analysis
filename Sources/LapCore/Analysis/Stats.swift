import Foundation

public struct ChannelStats: Sendable {
    public var min: Double
    public var max: Double
    public var mean: Double

    public init(min: Double, max: Double, mean: Double) {
        self.min = min
        self.max = max
        self.mean = mean
    }
}

public enum Stats {
    public static func stats(channel: Channel, start: Double, end: Double) -> ChannelStats? {
        let segments: [WindowSegment] = WindowSampling.segments(channel: channel, start: start, end: end)
        if segments.isEmpty { return nil }
        var lo: Double = segments[0].minValue
        var hi: Double = segments[0].maxValue
        var weighted: Double = 0
        var total: Double = 0
        for s in segments {
            lo = Swift.min(lo, s.minValue)
            hi = Swift.max(hi, s.maxValue)
            weighted += s.mid * s.duration
            total += s.duration
        }
        if total <= 0 { return nil }
        return ChannelStats(min: lo, max: hi, mean: weighted / total)
    }
}
