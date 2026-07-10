import SwiftUI

struct AppCommands: Commands {
    @FocusedObject private var model: PreviewModel?

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Check for Updates…") { UpdateChecker.check() }
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Reload") { model?.reloadPreview() }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Button("Export as PDF…") { model?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("Open PDF in Default App") { model?.openPDFInDefaultApp() }
                .disabled(model == nil)
            Button("Reveal Source File") { model?.revealSourceFile() }
                .disabled(model == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { model?.printDocument() }
                .keyboardShortcut("p")
                .disabled(model == nil)
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find…") { model?.openFindPanel() }
                .keyboardShortcut("f")
                .disabled(model == nil)
            Button("Find Next") { model?.findNext() }
                .keyboardShortcut("g")
                .disabled(model == nil)
            Button("Find Previous") { model?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Dark Mode") { model?.toggleDarkMode() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
    }
}
