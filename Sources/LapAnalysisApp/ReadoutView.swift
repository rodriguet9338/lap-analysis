import SwiftUI

/// Values of each checked lap at the shared cursor distance.
struct ReadoutView: View {
    @Environment(AppModel.self) private var model

    private func deltaText(for series: PlotSeries) -> String {
        if series.isReference { return "ref" }
        let match: PlotSeries? = model.analysis.deltaSeries.first(where: { (d: PlotSeries) -> Bool in d.id == series.id })
        guard let d = match, let v = d.value(at: cursorValue) else { return "–" }
        return Fmt.delta(v)
    }

    private var cursorValue: Double { model.cursorDistance ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cursor = model.cursorDistance, !model.analysis.channelSeries.isEmpty {
                Text("Distance  " + Fmt.distance(cursor))
                    .font(.subheadline).bold().monospacedDigit()
                HStack {
                    Text("Lap").frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.channelAxisLabel).frame(width: 70, alignment: .trailing)
                    Text("Δ s").frame(width: 60, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(model.analysis.channelSeries) { (s: PlotSeries) in
                    HStack(spacing: 6) {
                        Circle().fill(Palette.color(s.colorIndex)).frame(width: 8, height: 8)
                        Text(s.label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.value(s.value(at: cursor), decimals: 1))
                            .frame(width: 70, alignment: .trailing)
                        Text(deltaText(for: s))
                            .frame(width: 60, alignment: .trailing)
                    }
                    .font(.caption)
                    .monospacedDigit()
                }
            } else {
                Text("Hover or drag over a chart to read values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
