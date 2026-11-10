import SwiftUI

enum AnalysisTab: String, CaseIterable, Identifiable {
    case overlay = "Overlay"
    case splits = "Splits"
    var id: String { rawValue }
}

struct AnalysisContainerView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AnalysisTab = .overlay

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $tab) {
                    ForEach(AnalysisTab.allCases) { (t: AnalysisTab) in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                if model.computingTraces > 0 {
                    ProgressView().controlSize(.small)
                    Text("Computing laps…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            Divider()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overlay:
            OverlayView()
        case .splits:
            SplitsView()
        }
    }
}
