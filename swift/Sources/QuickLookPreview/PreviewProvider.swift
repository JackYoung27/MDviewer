import CryptoKit
import Foundation
import JavaScriptCore
import QuickLookUI
import RenderHelperKit
import UniformTypeIdentifiers

@objc(MDVPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let fileURL = request.fileURL

        let reply = QLPreviewReply(dataOfContentType: .html,
                                   contentSize: CGSize(width: 720, height: 900)) { replyToUpdate in
            replyToUpdate.stringEncoding = .utf8

            let markdown = Self.readMarkdown(at: fileURL)
            var body = MarkdownRenderer.renderPreviewBody(markdown: markdown)
                ?? "<pre>\(MarkdownRenderer.escapeHTML(markdown))</pre>"

            var css = Self.loadResource(name: "viewer", ext: "css") ?? ""
            if body.contains("class=\"katex") {
                css += "\n" + MarkdownRenderer.inlinedKaTeXCSS
            }

            var attachments: [String: QLPreviewReplyAttachment] = [:]
            body = ImageEmbedder.embedLocalImages(in: body,
                                                  baseDirectory: fileURL.deletingLastPathComponent(),
                                                  attachments: &attachments)
            if !attachments.isEmpty {
                replyToUpdate.attachments = attachments
            }

            return Data(MarkdownRenderer.previewHTML(body: body, css: css).utf8)
        }

        handler(reply, nil)
    }

    private static func readMarkdown(at fileURL: URL) -> String {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            return text
        }
        if let data = try? Data(contentsOf: fileURL) {
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
        return ""
    }

    static func loadResource(name: String, ext: String, subdirectory: String? = nil) -> String? {
        guard let url = Bundle(for: PreviewProvider.self).url(forResource: name,
                                                              withExtension: ext,
                                                              subdirectory: subdirectory) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - Markdown + math rendering (JavaScriptCore, no DOM needed)

enum MarkdownRenderer {

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func decodeHTMLEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func renderPreviewBody(markdown: String) -> String? {
        var mathByToken: [String: String] = [:]
        let prepared = substituteMath(in: markdown, mathByToken: &mathByToken)

        guard var html = renderMarkdownHTML(prepared) else { return nil }

        for (token, rendered) in mathByToken {
            html = html.replacingOccurrences(of: token, with: rendered)
        }

        return MermaidReplacer.applyMermaidRendering(to: html)
    }

    private static func renderMarkdownHTML(_ markdown: String) -> String? {
        guard let markedSource = PreviewProvider.loadResource(name: "marked.umd", ext: "js", subdirectory: "vendor"),
              let context = JSContext() else {
            return nil
        }

        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        context.evaluateScript(markedSource)

        guard !failed, let marked = context.objectForKeyedSubscript("marked"), !marked.isUndefined else {
            return nil
        }

        let options: [String: Any] = ["gfm": true, "breaks": true, "async": false]
        guard let rendered = marked.invokeMethod("parse", withArguments: [markdown, options]),
              !failed, rendered.isString else {
            return nil
        }
        return rendered.toString()
    }

    // katex.renderToString works without a browser DOM, so math renders even
    // though Quick Look forbids web content processes in extension sandboxes.
    private static let katexRender: JSValue? = {
        guard let source = PreviewProvider.loadResource(name: "katex.min", ext: "js", subdirectory: "vendor"),
              let context = JSContext() else {
            return nil
        }
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        context.evaluateScript(source)
        guard !failed, let katex = context.objectForKeyedSubscript("katex"), !katex.isUndefined else {
            return nil
        }
        return katex.objectForKeyedSubscript("renderToString")
    }()

    private static func renderTeX(_ tex: String, displayMode: Bool) -> String? {
        guard let render = katexRender else { return nil }
        var failed = false
        render.context.exceptionHandler = { _, _ in failed = true }
        let options: [String: Any] = ["displayMode": displayMode, "throwOnError": false]
        let result = render.call(withArguments: [tex, options])
        render.context.exceptionHandler = nil
        guard !failed, let result, result.isString else { return nil }
        return result.toString()
    }

    private static func protectMatches(in text: NSMutableString,
                                       pattern: String,
                                       marker: Character,
                                       store: inout [String: String]) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            let token = "\(marker)\(store.count)\(marker)"
            store[token] = text.substring(with: match.range)
            text.replaceCharacters(in: match.range, with: token)
        }
    }

    /// Extracts $$...$$, \[...\], \(...\), and $...$ math from the markdown
    /// source (skipping code fences and inline code), renders each with KaTeX,
    /// and swaps in placeholder tokens resolved after marked runs. Working on
    /// the source keeps TeX like $a_i + b_j$ away from marked's emphasis parsing.
    private static func substituteMath(in markdown: String,
                                       mathByToken: inout [String: String]) -> String {
        guard markdown.contains("$") || markdown.contains("\\(") || markdown.contains("\\[") else {
            return markdown
        }

        let working = NSMutableString(string: markdown)
        var protectedCode: [String: String] = [:]
        protectMatches(in: working, pattern: #"(?ms)^(```|~~~)[^\n]*$.*?^\1[ \t]*$"#,
                       marker: "\u{E000}", store: &protectedCode)
        protectMatches(in: working, pattern: #"(`+)[\s\S]*?\1"#,
                       marker: "\u{E000}", store: &protectedCode)

        let mathPattern = #"\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$([^\s$][^$\n]*?)\$"#
        if let regex = try? NSRegularExpression(pattern: mathPattern) {
            let matches = regex.matches(in: working as String, range: NSRange(location: 0, length: working.length))
            for match in matches.reversed() {
                var tex: String?
                var displayMode = false
                for group in 1...4 where match.range(at: group).location != NSNotFound {
                    tex = working.substring(with: match.range(at: group))
                    displayMode = group <= 2
                    break
                }

                guard let tex, !tex.isEmpty, let rendered = renderTeX(tex, displayMode: displayMode) else {
                    continue
                }

                let token = "\u{E001}\(mathByToken.count)\u{E001}"
                mathByToken[token] = rendered
                working.replaceCharacters(in: match.range, with: token)
            }
        }

        var result = working as String
        for (token, original) in protectedCode {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }

    // KaTeX CSS references its fonts with relative url(fonts/...) entries that
    // a data-based preview cannot resolve, so woff2 fonts become data URIs.
    static let inlinedKaTeXCSS: String = {
        guard let css = PreviewProvider.loadResource(name: "katex.min", ext: "css", subdirectory: "vendor") else {
            return ""
        }
        guard let regex = try? NSRegularExpression(pattern: #"url\(fonts/([^)]+\.woff2)\)"#) else {
            return css
        }

        let result = NSMutableString(string: css)
        let matches = regex.matches(in: css, range: NSRange(location: 0, length: result.length))
        for match in matches.reversed() {
            let fontName = (result.substring(with: match.range(at: 1)) as NSString).deletingPathExtension
            guard let fontURL = Bundle(for: PreviewProvider.self).url(forResource: fontName,
                                                                      withExtension: "woff2",
                                                                      subdirectory: "vendor/fonts"),
                  let fontData = try? Data(contentsOf: fontURL) else {
                continue
            }
            result.replaceCharacters(in: match.range,
                                     with: "url(data:font/woff2;base64,\(fontData.base64EncodedString()))")
        }
        return result as String
    }()

    // Quick Look renders data-based HTML previews with JavaScript disabled, so
    // the document must arrive fully rendered; the CSP is defense in depth.
    static func previewHTML(body: String, css: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file: cid:; style-src 'unsafe-inline'; script-src 'none'; object-src 'none'; frame-src 'none'; form-action 'none';">
        <meta name="color-scheme" content="light dark">
        <style>
        \(css)
        </style>
        </head>
        <body>
        <main class="document">
        \(body)
        </main>
        </body>
        </html>
        """
    }
}

// MARK: - Mermaid (cache + on-demand helper; no browser engine in this sandbox)

enum MermaidReplacer {

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // The sandboxed extension cannot read preferences the normal way; the
    // global preferences plist under the real home reveals the appearance.
    static var systemTheme: String {
        let path = (MermaidCache.realHomeDirectory as NSString)
            .appendingPathComponent("Library/Preferences/.GlobalPreferences.plist")
        let preferences = NSDictionary(contentsOfFile: path)
        return (preferences?["AppleInterfaceStyle"] as? String) == "Dark" ? "dark" : "light"
    }

    private static func cachedSVG(hash: String, theme: String) -> String? {
        let path = (MermaidCache.directory as NSString)
            .appendingPathComponent(MermaidCache.fileName(hash: hash, theme: theme))
        guard let svg = try? String(contentsOfFile: path, encoding: .utf8), !svg.isEmpty else {
            return nil
        }
        return svg
    }

    // Cache miss: ask the on-demand launchd helper. launchd spawns it lazily;
    // if the agent is not installed the lookup fails fast and we fall back.
    private static func requestHelperRender(_ trimmedSource: String) -> String? {
        let connection = NSXPCConnection(machServiceName: renderHelperServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: RenderHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        var renderedSVG: String?

        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            semaphore.signal()
        } as? RenderHelperProtocol

        proxy?.renderMermaidSource(trimmedSource, theme: systemTheme) { svg, _ in
            if let svg, !svg.isEmpty {
                renderedSVG = svg
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 25)
        return renderedSVG
    }

    /// Theme priority: an SVG matching the system appearance, then a live
    /// helper render, then a stale-theme SVG — a wrong theme beats no diagram.
    private static func svgForSource(_ source: String) -> String? {
        let trimmed = MermaidCache.normalized(source)
        guard !trimmed.isEmpty else { return nil }

        let hash = sha256Hex(trimmed)
        let theme = systemTheme

        if let svg = cachedSVG(hash: hash, theme: theme) { return svg }
        if let svg = requestHelperRender(trimmed) { return svg }
        return cachedSVG(hash: hash, theme: theme == "dark" ? "light" : "dark")
    }

    static func applyMermaidRendering(to html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"<pre><code class="language-mermaid">([\s\S]*?)</code></pre>"#) else {
            return html
        }

        let result = NSMutableString(string: html)
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: result.length))
        guard !matches.isEmpty else { return html }

        for match in matches.reversed() {
            let escapedSource = result.substring(with: match.range(at: 1))
            let figure: String

            if let svg = svgForSource(MarkdownRenderer.decodeHTMLEntities(escapedSource)) {
                let dataURI = "data:image/svg+xml;base64,\(Data(svg.utf8).base64EncodedString())"
                figure = """
                <figure class="mermaid-diagram">\
                <img class="mermaid-diagram__image" alt="Mermaid diagram" src="\(dataURI)">\
                </figure>
                """
            } else {
                figure = """
                <figure class="mermaid-diagram">\
                <p class="mermaid-diagram__status">Could not render Mermaid diagram.</p>\
                <pre><code class="language-mermaid">\(escapedSource)</code></pre>\
                </figure>
                """
            }
            result.replaceCharacters(in: match.range, with: figure)
        }
        return result as String
    }
}

// MARK: - Local image embedding

enum ImageEmbedder {
    private static let maxImageBytes = 25 * 1024 * 1024

    private static func resolveLocalImageURL(_ source: String, baseDirectory: URL) -> URL? {
        if source.hasPrefix("file://") {
            return URL(string: source)
        }
        var path = source
        if path.contains("%"), let decoded = path.removingPercentEncoding {
            path = decoded
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: path, relativeTo: baseDirectory).absoluteURL
    }

    // Data-based previews have no document base URL, so relative image paths
    // can never load on their own; local images become cid: attachments.
    static func embedLocalImages(in bodyHTML: String,
                                 baseDirectory: URL,
                                 attachments: inout [String: QLPreviewReplyAttachment]) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(<img\b[^>]*?\bsrc\s*=\s*")([^"]+)(")"#,
            options: .caseInsensitive) else {
            return bodyHTML
        }

        let result = NSMutableString(string: bodyHTML)
        let matches = regex.matches(in: bodyHTML, range: NSRange(location: 0, length: result.length))
        guard !matches.isEmpty else { return bodyHTML }

        var index = 0
        for match in matches.reversed() {
            let source = MarkdownRenderer.decodeHTMLEntities(result.substring(with: match.range(at: 2)))
            if source.range(of: #"^(https?:|data:|cid:)"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }

            guard let imageURL = resolveLocalImageURL(source, baseDirectory: baseDirectory),
                  let data = try? Data(contentsOf: imageURL, options: .mappedIfSafe),
                  !data.isEmpty, data.count <= maxImageBytes,
                  let contentType = UTType(filenameExtension: imageURL.pathExtension.lowercased()),
                  contentType.conforms(to: .image) else {
                continue
            }

            let key = "img\(index)"
            index += 1
            attachments[key] = QLPreviewReplyAttachment(data: data, contentType: contentType)
            result.replaceCharacters(in: match.range(at: 2), with: "cid:\(key)")
        }
        return result as String
    }
}
