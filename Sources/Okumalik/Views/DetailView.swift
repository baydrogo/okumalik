import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var colorScheme
    let selection: DetailID?

    @AppStorage("readerMode") private var reader = true
    @AppStorage("readerFont") private var font: ReaderFont = .newYork
    @AppStorage("readerSize") private var size = 19
    @AppStorage("readerTheme") private var theme: ReaderTheme = .auto
    @AppStorage("showHighlights") private var showHighlights = false
    @StateObject private var proxy = ReaderProxy()
    @State private var showTypography = false
    @State private var editing: UUID?
    @State private var finding = false
    @State private var findText = ""
    @State private var findMissed = false
    @FocusState private var findFocused: Bool

    private enum Subject {
        case item(SavedItem)
        case entry(FeedEntry)
        case highlight(Highlight)

        var url: URL {
            switch self {
            case .item(let i): i.url
            case .entry(let e): e.link
            case .highlight(let h): h.url
            }
        }

        var title: String {
            switch self {
            case .item(let i): i.title
            case .entry(let e): e.title
            case .highlight(let h): h.pageTitle
            }
        }
    }

    private var subject: Subject? {
        switch selection {
        case .item(let id): store.items.first { $0.id == id }.map(Subject.item)
        case .entry(let id): store.entries.first { $0.id == id }.map(Subject.entry)
        case .highlight(let id): store.highlights.first { $0.id == id }.map(Subject.highlight)
        case nil: nil
        }
    }

    private var style: ReaderStyle {
        ReaderStyle(font: font, size: size, theme: theme, systemDark: colorScheme == .dark)
    }

    var body: some View {
        Group {
            if case .item(let item) = subject, item.kind == .bookmark {
                BookmarkDetail(item: item)
            } else if let subject {
                page(subject)
            } else {
                ContentUnavailableView {
                    VStack(spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .opacity(0.9)
                        Text("Okumalık").font(.system(size: 22, weight: .semibold, design: .serif))
                    }
                } description: {
                    Text("Okumak için listeden bir yazı seçin.")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .okmHighlight)) { _ in proxy.highlight() }
        .onReceive(NotificationCenter.default.publisher(for: .okmFind)) { _ in
            guard subject != nil else { return }
            finding = true
            findFocused = true
        }
        .onChange(of: selection) { finding = false }
        .sheet(item: Binding(get: { editing.map(EditID.init) }, set: { editing = $0?.id })) { ItemEditSheet(id: $0.id) }
    }

    private struct EditID: Identifiable { let id: UUID }

    private func page(_ subject: Subject) -> some View {
        let url = subject.url
        let title = subject.title
        var focus: UUID?
        if case .highlight(let h) = subject { focus = h.id }

        return WebView(
            url: url,
            reader: reader,
            style: style,
            highlights: store.highlights(for: url),
            focus: focus,
            proxy: proxy,
            position: store.position(for: url)
        ) { id, text in
            store.addHighlight(id: id, url: url, title: title, text: text)
        } onDelete: { id in
            store.deleteHighlight(id)
        } onProgress: { value in
            store.setPosition(value, for: url)
        }
        .background(Color(nsColor: reader ? style.backgroundColor : .textBackgroundColor))
        .overlay(alignment: .top) { if finding { findBar } }
        .inspector(isPresented: $showHighlights) {
            HighlightsPanel(url: url, title: title, proxy: proxy)
                .inspectorColumnWidth(min: 220, ideal: 270, max: 380)
        }
        .toolbar { tools(subject) }
    }

    @ToolbarContentBuilder
    private func tools(_ subject: Subject) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if proxy.canGoBack {
                Button { proxy.goBack() } label: {
                    Label("Geri", systemImage: "chevron.left")
                }
                .help("Yazıya geri dön (⌘[)")
                .keyboardShortcut("[")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showTypography.toggle() } label: {
                Label("Görünüm", systemImage: "textformat.size")
            }
            .help("Yazı tipi, boyut ve arka plan")
            .popover(isPresented: $showTypography, arrowEdge: .bottom) {
                TypographyPanel(reader: $reader, font: $font, size: $size, theme: $theme)
            }

            Button { proxy.highlight() } label: {
                Label("Vurgula", systemImage: "highlighter")
            }
            .help("Seçili metni vurgula (⇧⌘H)")

            Button { showHighlights.toggle() } label: {
                Label("Vurgular", systemImage: "text.quote")
            }
            .help("Bu sayfanın vurguları")

            if case .item(let item) = subject, item.kind == .readLater {
                Button { store.setRead(item.id, !item.isRead) } label: {
                    Label(item.isRead ? "Okunacaklara Geri Al" : "Arşivle",
                          systemImage: item.isRead ? "tray.and.arrow.up" : "archivebox")
                }
                .help(item.isRead ? "Okunacaklara geri al" : "Arşivle (⌘E)")
                .keyboardShortcut("e")
            }
            if case .entry(let entry) = subject {
                let queued = store.queuedItem(for: entry.link) != nil
                Button { store.toggleQueued(entry) } label: {
                    Label(queued ? "Okunacaklarda" : "Okunacaklara Ekle",
                          systemImage: queued ? "checkmark" : "tray.and.arrow.down")
                        .labelStyle(.titleAndIcon)
                }
                .help(queued ? "Okunacaklardan çıkar (⌘S)" : "Okunacaklara ekle (⌘S)")
                .keyboardShortcut("s")
            }

            Button { Actions.open(subject.url) } label: {
                Label("Tarayıcıda Aç", systemImage: "safari")
            }
            .help("Varsayılan tarayıcıda aç (⌘O)")
            .keyboardShortcut("o")

            Menu {
                moreMenu(subject)
            } label: {
                Label("Diğer", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Diğer")
        }
    }

    /// ⌘F: find in the page; ↩ or ⌘G for the next match, ⇧⌘G for the previous one.
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Sayfada bul", text: $findText)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .focused($findFocused)
                .onSubmit { find(backwards: false) }
            if findMissed { Text("Bulunamadı").font(.caption).foregroundStyle(.secondary) }
            Button { find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button { find(backwards: false) } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g")
            Button { finding = false } label: { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .padding(10)
    }

    private func find(backwards: Bool) {
        proxy.find(findText, backwards: backwards) { found in findMissed = !found && !findText.isEmpty }
    }

    @ViewBuilder
    private func moreMenu(_ subject: Subject) -> some View {
        switch subject {
        case .item(let item):
            Button("Düzenle ve Not Ekle…") { editing = item.id }
            if item.kind == .readLater {
                Button("Yer İmlerine Taşı") { store.setKind(item.id, .bookmark) }
            } else {
                Button("Okunacaklara Taşı") { store.setKind(item.id, .readLater) }
            }
        case .entry(let entry):
            Button("Yer İmi Olarak Kaydet") { store.save(entry, as: .bookmark) }
            Button("Okunmadı Olarak İşaretle") { store.setEntryRead(entry.id, false) }
        case .highlight:
            EmptyView()
        }
        Divider()
        Button("Yazıyı Markdown Olarak Kopyala") { withArticle(subject) { Actions.copyText($0) } }
        Button("Yazıyı Markdown Olarak Dışa Aktar…") { withArticle(subject) { Actions.saveMarkdown($0, name: subject.title) } }
        Button("Obsidian'a Gönder") {
            withArticle(subject) { markdown in
                do {
                    let file = try Store.writeToObsidian(markdown, title: subject.title)
                    store.notify("Obsidian'a kaydedildi: \(file.deletingPathExtension().lastPathComponent)")
                } catch {
                    store.notify(error.localizedDescription)
                }
            }
        }
        let highlights = store.highlights(for: subject.url)
        if !highlights.isEmpty {
            Divider()
            Button("Vurguları Markdown Olarak Kopyala") {
                Actions.copyText(Store.markdown(title: subject.title, url: subject.url, highlights: highlights))
            }
            Button("Vurguları Dışa Aktar…") {
                Actions.saveMarkdown(Store.markdown(title: subject.title, url: subject.url, highlights: highlights), name: subject.title)
            }
        }
        Divider()
        if reader {
            Button("Yazıyı Siteden Yeniden Al") { proxy.refetch() }
        }
        Button("Bağlantıyı Kopyala") { Actions.copy(subject.url) }
        ShareLink("Paylaş…", item: subject.url)
    }

    private func withArticle(_ subject: Subject, _ use: @escaping (String) -> Void) {
        let highlights = store.highlights(for: subject.url)
        var note: String?
        if case .item(let item) = subject { note = item.note }
        proxy.article { info in
            guard let info, !(info.markdown ?? "").isEmpty else { return NSSound.beep() }
            use(Store.articleMarkdown(info, fallbackTitle: subject.title, note: note, highlights: highlights))
        }
    }
}
