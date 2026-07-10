import AppKit
import UniformTypeIdentifiers

/// Asked once, on the first launch where another app (usually Xcode on a
/// developer Mac) owns Markdown files.
enum DefaultHandlerOffer {
    private static let offeredKey = "MDVDidOfferDefaultHandler"

    private static var markdownContentTypes: [UTType] {
        var types: [UTType] = []
        var seen = Set<String>()

        if let declared = UTType("net.daringfireball.markdown") {
            types.append(declared)
            seen.insert(declared.identifier)
        }
        for ext in ["md", "markdown", "mdown", "mkd"] {
            if let type = UTType(filenameExtension: ext), !seen.contains(type.identifier) {
                types.append(type)
                seen.insert(type.identifier)
            }
        }
        return types
    }

    @MainActor
    static func offerIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: offeredKey) else { return }

        let types = markdownContentTypes
        guard let primary = types.first else { return }

        let workspace = NSWorkspace.shared
        let currentHandlerURL = workspace.urlForApplication(toOpen: primary)
        let currentBundleID = currentHandlerURL.flatMap { Bundle(url: $0)?.bundleIdentifier }

        defaults.set(true, forKey: offeredKey)

        guard currentBundleID != Bundle.main.bundleIdentifier else { return }

        let currentName = currentHandlerURL.map { FileManager.default.displayName(atPath: $0.path) }
            ?? "another app"

        let alert = NSAlert()
        alert.messageText = "Open Markdown files with Markdown Viewer?"
        alert.informativeText = """
        Markdown files currently open in \(currentName). Make Markdown Viewer the default \
        so double-clicking a .md file shows a rendered preview?

        You can change this anytime via Get Info in Finder.
        """
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let appURL = Bundle.main.bundleURL
        for type in types {
            workspace.setDefaultApplication(at: appURL, toOpen: type)
        }
    }
}
