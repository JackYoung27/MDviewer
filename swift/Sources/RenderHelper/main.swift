// On-demand launchd agent that renders Mermaid diagrams to SVG for the Quick
// Look extension, which cannot host a web content process itself. launchd
// spawns this binary when the extension connects; it exits when idle.
import CryptoKit
import Foundation
import RenderHelperKit
import Security
import WebKit

let idleExitInterval: TimeInterval = 45
let renderTimeout: TimeInterval = 20
let maxSourceLength = 1024 * 1024

var lastActivity = Date()
var activeRenders = 0

func writeCachedSVG(trimmedSource: String, theme: String, svg: String) {
    let directory = MermaidCache.directory
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let hash = SHA256.hash(data: Data(trimmedSource.utf8)).map { String(format: "%02x", $0) }.joined()
    let path = (directory as NSString).appendingPathComponent(MermaidCache.fileName(hash: hash, theme: theme))
    try? svg.write(toFile: path, atomically: true, encoding: .utf8)
}

// MARK: - Offscreen mermaid rendering

final class MermaidRender: NSObject, WKNavigationDelegate {
    private static var activeRenderSet = Set<MermaidRender>()

    private var webView: WKWebView?
    private var completion: ((String?, String?) -> Void)?
    private var pollsRemaining = 0

    static func render(source: String, theme: String,
                       completion: @escaping (String?, String?) -> Void) {
        guard let mermaidURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js",
                                               subdirectory: "vendor"),
              let mermaidSource = try? String(contentsOf: mermaidURL, encoding: .utf8) else {
            completion(nil, "mermaid.min.js is missing from the app bundle.")
            return
        }

        let render = MermaidRender()
        render.completion = completion
        activeRenderSet.insert(render)

        let base64Source = Data(source.utf8).base64EncodedString()
        let mermaidTheme = theme == "dark" ? "dark" : "default"
        let driverScript = """
        (async () => {
          try {
            const bytes = Uint8Array.from(atob("\(base64Source)"), (c) => c.charCodeAt(0));
            const source = new TextDecoder().decode(bytes);
            mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "\(mermaidTheme)" });
            const result = await mermaid.render("mdv-diagram", source);
            window.__mdvResult = { svg: result.svg };
          } catch (error) {
            window.__mdvResult = { error: String(error) };
          }
        })();
        """

        // User scripts sidestep any HTML escaping concerns with inline <script> tags.
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: mermaidSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(
            WKUserScript(source: driverScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                configuration: configuration)
        webView.navigationDelegate = render
        render.webView = webView
        webView.loadHTMLString("<!DOCTYPE html><html><head><meta charset=\"UTF-8\"></head><body></body></html>",
                               baseURL: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + renderTimeout) { [weak render] in
            render?.finish(svg: nil, errorMessage: "Timed out rendering the diagram.")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pollsRemaining = Int(renderTimeout / 0.1)
        poll()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(svg: nil, errorMessage: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(svg: nil, errorMessage: error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(svg: nil, errorMessage: "Web content process was terminated.")
    }

    private func poll() {
        guard completion != nil, let webView else { return }

        webView.evaluateJavaScript("window.__mdvResult || null") { [weak self] result, error in
            guard let self, self.completion != nil else { return }

            if let payload = result as? [String: Any] {
                let svg = payload["svg"] as? String
                let message = payload["error"] as? String
                self.finish(svg: svg, errorMessage: svg == nil ? (message ?? "Mermaid returned no SVG.") : nil)
                return
            }

            self.pollsRemaining -= 1
            if self.pollsRemaining <= 0 || error != nil {
                self.finish(svg: nil, errorMessage: error?.localizedDescription ?? "Timed out waiting for Mermaid.")
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.poll()
            }
        }
    }

    private func finish(svg: String?, errorMessage: String?) {
        guard let completion else { return }
        self.completion = nil

        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil

        Self.activeRenderSet.remove(self)
        completion(svg, errorMessage)
    }
}

// MARK: - XPC service

/// Team identifier from this process's own signature; nil for ad-hoc builds.
let ownTeamIdentifier: String? = {
    var selfCode: SecCode?
    guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
          let info = information as? [String: Any],
          let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
        return nil
    }
    return team
}()

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, RenderHelperProtocol {

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Only accept callers signed by the same team as this helper; ad-hoc
        // dev builds carry no team, so the check is skipped there.
        if let team = ownTeamIdentifier {
            newConnection.setCodeSigningRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }

        newConnection.exportedInterface = NSXPCInterface(with: RenderHelperProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    func renderMermaidSource(_ source: String, theme: String,
                             withReply reply: @escaping (String?, String?) -> Void) {
        guard !source.isEmpty, source.count <= maxSourceLength else {
            reply(nil, "Invalid diagram source.")
            return
        }

        let safeTheme = theme == "dark" ? "dark" : "light"
        let trimmedSource = MermaidCache.normalized(source)

        DispatchQueue.main.async {
            activeRenders += 1
            lastActivity = Date()

            MermaidRender.render(source: trimmedSource, theme: safeTheme) { svg, errorMessage in
                if let svg, !svg.isEmpty {
                    writeCachedSVG(trimmedSource: trimmedSource, theme: safeTheme, svg: svg)
                }
                activeRenders -= 1
                lastActivity = Date()
                reply(svg, errorMessage)
            }
        }
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: renderHelperServiceName)
listener.delegate = delegate
listener.resume()

Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
    if activeRenders == 0, -lastActivity.timeIntervalSinceNow > idleExitInterval {
        exit(0)
    }
}

RunLoop.main.run()
