import Foundation

public enum LapDelta {
    /// time(lap) - time(reference) at each of the reference's grid points.
    /// The compared lap's distance is scaled by reference.length / lap.length
    /// first, so line differences don't accumulate as fake time loss.
    /// Positive = `lap` is behind the reference.
    public static func timeDelta(reference: LapTrace, lap: LapTrace) -> [Double] {
        let count: Int = reference.distance.count
        if count == 0 { return [] }
        guard !lap.distance.isEmpty, !lap.time.isEmpty else {
            return [Double](repeating: 0, count: count)
        }
        let ratio: Double = (reference.length > 0 && lap.length > 0) ? lap.length / reference.length : 1.0
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let q: Double = reference.distance[i] * ratio
            let t: Double = GridInterp.value(xs: lap.distance, ys: lap.time, at: q)
            let r: Double = i < reference.time.count ? reference.time[i] : 0
            out.append(t - r)
        }
        return out
    }
}
