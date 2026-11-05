import SwiftUI
import UniformTypeIdentifiers

@main
struct OkumalikApp: App {
    @StateObject private var store = Store()
    @AppStorage("readerMode") private var reader = true
    @AppStorage("readerSize") private var size = 19
    @AppStorage("compactList") private var compact = false

    var body: some Scene {
        Window("Okumalık", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 580)
                .tint(.okmAccent)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                Button("Odak Modu") { NotificationCenter.default.post(name: .okmFocus, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Bilgi ve Vurgular Paneli") { NotificationCenter.default.post(name: .okmPanel, object: nil) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Toggle("Sıkı Liste", isOn: $compact)
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("Yeni Ekle…") { store.showAddSheet = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Akışları Yenile") { Task { await store.refreshAll() } }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .toolbar) {
                Toggle("Okuma Modu", isOn: $reader)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Yazıyı Büyüt") { size = min(32, size + 1) }
                    .keyboardShortcut("+")
                Button("Yazıyı Küçült") { size = max(13, size - 1) }
                    .keyboardShortcut("-")
                Divider()
                Button("Seçili Metni Vurgula") { NotificationCenter.default.post(name: .okmHighlight, object: nil) }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Sayfada Bul…") { NotificationCenter.default.post(name: .okmFind, object: nil) }
                    .keyboardShortcut("f")
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

enum Actions {
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    static func copy(_ url: URL) { copyText(url.absoluteString) }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func saveMarkdown(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(Store.fileName(name).prefix(80)) + ".md"
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
