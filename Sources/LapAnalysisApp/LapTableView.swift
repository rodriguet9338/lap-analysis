import SwiftUI
import LapCore

private enum LapColumns {
    static let check: CGFloat = 22
    static let dot: CGFloat = 10
    static let number: CGFloat = 30
    static let time: CGFloat = 84
    static let delta: CGFloat = 72
    static let star: CGFloat = 22
}

struct LapTableView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            toolbarRow
            Divider()
            columnHeader
            Divider()
            List {
                ForEach(model.visibleSessions) { (loaded: LoadedSession) in
                    Section {
                        ForEach(loaded.session.laps) { (lap: Lap) in
                            LapRowView(loaded: loaded, lap: lap)
                        }
                    } header: {
                        LapSectionHeader(loaded: loaded)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var toolbarRow: some View {
        HStack(spacing: 8) {
            Text("Laps").font(.headline)
            Spacer()
            Button("Best laps") { model.checkBestLaps() }
            Button("Clear") { model.clearChecked() }
            Button("Reset ref") { model.resetReference() }
                .help("Use the fastest lap overall as the reference")
        }
        .controlSize(.small)
        .padding(8)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: LapColumns.check + LapColumns.dot + 8)
            Text("Lap").frame(width: LapColumns.number, alignment: .trailing)
            Text("Time").frame(width: LapColumns.time, alignment: .trailing)
            Text("Δ best").frame(width: LapColumns.delta, alignment: .trailing)
            Spacer()
            Text("Ref").frame(width: LapColumns.star + 6)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

struct LapSectionHeader: View {
    @Environment(AppModel.self) private var model
    let loaded: LoadedSession

    var body: some View {
        HStack {
            Text(model.sessionLabel(loaded.id)).font(.subheadline).bold()
            if !loaded.session.metadata.venue.isEmpty {
                Text(loaded.session.metadata.venue).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LapRowView: View {
    @Environment(AppModel.self) private var model
    let loaded: LoadedSession
    let lap: Lap

    private var key: LapKey { LapKey(sessionID: loaded.id, lapNumber: lap.number) }

    private var deltaText: String {
        guard let best = loaded.session.bestLap else { return "–" }
        if best.number == lap.number { return "best" }
        return Fmt.delta(lap.duration - best.duration)
    }

    var body: some View {
        let isChecked: Bool = model.checkedLaps.contains(key)
        let isRef: Bool = (model.referenceKey == key)
        let dimmed: Bool = model.isDimmed(sessionID: loaded.id, lap: lap, in: loaded.session)
        let colorIndex: Int = model.lapColorIndex[key] ?? 0
        let toggleBinding: Binding<Bool> = Binding<Bool>(
            get: { isChecked },
            set: { (newValue: Bool) in model.setChecked(key, newValue) }
        )

        HStack(spacing: 8) {
            Toggle("", isOn: toggleBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: LapColumns.check)
            Circle()
                .fill(isChecked ? Palette.color(colorIndex) : Color.clear)
                .frame(width: LapColumns.dot, height: LapColumns.dot)
            Text(String(lap.number))
                .frame(width: LapColumns.number, alignment: .trailing)
            Text(Fmt.lapTime(lap.duration))
                .frame(width: LapColumns.time, alignment: .trailing)
            Text(deltaText)
                .frame(width: LapColumns.delta, alignment: .trailing)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.setReference(key)
            } label: {
                Image(systemName: isRef ? "star.fill" : "star")
                    .foregroundStyle(isRef ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: LapColumns.star)
            .help("Use as reference lap")
        }
        .font(.body)
        .monospacedDigit()
        .opacity(dimmed ? 0.45 : 1.0)
        .contentShape(Rectangle())
    }
}
