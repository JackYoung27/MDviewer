import SwiftUI

struct SettingsView: View {
    @AppStorage(preferredFontKey) private var preferredFont = "serif"

    var body: some View {
        Form {
            Picker("Document font:", selection: $preferredFont) {
                Text("Serif (default)").tag("serif")
                Text("GitHub (system sans)").tag("github")
                Text("Geist (Next.js)").tag("geist")
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(width: 340)
        .onChange(of: preferredFont) { _ in
            NotificationCenter.default.post(name: preferredFontDidChange, object: nil)
        }
    }
}
