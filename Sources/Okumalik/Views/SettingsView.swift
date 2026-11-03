import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("readerMode") private var reader = true
    @AppStorage("refreshMinutes") private var refreshMinutes = 30
    @State private var status: String?

    private static let bookmarklets: [(String, String)] = [
        ("Sonra Oku", "add"),
        ("Yer İmi", "bookmark"),
        ("Akışa Abone Ol", "feed"),
    ]

    var body: some View {
        Form {
            Section("Okuma") {
                Toggle("Sayfaları okuma modunda aç", isOn: $reader)
            }

            Section("Akışlar") {
                Picker("Otomatik yenile", selection: $refreshMinutes) {
                    Text("15 dakikada bir").tag(15)
                    Text("30 dakikada bir").tag(30)
                    Text("Saatte bir").tag(60)
                    Text("3 saatte bir").tag(180)
                }
                HStack {
                    Button("OPML İçe Aktar…", action: importOPML)
                    Button("OPML Dışa Aktar…", action: exportOPML)
                        .disabled(store.feeds.isEmpty)
                }
            }

            Section {
                ForEach(Self.bookmarklets, id: \.1) { name, action in
                    LabeledContent(name) {
                        Button("Kopyala") { copyBookmarklet(action) }
                    }
                }
            } header: {
                Text("Tarayıcıdan kaydet")
            } footer: {
                Text("Kopyaladığınız kodu tarayıcınızda yeni bir yer imi oluşturup adres alanına yapıştırın. O yer imine tıkladığınızda açık sayfa Okumalık'a eklenir.")
                    .foregroundStyle(.secondary)
            }

            Section("Veri") {
                Button("Veri Klasörünü Göster") { NSWorkspace.shared.open(Store.dataDirectory) }
                if let status {
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copyBookmarklet(_ action: String) {
        // Wrapped so the bookmarklet returns nothing; a returned string would replace the page.
        let js = "javascript:(function(){location.href='okumalik://\(action)?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title);})();"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(js, forType: .string)
        status = "Yer imciği panoya kopyalandı."
    }

    private func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        Task {
            let added = await store.importOPML(data)
            status = "\(added) akış içe aktarıldı."
        }
    }

    private func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Okumalik.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportOPML().write(to: url, atomically: true, encoding: .utf8)
            status = "\(store.feeds.count) akış dışa aktarıldı."
        } catch {
            status = error.localizedDescription
        }
    }
}
