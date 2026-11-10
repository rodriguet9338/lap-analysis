import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted: Bool = false

    private static var contentTypes: [UTType] {
        let types: [UTType] = ["xrk", "xrz"].compactMap { (ext: String) -> UTType? in
            UTType(filenameExtension: ext)
        }
        return types.isEmpty ? [UTType.data] : types
    }

    private var importerBinding: Binding<Bool> {
        Binding<Bool>(
            get: { model.showImporter },
            set: { (newValue: Bool) in model.showImporter = newValue }
        )
    }

    var body: some View {
        NavigationSplitView {
            SessionSidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showImporter = true
                } label: {
                    Label("Open", systemImage: "folder")
                }
            }
        }
        .fileImporter(
            isPresented: importerBinding,
            allowedContentTypes: ContentView.contentTypes,
            allowsMultipleSelection: true
        ) { (result: Result<[URL], Error>) in
            handleImport(result)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { (providers: [NSItemProvider]) -> Bool in
            return handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            model.open(urls: urls)
        case .failure(let error):
            model.report(error: error, fileName: "Open")
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let appModel: AppModel = model
        var accepted: Bool = false
        for provider in providers {
            if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { continue }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item: NSSecureCoding?, error: Error?) in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let fileURL = url else { return }
                Task { @MainActor in
                    appModel.openDropped(url: fileURL)
                }
            }
        }
        return accepted
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.sessions.isEmpty {
            emptyState
        } else {
            HSplitView {
                LapTableView()
                    .frame(minWidth: 320, idealWidth: 360, maxWidth: 480)
                AnalysisContainerView()
                    .frame(minWidth: 640)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Sessions", systemImage: "speedometer")
        } description: {
            Text("Open or drop .xrk / .xrz files from an AiM Solo 2. Load a friend's file too to compare laps.")
        } actions: {
            Button("Open…") { model.showImporter = true }
        }
    }
}
