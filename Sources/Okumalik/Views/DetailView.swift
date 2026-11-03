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
    }

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
            proxy: proxy
        ) { id, text in
            store.addHighlight(id: id, url: url, title: title, text: text)
        } onDelete: { id in
            store.deleteHighlight(id)
        }
        .background(Color(nsColor: reader ? style.backgroundColor : .textBackgroundColor))
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
                Button { store.save(entry, as: .readLater) } label: {
                    Label("Sonra Oku", systemImage: "tray.and.arrow.down")
                }
                .help("Okunacaklara ekle")
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

    @ViewBuilder
    private func moreMenu(_ subject: Subject) -> some View {
        switch subject {
        case .item(let item):
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
        proxy.article { info in
            guard let info, !(info.markdown ?? "").isEmpty else { return NSSound.beep() }
            use(Store.articleMarkdown(info, fallbackTitle: subject.title, highlights: highlights))
        }
    }
}

/// Inspector listing the highlights of the page on screen.
struct HighlightsPanel: View {
    @EnvironmentObject private var store: Store
    let url: URL
    let title: String
    let proxy: ReaderProxy

    var body: some View {
        let list = store.highlights(for: url)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Vurgular").font(.system(size: 15, weight: .semibold, design: .serif))
                Spacer()
                if !list.isEmpty {
                    Text("\(list.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if list.isEmpty {
                Spacer()
                Text("Metni seçip ⇧⌘H’ye basın ya da sağ tıklayıp “Vurgula”yı seçin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(list) { h in
                            HighlightQuote(highlight: h)
                                .contentShape(Rectangle())
                                .onTapGesture { proxy.scroll(to: h.id) }
                                .contextMenu {
                                    Button("Metni Kopyala") { Actions.copyText(h.text) }
                                    Button("Markdown Olarak Kopyala") {
                                        Actions.copyText(Store.markdown(title: title, url: url, highlights: [h]))
                                    }
                                    Divider()
                                    Button("Vurguyu Sil", role: .destructive) { store.deleteHighlight(h.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                Divider()
                HStack {
                    Button("Markdown Kopyala") {
                        Actions.copyText(Store.markdown(title: title, url: url, highlights: list))
                    }
                    Spacer()
                    Button("Dışa Aktar…") {
                        Actions.saveMarkdown(Store.markdown(title: title, url: url, highlights: list), name: title)
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(12)
            }
        }
    }
}

struct HighlightQuote: View {
    let highlight: Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 0.95, green: 0.76, blue: 0.20))
                .frame(width: 2)
            Text(highlight.text)
                .font(.system(size: 13, design: .serif))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
