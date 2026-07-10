import AppKit
import CryptoKit
import WebKit

let preferredFontKey = "MDVPreferredFont"
let preferredFontDidChange = Notification.Name("MDVPreferredFontDidChangeNotification")

enum PreferredFont {
    static let values = ["serif", "github", "geist"]

    static var current: String {
        let value = UserDefaults.standard.string(forKey: preferredFontKey) ?? "serif"
        return values.contains(value) ? value : "serif"
    }

    static var script: String {
        let value = current
        if value == "serif" {
            return "document.documentElement.removeAttribute('data-font');"
        }
        return "document.documentElement.setAttribute('data-font', '\(value)');"
    }
}

/// One per document window: owns the WKWebView, runs the renderer script,
/// watches the source file, and backs every menu command.
@MainActor
final class PreviewModel: NSObject, ObservableObject {
    let webView: WKWebView
    private(set) var sourceFileURL: URL?
    private(set) var previewReady = false
    private var lastExportedPDFURL: URL?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var pendingScrollTop: Double = 0
    private var pendingScrollRatio: Double = 0
    private var hasPendingScrollRestore = false

    override init() {
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = false

        installPreferredFontUserScript()
        configuration.userContentController.add(MessageProxy(target: self), name: "mermaidRendered")

        NotificationCenter.default.addObserver(self, selector: #selector(preferredFontChanged),
                                               name: preferredFontDidChange, object: nil)
    }

    deinit {
        fileWatcher?.cancel()
    }

    // MARK: - Rendering pipeline (same shell renderer as the ObjC app)

    func open(fileURL: URL?) {
        guard let fileURL else { return }
        let standardized = fileURL.standardizedFileURL
        let fileChanged = standardized != sourceFileURL
        sourceFileURL = standardized
        previewReady = false
        lastExportedPDFURL = nil
        render()
        if fileChanged || fileWatcher == nil {
            startWatching()
        }
    }

    private func render() {
        guard let sourceFileURL,
              let scriptURL = Bundle.main.url(forResource: "MarkdownViewer", withExtension: "sh") else {
            loadErrorPage("The preview generator is missing from the app bundle.")
            return
        }

        let path = sourceFileURL.path
        Task.detached(priority: .userInitiated) {
            let result = Self.runRenderer(scriptURL: scriptURL, filePath: path)
            await MainActor.run { [weak self] in
                guard let self, self.sourceFileURL?.path == path else { return }
                switch result {
                case .success(let htmlURL):
                    self.webView.loadFileURL(htmlURL, allowingReadAccessTo: URL(fileURLWithPath: "/"))
                case .failure(let message):
                    self.loadErrorPage(message)
                }
            }
        }
    }

    private enum RenderResult {
        case success(URL)
        case failure(String)
    }

    nonisolated private static func runRenderer(scriptURL: URL, filePath: String) -> RenderResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = scriptURL
        process.arguments = [filePath]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure("Could not start the preview generator: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(message.isEmpty ? "Preview generation failed." : message)
        }

