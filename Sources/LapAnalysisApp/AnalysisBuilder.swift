import Foundation
import LapCore

struct MapLap: Sendable {
    let id: String
    let colorIndex: Int
    let x: [Double]
    let y: [Double]

    /// Position at a fraction (0...1) of the lap's length (arrays are uniformly strided).
    func position(fraction: Double) -> (x: Double, y: Double)? {
        let n: Int = min(x.count, y.count)
        guard n >= 2 else { return nil }
        let f: Double = min(max(fraction, 0), 1) * Double(n - 1)
        let i: Int = min(Int(f), n - 2)
        let t: Double = f - Double(i)
        let px: Double = x[i] + t * (x[i + 1] - x[i])
        let py: Double = y[i] + t * (y[i + 1] - y[i])
        guard px.isFinite && py.isFinite else { return nil }
        return (px, py)
    }
}

struct MapData: Sendable {
    var refX: [Double]
    var refY: [Double]
    var speedNorm: [Double]
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
    var laps: [MapLap]
}

struct SplitRow: Identifiable, Sendable {
    let id: String
    let label: String
    let colorIndex: Int
    let times: [Double]
    let total: Double
}

struct SplitTable: Sendable {
    var rows: [SplitRow]
    var columnCount: Int
    var bestPerSplit: [Double]
    var theoreticalBest: Double?

    static let empty: SplitTable = SplitTable(rows: [], columnCount: 0, bestPerSplit: [], theoreticalBest: nil)
}

struct AnalysisResult: Sendable {
    var channelSeries: [PlotSeries]
    var deltaSeries: [PlotSeries]
    var map: MapData?
    var splits: SplitTable
    /// Length (m) of the reference lap; the shared X axis spans 0...xMax.
    var refLength: Double
    var xMax: Double

    static let empty: AnalysisResult = AnalysisResult(
        channelSeries: [], deltaSeries: [], map: nil, splits: SplitTable.empty, refLength: 0, xMax: 1
    )
}

/// All heavy work for the analysis area. Runs off the main thread.
///
/// Distance alignment: every lap's distance axis is scaled by
/// refLength / lap.length so all laps share the reference's X axis (same
/// convention LapDelta uses), and the shared cursor means the same place on track.
enum AnalysisBuilder {
    static func build(_ input: AnalysisInput) -> AnalysisResult {
        let refTrace: LapTrace? = input.reference?.trace
        let refLength: Double = refTrace?.length ?? 0

        var channelSeries: [PlotSeries] = []
        var deltaSeries: [PlotSeries] = []
        var maxX: Double = 0

        for entry in input.laps {
            let trace: LapTrace = entry.trace
            let isRef: Bool = (entry.key == input.referenceKey)

            if let values = trace.channels[input.channel] {
                let scale: Double = (refLength > 0 && trace.length > 0) ? refLength / trace.length : 1.0
                let n: Int = min(trace.distance.count, values.count)
                var xs: [Double] = []
                var ys: [Double] = []
                xs.reserveCapacity(n)
                ys.reserveCapacity(n)
                for i in 0..<n {
                    xs.append(trace.distance[i] * scale)
                    ys.append(values[i] * input.channelScale)
                }
                if let lastX = xs.last { maxX = max(maxX, lastX) }
                let pts: [PlotPoint] = Downsampler.downsample(x: xs, y: ys)
                channelSeries.append(PlotSeries(id: entry.key.stringID, label: entry.label,
                                                colorIndex: entry.colorIndex, isReference: isRef, points: pts))
            }

            if let ref = refTrace, !isRef {
                let d: [Double] = LapDelta.timeDelta(reference: ref, lap: trace)
                let n: Int = min(ref.distance.count, d.count)
                var xs: [Double] = []
                var ys: [Double] = []
                xs.reserveCapacity(n)
                ys.reserveCapacity(n)
                for i in 0..<n {
                    xs.append(ref.distance[i])
                    ys.append(d[i])
                }
                let pts: [PlotPoint] = Downsampler.downsample(x: xs, y: ys)
                deltaSeries.append(PlotSeries(id: entry.key.stringID, label: entry.label,
                                              colorIndex: entry.colorIndex, isReference: false, points: pts))
            }
        }

        let mapTrace: LapTrace? = refTrace ?? input.laps.first?.trace
        let map: MapData? = mapTrace.flatMap { (t: LapTrace) -> MapData? in
            buildMap(reference: t, laps: input.laps)
        }
        let splits: SplitTable = buildSplits(laps: input.laps, count: input.splitCount)

        return AnalysisResult(channelSeries: channelSeries, deltaSeries: deltaSeries, map: map,
                              splits: splits, refLength: refLength,
                              xMax: max(refLength, maxX, 1))
    }

    // MARK: Map

