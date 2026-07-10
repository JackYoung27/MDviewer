import Foundation

/// Mach service the on-demand launchd agent registers; the Quick Look
/// extension holds a mach-lookup entitlement exception for this exact name.
public let renderHelperServiceName = "com.local.markdown-viewer.render-helper"

/// XPC protocol between the Quick Look extension and the render helper.
/// The @objc name and selector match the Objective-C implementation so Swift
/// and ObjC builds interoperate.
@objc(MDVRenderHelperProtocol)
public protocol RenderHelperProtocol {
    func renderMermaidSource(_ source: String, theme: String, withReply reply: @escaping (String?, String?) -> Void)
}

/// Shared locations and normalization for the Mermaid SVG cache.
public enum MermaidCache {
    /// NSHomeDirectory() points inside a sandbox container for the extension;
    /// the cache lives under the user's real home.
    public static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    public static var directory: String {
        (realHomeDirectory as NSString).appendingPathComponent("Library/Application Support/Markdown Viewer/mermaid-cache")
    }

    public static func normalized(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func fileName(hash: String, theme: String) -> String {
        "\(hash)-\(theme).svg"
    }
}
