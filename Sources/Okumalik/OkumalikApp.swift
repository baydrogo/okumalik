import SwiftUI
import UniformTypeIdentifiers

@main
struct OkumalikApp: App {
    @StateObject private var store = Store()
    @AppStorage("readerMode") private var reader = true
    @AppStorage("readerSize") private var size = 19
    @AppStorage("compactList") private var compact = false
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @AppStorage(ReaderTheme.key) private var theme: ReaderTheme = .auto

    /// Choosing light or dark hands the colors back to "Otomatik": a fixed theme would override it.
    private var appearanceChoice: Binding<AppAppearance> {
        Binding(get: { appearance }, set: { appearance = $0; theme = .auto })
    }

    var body: some Scene {
        Window("Okumalık", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 960, minHeight: 580)
                .tint(.okmTint)
                .followsAppAppearance()
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
                Picker("Renk Teması", selection: $theme) {
                    ForEach(ReaderTheme.allCases) { Text($0.name).tag($0) }
                }
                Picker("Uygulama Görünümü", selection: appearanceChoice) {
                    ForEach(AppAppearance.allCases) { Text($0.name).tag($0) }
                }
                Button("Açık ve Koyu Arasında Geç") {
                    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    appearance = dark ? .light : .dark
                    theme = .auto
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
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
                Button("Seçili Metne Not Ekle") { NotificationCenter.default.post(name: .okmNote, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Kitaplıkta Ara") { NotificationCenter.default.post(name: .okmSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Sayfada Bul…") { NotificationCenter.default.post(name: .okmFind, object: nil) }
                    .keyboardShortcut("f")
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .followsAppAppearance()
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
