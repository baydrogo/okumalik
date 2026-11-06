import SwiftUI

/// The reading pane: the page, a floating bar of tools over it and the side panel.
struct DetailView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var colorScheme
    let selection: DetailID?

    @AppStorage("readerMode") private var reader = true
    @AppStorage("readerFont") private var font: ReaderFont = .newYork
    @AppStorage("readerSize") private var size = 19
    @AppStorage("readerTheme") private var theme: ReaderTheme = .auto
    @AppStorage("showPanel") private var showPanel = false
    @StateObject private var proxy = ReaderProxy()
    @State private var showTypography = false
    @State private var editing: UUID?
    /// The floating bar hides while scrolling down and returns when scrolling up or pointing at it.
    @State private var barVisible = true
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
        ReaderStyle(font: font, size: size, theme: theme, windowDark: colorScheme == .dark)
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
        .onReceive(NotificationCenter.default.publisher(for: .okmNote)) { _ in proxy.addNote() }
        .onReceive(NotificationCenter.default.publisher(for: .okmPanel)) { _ in showPanel.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .okmFind)) { _ in
            guard subject != nil else { return }
            finding = true
            findFocused = true
        }
        .onChange(of: selection) {
            finding = false
            barVisible = true
        }
        .sheet(item: Binding(get: { editing.map(EditID.init) }, set: { editing = $0?.id })) { ItemEditSheet(id: $0.id) }
    }

    private struct EditID: Identifiable { let id: UUID }

    private func page(_ subject: Subject) -> some View {
        let url = subject.url
        let title = subject.title
        var focus: UUID?
        if case .highlight(let h) = subject { focus = h.id }
        var item: SavedItem?
        if case .item(let i) = subject { item = i }
        var entry: FeedEntry?
        if case .entry(let e) = subject { entry = e }

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
        } onNote: { id, note in
            store.setHighlightNote(id, note)
        } onDiscard: { id in
            store.discardHighlight(id)
        } onProgress: { value in
            store.setPosition(value, for: url)
        } onScrollDirection: { down in
            withAnimation(.easeOut(duration: 0.2)) { barVisible = !down }
        }
        .background(Color(nsColor: reader ? style.backgroundColor : .textBackgroundColor))
        .overlay(alignment: .topTrailing) { floatingBar(subject) }
        .overlay(alignment: .top) {
            // While the bar is hidden, pointing at the top edge brings it back.
            if !barVisible {
                Color.clear.frame(height: 44).contentShape(Rectangle())
                    .onHover { if $0 { withAnimation(.easeOut(duration: 0.2)) { barVisible = true } } }
            }
        }
        .overlay(alignment: .top) { if finding { findBar } }
        .inspector(isPresented: $showPanel) {
            SidePanel(url: url, title: title, item: item, entry: entry, proxy: proxy)
                .inspectorColumnWidth(min: 240, ideal: 290, max: 400)
        }
    }

    // MARK: Floating bar

    private func floatingBar(_ subject: Subject) -> some View {
        HStack(spacing: 2) {
            barButton("textformat.size", "Yazı tipi, boyut ve arka plan") { showTypography.toggle() }
                .popover(isPresented: $showTypography, arrowEdge: .bottom) {
                    TypographyPanel(reader: $reader, font: $font, size: $size, theme: $theme)
                }
            barButton("highlighter", "Seçili metni vurgula (⇧⌘H)") { proxy.highlight() }
            barButton("sidebar.right", "Bilgi ve vurgular (⌥⌘I)") { showPanel.toggle() }

            if case .item(let item) = subject, item.kind == .readLater {
                barButton(item.isRead ? "tray.and.arrow.up" : "archivebox",
                          item.isRead ? "Okunacaklara geri al (⌘E)" : "Arşivle (⌘E)") {
                    store.setRead(item.id, !item.isRead)
                }
                .keyboardShortcut("e")
            }
            if case .entry(let entry) = subject {
                let queued = store.queuedItem(for: entry.link) != nil
                barButton(queued ? "checkmark.circle.fill" : "tray.and.arrow.down",
                          queued ? "Okunacaklarda; çıkarmak için tıklayın (⌘S)" : "Okunacaklara ekle (⌘S)") {
                    store.toggleQueued(entry)
                }
                .foregroundStyle(queued ? Color.okmAccent : .secondary)
                .keyboardShortcut("s")
            }
            barButton("safari", "Tarayıcıda aç (⌘O)") { Actions.open(subject.url) }
                .keyboardShortcut("o")

            Menu {
                moreMenu(subject)
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diğer")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(12)
        .opacity(barVisible || showTypography ? 1 : 0)
        .allowsHitTesting(barVisible || showTypography)
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .help(help)
    }

    // MARK: Find

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

    // MARK: More menu

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
