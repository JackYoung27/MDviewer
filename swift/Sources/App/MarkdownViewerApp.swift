import SwiftUI
import UniformTypeIdentifiers

@main
struct MarkdownViewerApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            PreviewContainer(fileURL: file.fileURL)
        }
        .defaultSize(width: 860, height: 980)
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}

/// Viewer-only document: content is read from disk by the renderer script, so
/// the document itself only anchors SwiftUI's document lifecycle (open panel,
/// recents, window-per-file).
struct MarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        var types: [UTType] = [.plainText]
        if let markdown = UTType("net.daringfireball.markdown") {
            types.insert(markdown, at: 0)
        }
        return types
    }

    init() {}
    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}

struct PreviewContainer: View {
    let fileURL: URL?
    @StateObject private var model = PreviewModel()

    var body: some View {
        PreviewWebView(model: model)
            .focusedSceneObject(model)
            .onAppear { model.open(fileURL: fileURL) }
            .onChange(of: fileURL) { newURL in model.open(fileURL: newURL) }
    }
}

struct PreviewWebView: NSViewRepresentable {
    @ObservedObject var model: PreviewModel

    func makeNSView(context: Context) -> NSView {
        model.webView
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