        guard let htmlPath = output.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return .failure("Preview generation did not return an HTML path.")
        }

        return .success(URL(fileURLWithPath: htmlPath))
    }

    private func loadErrorPage(_ message: String) {
        let safe = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;padding:32px;font:13pt/1.6 -apple-system,BlinkMacSystemFont,sans-serif;background:#fff;color:#1f2937;}
        main{max-width:760px;}h1{margin:0 0 0.5em;font-size:1.3em;}p{margin:0;white-space:pre-wrap;}
        </style></head><body><main><h1>Could not open document</h1><p>\(safe)</p></main></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        previewReady = false
    }

    // MARK: - Live reload

    private func startWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
        guard let sourceFileURL else { return }

        let descriptor = Darwin.open(sourceFileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            let events = watcher.data
            self.reloadPreview()
            if events.contains(.rename) || events.contains(.delete) {
                // Editors that save atomically replace the file; re-arm on the new inode.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startWatching()
                }
            }
        }
        watcher.setCancelHandler {
            close(descriptor)
        }
        watcher.resume()
        fileWatcher = watcher
    }

    // MARK: - Commands

    func reloadPreview() {
        guard sourceFileURL != nil else { return }
        guard previewReady else {
            render()
            return
        }

        let captureScript = """
        (() => {
          const doc = document.documentElement;
          const body = document.body;
          const viewportHeight = window.innerHeight || doc.clientHeight || 0;
          const scrollHeight = Math.max(doc.scrollHeight || 0, body.scrollHeight || 0);
          const maxScroll = Math.max(scrollHeight - viewportHeight, 0);
          const scrollTop = Math.max(window.scrollY || window.pageYOffset || doc.scrollTop || body.scrollTop || 0, 0);
          const scrollRatio = maxScroll > 0 ? scrollTop / maxScroll : 0;
          return { scrollTop, scrollRatio };
        })()
        """
        webView.evaluateJavaScript(captureScript) { [weak self] result, _ in
            guard let self else { return }
            self.hasPendingScrollRestore = false
            if let state = result as? [String: Any] {
                if let top = state["scrollTop"] as? Double {
                    self.pendingScrollTop = top
                    self.hasPendingScrollRestore = true
                }
                if let ratio = state["scrollRatio"] as? Double {
                    self.pendingScrollRatio = ratio
                }
            }
            self.render()
        }
    }

    func printDocument() {
        guard previewReady, let window = webView.window else { return }
        let operation = webView.printOperation(with: .shared)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func createPDF(_ completion: @escaping (Result<Data, Error>) -> Void) {
        guard previewReady else {
            completion(.failure(NSError(domain: "com.local.markdown-viewer", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Wait until the preview finishes loading before exporting.",
            ])))
            return
        }
        webView.createPDF { completion($0) }
    }

    private var defaultPDFFileName: String {
        let stem = sourceFileURL?.deletingPathExtension().lastPathComponent ?? "Document"
        return stem.isEmpty ? "Document.pdf" : stem + ".pdf"
    }

    func exportPDF() {
        guard let sourceFileURL, let window = webView.window else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultPDFFileName
        panel.directoryURL = sourceFileURL.deletingLastPathComponent()

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            self.createPDF { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let data):
                        do {
                            try data.write(to: destination, options: .atomic)
                            self.lastExportedPDFURL = destination
                        } catch {
                            NSAlert(error: error).runModal()
                        }
                    case .failure(let error):
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
    }

    func openPDFInDefaultApp() {
        if let lastExportedPDFURL, FileManager.default.fileExists(atPath: lastExportedPDFURL.path) {
            NSWorkspace.shared.open(lastExportedPDFURL)
            return
        }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(defaultPDFFileName)
        createPDF { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: destination, options: .atomic)
                        self.lastExportedPDFURL = destination
                        NSWorkspace.shared.open(destination)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                case .failure(let error):
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    func revealSourceFile() {
        guard let sourceFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sourceFileURL])
    }

    func toggleDarkMode() {
        runViewerScript("toggleTheme()")
    }

    func openFindPanel() {
        runViewerScript("if (typeof mdvToggleFindBar === 'function') { mdvToggleFindBar(); }")
    }

    func findNext() {
        runViewerScript("if (typeof mdvFindNextMatch === 'function') { mdvFindNextMatch(); }")
    }

    func findPrevious() {
        runViewerScript("if (typeof mdvFindPreviousMatch === 'function') { mdvFindPreviousMatch(); }")
    }

    private func runViewerScript(_ script: String) {
        guard previewReady else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Preferred font

    private func installPreferredFontUserScript() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: PreferredFont.script,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }

    @objc private func preferredFontChanged() {
        installPreferredFontUserScript()
        webView.evaluateJavaScript(PreferredFont.script, completionHandler: nil)
    }
}

// MARK: - WKWebView delegates

extension PreviewModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        previewReady = true
        guard hasPendingScrollRestore else { return }
        let top = pendingScrollTop
        let ratio = pendingScrollRatio
        hasPendingScrollRestore = false

        let restoreScript = """
        (() => {
          const requestedTop = \(top);
          const requestedRatio = \(ratio);
          const restore = () => {
            const doc = document.documentElement;
            const body = document.body;
            const viewportHeight = window.innerHeight || doc.clientHeight || 0;
            const scrollHeight = Math.max(doc.scrollHeight || 0, body.scrollHeight || 0);
            const maxScroll = Math.max(scrollHeight - viewportHeight, 0);
            let target = Math.min(Math.max(requestedTop, 0), maxScroll);
            if (requestedRatio >= 0.98 && maxScroll > 0) {
              target = maxScroll;
            }
            window.scrollTo(0, target);
          };
          restore();
          requestAnimationFrame(restore);
          requestAnimationFrame(() => requestAnimationFrame(restore));
        })()
        """
        webView.evaluateJavaScript(restoreScript, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        previewReady = false
        loadErrorPage(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        previewReady = false
        loadErrorPage(error.localizedDescription)
    }

    private func openLinkedURL(_ url: URL) {
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
        if url.isFileURL && markdownExtensions.contains(url.pathExtension.lowercased()) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return
        }
        NSWorkspace.shared.open(url)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            openLinkedURL(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openLinkedURL(url)
        }
        return nil
    }
}

// MARK: - Mermaid SVG cache (shared with the Quick Look extension)

extension PreviewModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "mermaidRendered",
              let body = message.body as? [String: Any],
              let source = body["source"] as? String,
              let svg = body["svg"] as? String,
              let theme = body["theme"] as? String,
              theme == "light" || theme == "dark",
              !svg.isEmpty, svg.count <= 4 * 1024 * 1024 else {
            return
        }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let digest = SHA256.hash(data: Data(trimmed.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        let directory = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? "")
            .appending("/Markdown Viewer/mermaid-cache")

        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let path = (directory as NSString).appendingPathComponent("\(hash)-\(theme).svg")
            try? svg.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

/// WKUserContentController retains its message handlers; the proxy breaks the
/// retain cycle with the model that owns the web view.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler & AnyObject)?

    init(target: any WKScriptMessageHandler & AnyObject) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
