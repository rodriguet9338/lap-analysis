import Foundation

struct PlotPoint: Sendable {
    let x: Double
    let y: Double
}

struct PlotSeries: Identifiable, Sendable {
    let id: String
    let label: String
    let colorIndex: Int
    let isReference: Bool
    let points: [PlotPoint]

    /// Linear interpolation of the (downsampled) series at x.
    func value(at x: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        var lo: Int = 0
        var hi: Int = points.count - 1
        while hi - lo > 1 {
            let mid: Int = (lo + hi) / 2
            if points[mid].x <= x { lo = mid } else { hi = mid }
        }
        let a: PlotPoint = points[lo]
        let b: PlotPoint = points[hi]
        let span: Double = b.x - a.x
        guard span > 0 else { return a.y }
        return a.y + (x - a.x) / span * (b.y - a.y)
    }
}

/// Min/max-per-bucket downsampler.
///
/// When a series has more than `maxPoints` samples, the interior is split into
/// equal-count buckets; from each bucket we keep the sample with the smallest y
/// and the one with the largest y (emitted in original x order), so spikes and
/// dips survive. The first and last samples are always kept. Output size is at
/// most `maxPoints`. Non-finite samples are dropped.
enum Downsampler {
    static let defaultMaxPoints: Int = 1500

    static func downsample(x: [Double], y: [Double], maxPoints: Int = Downsampler.defaultMaxPoints) -> [PlotPoint] {
        let n: Int = min(x.count, y.count)
        if n == 0 { return [] }
        var out: [PlotPoint] = []
        out.reserveCapacity(min(n, maxPoints) + 2)

        if n <= maxPoints {
            for i in 0..<n {
                if x[i].isFinite && y[i].isFinite {
                    out.append(PlotPoint(x: x[i], y: y[i]))
                }
            }
            return out
        }

        if x[0].isFinite && y[0].isFinite { out.append(PlotPoint(x: x[0], y: y[0])) }

        let buckets: Int = max(1, maxPoints / 2 - 1)
        let interior: Int = n - 2
        let bucketSize: Double = Double(interior) / Double(buckets)
        for b in 0..<buckets {
            let lo: Int = 1 + Int(Double(b) * bucketSize)
            let hi: Int = min(1 + Int(Double(b + 1) * bucketSize), n - 1)
            if lo >= hi { continue }
            var minI: Int = -1
            var maxI: Int = -1
            for i in lo..<hi {
                if !(x[i].isFinite && y[i].isFinite) { continue }
                if minI < 0 || y[i] < y[minI] { minI = i }
                if maxI < 0 || y[i] > y[maxI] { maxI = i }
            }
            if minI < 0 { continue }
            if minI == maxI {
                out.append(PlotPoint(x: x[minI], y: y[minI]))
            } else {
                let first: Int = min(minI, maxI)
                let second: Int = max(minI, maxI)
                out.append(PlotPoint(x: x[first], y: y[first]))
                out.append(PlotPoint(x: x[second], y: y[second]))
            }
        }

        let last: Int = n - 1
        if x[last].isFinite && y[last].isFinite { out.append(PlotPoint(x: x[last], y: y[last])) }
        return out
    }

    /// Evenly spaced indices (always including 0 and n-1) with at most maxCount entries.
    static func sampleIndices(count n: Int, maxCount: Int) -> [Int] {
        if n <= 0 { return [] }
        if n <= maxCount { return Array(0..<n) }
        var out: [Int] = []
        out.reserveCapacity(maxCount)
        let denom: Double = Double(max(maxCount - 1, 1))
        for k in 0..<maxCount {
            let idx: Int = Int((Double(k) * Double(n - 1) / denom).rounded())
            out.append(min(idx, n - 1))
        }
        return out
    }
}
