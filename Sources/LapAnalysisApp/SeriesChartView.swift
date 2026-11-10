import SwiftUI
import Charts

/// One distance-based line chart. Used for both the channel plot and the time-delta plot;
/// both write the shared `model.cursorDistance`, so the cursor appears on both.
struct SeriesChartView: View {
    @Environment(AppModel.self) private var model
    let title: String
    let yLabel: String
    let series: [PlotSeries]
    let xMax: Double
    let showZeroLine: Bool
    let showLegend: Bool

    private var legendDomain: [String] {
        return series.map { (s: PlotSeries) -> String in s.label }
    }

    private var legendColors: [Color] {
        return series.map { (s: PlotSeries) -> Color in Palette.color(s.colorIndex) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { (s: PlotSeries) in
                ForEach(s.points.indices, id: \.self) { (i: Int) in
                    LineMark(
                        x: .value("Distance", s.points[i].x),
                        y: .value(yLabel, s.points[i].y),
                        series: .value("Lap", s.label)
                    )
                    .foregroundStyle(by: .value("Lap", s.label))
                    .lineStyle(StrokeStyle(lineWidth: s.isReference ? 2.5 : 1.5))
                }
            }
            if showZeroLine {
                RuleMark(y: .value("Zero", 0.0))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let cursor = model.cursorDistance {
                RuleMark(x: .value("Cursor", cursor))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartForegroundStyleScale(domain: legendDomain, range: legendColors)
        .chartXScale(domain: 0.0...max(xMax, 1.0))
        .chartLegend(showLegend ? Visibility.visible : Visibility.hidden)
        .chartOverlay { (proxy: ChartProxy) in
            GeometryReader { (geo: GeometryProxy) in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { (phase: HoverPhase) in
                        switch phase {
                        case .active(let location):
                            updateCursor(location: location, proxy: proxy, geo: geo)
                        case .ended:
                            break
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { (value: DragGesture.Value) in
                                updateCursor(location: value.location, proxy: proxy, geo: geo)
                            }
                    )
            }
        }
    }

    private func updateCursor(location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let frameAnchor = proxy.plotFrame else { return }
        let frame: CGRect = geo[frameAnchor]
        let xInPlot: CGFloat = location.x - frame.origin.x
        guard xInPlot >= 0, xInPlot <= frame.width else { return }
        if let d: Double = proxy.value(atX: xInPlot) {
            model.cursorDistance = min(max(d, 0), max(xMax, 1))
        }
    }
}
