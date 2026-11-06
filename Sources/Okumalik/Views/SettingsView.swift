import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @AppStorage("readerMode") private var reader = true
    @AppStorage("refreshMinutes") private var refreshMinutes = 30
    @AppStorage(Store.readRetentionKey) private var readRetention = 30
    @AppStorage(Store.copyRetentionKey) private var copyRetention = 30
    @AppStorage(Store.obsidianFolderKey) private var obsidianFolder = ""
    @AppStorage("compactList") private var compact = false
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @State private var status: String?
    @State private var pendingRestore: Store.Snapshot?
    @State private var renamingTag: String?
    @State private var deletingTag: String?
    @State private var newTagName = ""

    private static let bookmarklets: [(String, String)] = [
        ("Sonra Oku", "add"),
        ("Yer İmi", "bookmark"),
        ("Akışa Abone Ol", "feed"),
    ]

    var body: some View {
        TabView {
            tab {
                Section {
                    Picker("Uygulama", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Görünüm")
                } footer: {
                    Text("Okuma teması Otomatik ise yazı alanı da uygulamanın görünümünü izler. Kâğıt, Beyaz, Sepya ya da Gece seçiliyse o tema korunur.")
                        .foregroundStyle(.secondary)
                }
                Section("Okuma") {
                    Toggle("Sayfaları okuma modunda aç", isOn: $reader)
                }
                Section("Liste") {
                    Toggle("Sıkı liste (tek satır, görselsiz)", isOn: $compact)
                }
            }
            .tabItem { Label("Genel", systemImage: "gearshape") }

            tagsTab
                .tabItem { Label("Etiketler", systemImage: "number") }

            tab {
                Section {
                    Picker("Otomatik yenile", selection: $refreshMinutes) {
                        Text("15 dakikada bir").tag(15)
                        Text("30 dakikada bir").tag(30)
                        Text("Saatte bir").tag(60)
                        Text("3 saatte bir").tag(180)
                    }
                    Picker("Okunmuş yazıları sil", selection: $readRetention) { retentionOptions }
                    Picker("Kayıtlı kopyaları sil", selection: $copyRetention) { retentionOptions }
                    HStack {
                        Button("OPML İçe Aktar…", action: importOPML)
                        Button("OPML Dışa Aktar…", action: exportOPML)
                            .disabled(store.feeds.isEmpty)
                    }
                } header: {
                    Text("Akışlar")
                } footer: {
                    Text("Okunmamış yazılar hiç silinmez. Kayıtlı kopyalar, okuma modunda açılan yazıların çevrimdışı hâlleridir; Okunacaklar'daki, Yer İmleri'ndeki ve vurgu yaptığınız yazıların kopyaları silinmez. Temizlik akışlar yenilenince yapılır.")
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Akışlar", systemImage: "dot.radiowaves.up.forward") }

            tab {
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

                Section {
                    LabeledContent("Klasör") {
                        Text(obsidianFolder.isEmpty ? "Seçilmedi" : (obsidianFolder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack {
                        Button("Seç…", action: chooseObsidianFolder)
                        if !obsidianFolder.isEmpty { Button("Kaldır") { obsidianFolder = "" } }
                    }
                } header: {
                    Text("Obsidian")
                } footer: {
                    Text("Okurken \"…\" menüsündeki \"Obsidian'a Gönder\", yazıyı notunuz ve vurgularınızla birlikte bu klasöre Markdown notu olarak kaydeder.")
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Kaydetme", systemImage: "square.and.arrow.down") }

            tab {
                Section {
                    HStack {
                        Button("Yedeği Dışa Aktar…", action: exportLibrary)
                        Button("Yedekten Geri Yükle…", action: chooseBackup)
                    }
                    HStack {
                        Button("Yer İmlerini İçe Aktar…", action: importBookmarks)
                        Button("Yer İmlerini Dışa Aktar…", action: exportBookmarks)
                    }
                    HStack {
                        Button("Veri Klasörünü Göster") { NSWorkspace.shared.open(Store.dataDirectory) }
                        Button("Otomatik Yedekler") { NSWorkspace.shared.open(Store.backupDirectory) }
                    }
                } header: {
                    Text("Veri")
                } footer: {
                    Text("Kitaplık her gün kendiliğinden yedeklenir; son 10 günün yedeği tutulur. Yer imleri Firefox, Chrome, Safari ya da Linkding'in HTML biçimiyle aktarılır.")
                        .foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Veri", systemImage: "externaldrive") }
        }
        .alert("Yedek geri yüklensin mi?", isPresented: restoreAlert) {
            Button("Geri Yükle", role: .destructive) {
                if let backup = pendingRestore { store.restoreLibrary(backup) }
                status = "Yedek geri yüklendi."
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            if let b = pendingRestore {
                Text("Yedekte \(b.items.count) bağlantı, \(b.feeds.count) akış ve \(b.highlights.count) vurgu var. Şimdiki kitaplık bunlarla değiştirilecek; değiştirilmeden önce otomatik yedeklerin arasına kaydedilir.")
            }
        }
        .frame(width: 500)
    }

    /// Tags can be many, so this tab scrolls at a fixed height.
    private var tagsTab: some View {
        let counts = store.tagCounts
        return Form {
            Section {
                if counts.isEmpty {
                    Text("Henüz etiket yok.").foregroundStyle(.secondary)
                }
                ForEach(store.allTags, id: \.self) { tag in
                    LabeledContent {
                        HStack(spacing: 10) {
                            Text("\(counts[tag] ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                            Button { newTagName = tag; renamingTag = tag } label: { Image(systemName: "pencil") }
                                .help("Yeniden adlandır")
                            Button { deletingTag = tag } label: { Image(systemName: "trash") }
                                .help("Sil")
                        }
                        .buttonStyle(.borderless)
                    } label: {
                        Text("#" + tag).lineLimit(1)
                    }
                }
            } footer: {
                Text("Sayılar, etiketi taşıyan bağlantı ve akış sayısıdır. Listeyi etikete göre süzmek için başlıktaki # düğmesini kullanın ya da aramaya #etiket yazın.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
        .alert("Etiketi Yeniden Adlandır", isPresented: Binding(get: { renamingTag != nil }, set: { if !$0 { renamingTag = nil } })) {
            TextField("Ad", text: $newTagName)
            Button("Kaydet") { if let old = renamingTag { store.renameTag(old, to: newTagName) } }
            Button("Vazgeç", role: .cancel) {}
        }
        .confirmationDialog("“#\(deletingTag ?? "")” etiketi silinsin mi?",
                            isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } })) {
            Button("Etiketi Sil", role: .destructive) { if let tag = deletingTag { store.deleteTag(tag) } }
        } message: {
            Text("Bağlantılar ve akışlar silinmez, yalnızca bu etiket kaldırılır.")
        }
    }

    /// One settings tab: a grouped form sized to its content, with the last action's result below.
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form {
            content()
            if let status {
                Text(status).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var restoreAlert: Binding<Bool> {
        Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    }

    @ViewBuilder
    private var retentionOptions: some View {
        Text("7 gün sonra").tag(7)
        Text("30 gün sonra").tag(30)
        Text("90 gün sonra").tag(90)
        Text("Hiçbir zaman").tag(0)
    }

    private func copyBookmarklet(_ action: String) {
        // Wrapped so the bookmarklet returns nothing; a returned string would replace the page.
        let js = "javascript:(function(){location.href='okumalik://\(action)?url='+encodeURIComponent(location.href)+'&title='+encodeURIComponent(document.title);})();"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(js, forType: .string)
        status = "Yer imciği panoya kopyalandı."
    }

    private func chooseObsidianFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Seç"
        panel.message = "Obsidian kasanızda notların kaydedileceği klasörü seçin."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        obsidianFolder = url.path
    }

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Okumalik-yedek-\(Date().formatted(.iso8601.year().month().day())).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportLibrary(to: url)
            status = "Yedek kaydedildi."
        } catch {
            status = error.localizedDescription
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = Store.backupDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            pendingRestore = try Store.readLibrary(at: url)
        } catch {
            status = "Bu dosya bir Okumalık yedeği değil."
        }
    }

    private func importBookmarks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let result = store.importBookmarks(HTMLTools.decode(data))
        status = "\(result.added) yer imi eklendi" + (result.skipped > 0 ? ", \(result.skipped) tanesi zaten vardı." : ".")
    }

    private func exportBookmarks() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Okumalik-yer-imleri.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportBookmarks().write(to: url, atomically: true, encoding: .utf8)
            status = "\(store.items.count) bağlantı dışa aktarıldı."
        } catch {
            status = error.localizedDescription
        }
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
