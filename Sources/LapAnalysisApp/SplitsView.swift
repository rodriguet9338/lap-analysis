import SwiftUI

struct SplitsView: View {
    @Environment(AppModel.self) private var model

    private var countBinding: Binding<Int> {
        Binding<Int>(
            get: { model.splitCount },
            set: { (newValue: Int) in model.setSplitCount(newValue) }
        )
    }

    var body: some View {
        let table: SplitTable = model.analysis.splits
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Stepper("Splits: " + String(model.splitCount), value: countBinding, in: 3...8)
                    .fixedSize()
                Spacer()
                if let best = table.theoreticalBest {
                    Text("Theoretical best  " + Fmt.lapTime(best))
                        .font(.headline)
                        .monospacedDigit()
                }
            }
            if table.rows.isEmpty {
                Spacer()
                Text("Check one or more laps to see split times.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView([.horizontal, .vertical]) {
                    SplitGridView(table: table)
                }
            }
        }
        .padding(12)
    }
}

struct SplitGridView: View {
    let table: SplitTable

    private func cellText(_ row: SplitRow, _ j: Int) -> String {
        return j < row.times.count ? Fmt.splitTime(row.times[j]) : "–"
    }

    private func isBest(_ row: SplitRow, _ j: Int) -> Bool {
        guard j < row.times.count, j < table.bestPerSplit.count else { return false }
        return row.times[j] == table.bestPerSplit[j]
    }

    private func bestText(_ j: Int) -> String {
        guard j < table.bestPerSplit.count, table.bestPerSplit[j].isFinite else { return "–" }
        return Fmt.splitTime(table.bestPerSplit[j])
    }

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("Lap")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 140, alignment: .leading)
                ForEach(0..<table.columnCount, id: \.self) { (j: Int) in
                    Text("S" + String(j + 1))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            ForEach(table.rows) { (row: SplitRow) in
                GridRow {
                    SplitLapLabel(row: row)
                    ForEach(0..<table.columnCount, id: \.self) { (j: Int) in
                        SplitCell(text: cellText(row, j), highlighted: isBest(row, j))
                    }
                    Text(Fmt.lapTime(row.total))
                }
            }
            Divider()
            GridRow {
                Text("Best per split")
                    .bold()
                    .frame(minWidth: 140, alignment: .leading)
                ForEach(0..<table.columnCount, id: \.self) { (j: Int) in
                    Text(bestText(j)).bold()
                }
                Text(theoreticalText).bold()
            }
        }
        .monospacedDigit()
        .padding(4)
    }

    private var theoreticalText: String {
        if let t = table.theoreticalBest { return Fmt.lapTime(t) }
        return "–"
    }
}

struct SplitLapLabel: View {
    let row: SplitRow

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Palette.color(row.colorIndex)).frame(width: 8, height: 8)
            Text(row.label).lineLimit(1)
        }
        .frame(minWidth: 140, alignment: .leading)
    }
}

struct SplitCell: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .fontWeight(highlighted ? Font.Weight.bold : Font.Weight.regular)
            .padding(.horizontal, 4)
            .background(highlighted ? Color.green.opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
