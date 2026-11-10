import Foundation

/// Internal helpers shared by the analysis types.
enum GridInterp {
    /// Linear interpolation of `ys` over ascending `xs`, clamped at both ends.
    /// Returns 0 for empty input.
    static func value(xs: [Double], ys: [Double], at x: Double) -> Double {
        let n: Int = Swift.min(xs.count, ys.count)
        if n == 0 { return 0 }
        if x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }
        var lo: Int = 0
        var hi: Int = n - 1
        while hi - lo > 1 {
            let mid: Int = (lo + hi) / 2
            if xs[mid] <= x { lo = mid } else { hi = mid }
        }
        let span: Double = xs[hi] - xs[lo]
        if span <= 0 { return ys[lo] }
        let f: Double = (x - xs[lo]) / span
        return ys[lo] + f * (ys[hi] - ys[lo])
    }
}

/// One piece of a channel inside a window, split at every sample time so the
/// channel is linear (or constant, for step channels) within the piece.
struct WindowSegment {
    var duration: Double
    /// Channel value at the piece midpoint.
    var mid: Double
    var minValue: Double
    var maxValue: Double
}

enum WindowSampling {
    static func segments(channel: Channel, start: Double, end: Double) -> [WindowSegment] {
        guard end > start, !channel.times.isEmpty else { return [] }
        var points: [Double] = [start]
        let n: Int = Swift.min(channel.times.count, channel.values.count)
        for i in 0..<n {
            let t: Double = channel.times[i]
            if t > start && t < end { points.append(t) }
        }
        points.append(end)
        var result: [WindowSegment] = []
        if points.count < 2 { return result }
        for i in 0..<(points.count - 1) {
            let a: Double = points[i]
            let b: Double = points[i + 1]
            let duration: Double = b - a
            if duration <= 0 { continue }
            guard let mid = channel.value(at: (a + b) / 2), mid.isFinite else { continue }
            var lo: Double = mid
            var hi: Double = mid
            if channel.interpolate {
                if let va = channel.value(at: a), let vb = channel.value(at: b), va.isFinite, vb.isFinite {
                    lo = Swift.min(va, vb)
                    hi = Swift.max(va, vb)
                }
            }
            result.append(WindowSegment(duration: duration, mid: mid, minValue: lo, maxValue: hi))
        }
        return result
    }
}
