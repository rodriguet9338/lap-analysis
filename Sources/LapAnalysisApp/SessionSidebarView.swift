import SwiftUI
import LapCore

struct SessionSidebarView: View {
    @Environment(AppModel.self) private var model

    private var selectionBinding: Binding<Set<UUID>> {
        Binding<Set<UUID>>(
            get: { model.selectedSessionIDs },
            set: { (newValue: Set<UUID>) in model.selectedSessionIDs = newValue }
        )
    }

    var body: some View {
        List(selection: selectionBinding) {
            Section("Sessions") {
                ForEach(model.sessions) { (loaded: LoadedSession) in
                    SessionRowView(loaded: loaded)
                        .tag(loaded.id)
                        .contextMenu {
                            Button("Close Session") {
                                model.close(sessionIDs: [loaded.id])
                            }
                        }
                }
            }
            if !model.loadingFiles.isEmpty {
                Section("Loading") {
                    ForEach(model.loadingFiles) { (f: LoadingFile) in
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(f.fileName).lineLimit(1)
                        }
                    }
                }
            }
            if !model.issues.isEmpty {
                Section("Errors") {
                    ForEach(model.issues) { (issue: LoadIssue) in
                        IssueRowView(issue: issue)
                    }
                }
            }
        }
        .overlay {
            if model.sessions.isEmpty && model.loadingFiles.isEmpty && model.issues.isEmpty {
                Text("Drop .xrk or .xrz files here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct IssueRowView: View {
    @Environment(AppModel.self) private var model
    let issue: LoadIssue

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.fileName).font(.caption).bold().lineLimit(1)
                Text(issue.message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button {
                model.dismissIssue(issue.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
        }
    }
}

struct SessionRowView: View {
    let loaded: LoadedSession

    private var venue: String {
        let v: String = loaded.session.metadata.venue
        return v.isEmpty ? loaded.fileName : v
    }

    private var subtitle: String {
        let meta: SessionMetadata = loaded.session.metadata
        var parts: [String] = []
        if !meta.driver.isEmpty { parts.append(meta.driver) }
        if let d = meta.date {
            parts.append(d.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    private var lapsLine: String {
        let count: Int = loaded.session.laps.count
        let best: String = loaded.session.bestLap.map { (l: Lap) -> String in Fmt.lapTime(l.duration) } ?? "–"
        return String(count) + " laps · Best " + best
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(venue).font(.headline).lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(lapsLine).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