    private static func pick(_ a: [Double], _ idx: [Int]) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(idx.count)
        for i in idx {
            out.append(i < a.count ? a[i] : Double.nan)
        }
        return out
    }

    static func buildMap(reference ref: LapTrace, laps: [LapEntry]) -> MapData? {
        let maxPts: Int = Downsampler.defaultMaxPoints
        let refN: Int = min(ref.latitude.count, ref.longitude.count)
        let refIdx: [Int] = Downsampler.sampleIndices(count: refN, maxCount: maxPts)
        guard refIdx.count >= 2 else { return nil }

        // One concatenated projection so every lap shares the same origin
        // regardless of how Geo.project chooses it.
        var lat: [Double] = pick(ref.latitude, refIdx)
        var lon: [Double] = pick(ref.longitude, refIdx)
        let refCount: Int = lat.count

        var lapRanges: [(entry: LapEntry, start: Int, count: Int)] = []
        for entry in laps {
            let n: Int = min(entry.trace.latitude.count, entry.trace.longitude.count)
            let idx: [Int] = Downsampler.sampleIndices(count: n, maxCount: maxPts)
            if idx.count < 2 { continue }
            let start: Int = lat.count
            lat.append(contentsOf: pick(entry.trace.latitude, idx))
            lon.append(contentsOf: pick(entry.trace.longitude, idx))
            lapRanges.append((entry: entry, start: start, count: idx.count))
        }

        let projected: [(x: Double, y: Double)] = Geo.project(latitude: lat, longitude: lon)
        guard projected.count == lat.count else { return nil }

        var refX: [Double] = []
        var refY: [Double] = []
        for i in 0..<refCount {
            refX.append(projected[i].x)
            refY.append(projected[i].y)
        }

        var minX: Double = Double.greatestFiniteMagnitude
        var maxX: Double = -Double.greatestFiniteMagnitude
        var minY: Double = Double.greatestFiniteMagnitude
        var maxY: Double = -Double.greatestFiniteMagnitude
        for i in 0..<refCount {
            let px: Double = refX[i]
            let py: Double = refY[i]
            if px.isFinite && py.isFinite {
                minX = min(minX, px)
                maxX = max(maxX, px)
                minY = min(minY, py)
                maxY = max(maxY, py)
            }
        }
        guard minX <= maxX && minY <= maxY else { return nil }

        var speedNorm: [Double] = [Double](repeating: 0.5, count: refCount)
        if let speeds = ref.channels[ChannelName.gpsSpeed] {
            let s: [Double] = pick(speeds, refIdx)
            var lo: Double = Double.greatestFiniteMagnitude
            var hi: Double = -Double.greatestFiniteMagnitude
            for v in s where v.isFinite {
                lo = min(lo, v)
                hi = max(hi, v)
            }
            if hi > lo {
                for i in 0..<refCount {
                    let v: Double = s[i]
                    speedNorm[i] = v.isFinite ? (v - lo) / (hi - lo) : 0.5
                }
            }
        }

        var mapLaps: [MapLap] = []
        for r in lapRanges {
            var xs: [Double] = []
            var ys: [Double] = []
            xs.reserveCapacity(r.count)
            ys.reserveCapacity(r.count)
            for i in r.start..<(r.start + r.count) {
                xs.append(projected[i].x)
                ys.append(projected[i].y)
            }
            mapLaps.append(MapLap(id: r.entry.key.stringID, colorIndex: r.entry.colorIndex, x: xs, y: ys))
        }

        return MapData(refX: refX, refY: refY, speedNorm: speedNorm,
                       minX: minX, maxX: maxX, minY: minY, maxY: maxY, laps: mapLaps)
    }

    // MARK: Splits

    /// Boundaries are computed here (count-1 interior boundaries, giving `count` splits)
    /// rather than via Splits.equalBoundaries, whose doc is ambiguous about whether
    /// `count` is a number of boundaries or of splits.
    static func buildSplits(laps: [LapEntry], count: Int) -> SplitTable {
        guard count >= 2 else { return SplitTable.empty }
        var rows: [SplitRow] = []
        var perLap: [[SplitResult]] = []
        for entry in laps {
            let len: Double = entry.trace.length
            if !(len > 0) { continue }
            var boundaries: [Double] = []
            for i in 1..<count {
                boundaries.append(Double(i) * len / Double(count))
            }
            let results: [SplitResult] = Splits.times(trace: entry.trace, boundaries: boundaries)
            if results.isEmpty { continue }
            let sorted: [SplitResult] = results.sorted { (a: SplitResult, b: SplitResult) -> Bool in a.index < b.index }
            perLap.append(sorted)
            rows.append(SplitRow(id: entry.key.stringID, label: entry.label, colorIndex: entry.colorIndex,
                                 times: sorted.map { (r: SplitResult) -> Double in r.time },
                                 total: entry.trace.lap.duration))
        }
        if rows.isEmpty { return SplitTable.empty }

        var columns: Int = 0
        for r in rows { columns = max(columns, r.times.count) }
        var best: [Double] = []
        for j in 0..<columns {
            var m: Double = Double.infinity
            for r in rows where j < r.times.count && r.times[j].isFinite {
                m = min(m, r.times[j])
            }
            best.append(m)
        }
        return SplitTable(rows: rows, columnCount: columns, bestPerSplit: best,
                          theoreticalBest: Splits.theoreticalBest(perLap))
    }
}
