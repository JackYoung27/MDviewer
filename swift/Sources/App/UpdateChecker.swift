import AppKit

/// Only ever runs when the user picks "Check for Updates…" — the app makes no
/// network requests on its own.
enum UpdateChecker {
    private static let releasesURL = URL(string: "https://api.github.com/repos/JackYoung27/MDviewer/releases/latest")!
    private static let downloadURL = URL(string: "https://github.com/JackYoung27/MDviewer/releases/latest")!

    static func check() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tagName = json?["tag_name"] as? String

            DispatchQueue.main.async {
                let alert = NSAlert()

                guard error == nil, status == 200, let tagName else {
                    alert.messageText = "Could not check for updates"
                    alert.informativeText = "The releases page could not be reached. Please try again later."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                guard latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
                    alert.messageText = "You're up to date"
                    alert.informativeText = "Markdown Viewer \(currentVersion) is the latest version."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                alert.messageText = "MDviewer \(latestVersion) is available"
                alert.informativeText = "You're running version \(currentVersion). Would you like to download the update?"
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(downloadURL)
                }
            }
        }.resume()
    }
}
