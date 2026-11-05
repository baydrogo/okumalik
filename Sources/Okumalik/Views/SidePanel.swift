import SwiftUI

/// The reading pane's right-hand panel: the article's details, or its highlights.
struct SidePanel: View {
    let url: URL
    let title: String
    let item: SavedItem?
    let entry: FeedEntry?
    let proxy: ReaderProxy
    @AppStorage("panelTab") private var tab = Tab.info

    enum Tab: String { case info, highlights }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Bilgi").tag(Tab.info)
                Text("Vurgular").tag(Tab.highlights)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            switch tab {
            case .info: InfoPanel(url: url, title: title, item: item, entry: entry)
            case .highlights: HighlightsPanel(url: url, title: title, proxy: proxy)
            }
        }
    }
}

/// What is known about the article: from the offline copy, the saved link or the feed.
struct InfoPanel: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var cache = ArticleCache.shared
    let url: URL
    let title: String
    let item: SavedItem?
    let entry: FeedEntry?

    private static let dateFormat = Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "tr_TR"))

    var body: some View {
        let article = cache.article(for: url)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(article?.title ?? title)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                if let description = article?.description ?? item?.excerpt, !description.isEmpty {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    row("Site", article?.site ?? url.host()?.replacingOccurrences(of: "www.", with: ""))
                    row("Yazar", article?.author.flatMap { $0.isEmpty ? nil : $0 } ?? item?.author)
                    row("Yayın", article?.published.flatMap(DateParsing.parse).map { $0.formatted(Self.dateFormat) }
                        ?? article?.published.flatMap { $0.isEmpty ? nil : $0 } ?? entry?.date.map { $0.formatted(Self.dateFormat) })
                    if let words = article?.wordCount, words > 0 {
                        row("Uzunluk", "\(words.formatted()) kelime · \(cache.minutes(for: url) ?? 1) dk")
                    }
                    if let p = store.position(for: url), p > 0.01 { row("Okunan", "%\(Int(p * 100))") }
                    if let entry { row("Akış", store.feed(entry.feedID)?.title) }
                    if let item { row("Eklendi", item.dateAdded.formatted(Self.dateFormat)) }
                    row("Kopya", cache.contains(url) ? "Çevrimdışı okunabilir" : "Yok")
                }

                VStack(alignment: .leading, spacing: 4) {
                    label("Adres")
                    Button { Actions.open(url) } label: {
                        Text(url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(Color.okmAccent)
                            .multilineTextAlignment(.leading)
                            .lineLimit(3)
                    }
                    .buttonStyle(.plain)
                    .help("Tarayıcıda aç")
                }

                if let item {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        label("Etiketler")
                        TagEditor(tags: store.tagBinding(.item(item.id)))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        label("Not")
                        TextField("Kendiniz için bir not", text: store.noteBinding(item.id), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...12)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func row(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                Text(value).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
