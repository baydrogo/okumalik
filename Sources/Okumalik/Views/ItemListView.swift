import SwiftUI

/// The middle column: the links, highlights or feed entries of the chosen section.
struct ItemListView: View {
    @EnvironmentObject private var store: Store
    let section: SidebarSection
    @Binding var selection: Set<DetailID>
    let search: String
    @AppStorage("unreadOnly") private var unreadOnly = false
    @AppStorage("queueSort") private var queueSort = QueueSort.newest
    @AppStorage("queueLength") private var queueLength = QueueLength.all
    @State private var editing: UUID?
    @State private var tagFilter: String?
    @State private var confirmEmptyTrash = false

    enum QueueSort: String { case newest, oldest, shortest }
    enum QueueLength: String { case all, short, medium, long }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !stripTags.isEmpty { tagStrip }
            Divider().opacity(0.5)
            content
        }
        .onChange(of: section) { tagFilter = nil }
        .dropDestination(for: URL.self) { urls, _ in
            let kind: ItemKind = section == .bookmarks ? .bookmark : .readLater
            urls.filter { $0.scheme?.hasPrefix("http") == true }.forEach { store.addLink($0, kind: kind) }
            return !urls.isEmpty
        }
        .sheet(item: Binding(get: { editing.map(EditID.init) }, set: { editing = $0?.id })) { ItemEditSheet(id: $0.id) }
        .confirmationDialog("Çöp kutusu boşaltılsın mı?", isPresented: $confirmEmptyTrash) {
            Button("Çöpü Boşalt", role: .destructive) {
                selection.removeAll()
                store.emptyTrash()
            }
        } message: {
            Text("Bu işlem geri alınamaz.")
        }
    }

    private struct EditID: Identifiable { let id: UUID }

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    private func matches(_ fields: String...) -> Bool {
        query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .readLater, .archive, .bookmarks: savedList
        case .highlights: highlightList
        case .trash: trashList
        case .allFeeds, .feed: entryList
        case .tag(let tag): tagList(tag)
        }
    }

    // MARK: Header

    private var title: String {
        switch section {
        case .readLater: "Okunacaklar"
        case .archive: "Arşiv"
        case .bookmarks: "Yer İmleri"
        case .highlights: "Vurgular"
        case .trash: "Çöp Kutusu"
        case .allFeeds: "Akışlar"
        case .feed(let id): store.feed(id)?.title ?? "Akış"
        case .tag(let tag): "#" + tag
        }
    }

    private var subtitle: String {
        switch section {
        case .readLater, .archive, .bookmarks: "\(savedItems.count) bağlantı"
        case .highlights: "\(store.highlights.count) vurgu"
        case .trash: "\(Store.trashDays) gün sonra kalıcı olarak silinir"
        case .allFeeds: "\(store.unreadCount(feed: nil)) okunmamış"
        case .feed(let id): feedStatus(id)
        case .tag(let tag):
            "\(store.items.filter { $0.tags.contains(tag) }.count) bağlantı · \(store.feeds.filter { $0.tags.contains(tag) }.count) akış"
        }
    }

    private func feedStatus(_ id: UUID) -> String {
        let unread = "\(store.unreadCount(feed: id)) okunmamış"
        guard let feed = store.feed(id) else { return unread }
        if let error = feed.lastError { return "Güncellenemedi: \(error)" }
        guard let date = feed.lastUpdated else { return unread }
        return unread + " · güncellendi " + date.formatted(.relative(presentation: .named))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            headerActions
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var headerActions: some View {
        switch section {
        case .readLater:
            Menu {
                Picker("Sırala", selection: $queueSort) {
                    Text("En yeni önce").tag(QueueSort.newest)
                    Text("En eski önce").tag(QueueSort.oldest)
                    Text("En kısa önce").tag(QueueSort.shortest)
                }
                Picker("Okuma süresi", selection: $queueLength) {
                    Text("Tümü").tag(QueueLength.all)
                    Text("5 dakikadan kısa").tag(QueueLength.short)
                    Text("5–15 dakika").tag(QueueLength.medium)
                    Text("15 dakikadan uzun").tag(QueueLength.long)
                }
            } label: {
                Image(systemName: queueSort == .newest && queueLength == .all
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .pickerStyle(.inline)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sırala ve süz")
        case .allFeeds, .feed:
            Button { unreadOnly.toggle() } label: {
                Image(systemName: unreadOnly ? "circle.inset.filled" : "circle")
            }
            .help(unreadOnly ? "Tümünü göster" : "Yalnızca okunmamışları göster")
            Button {
                if case .feed(let id) = section { store.markAllRead(feed: id) } else { store.markAllRead(feed: nil) }
            } label: {
                Image(systemName: "checkmark")
            }
            .help("Tümünü okundu say")
        case .highlights:
            Menu {
                Button("Tümünü Markdown Olarak Kopyala") { Actions.copyText(store.markdownForAllHighlights()) }
                Button("Markdown Dosyası Olarak Kaydet…") {
                    Actions.saveMarkdown(store.markdownForAllHighlights(), name: "Vurgular")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(store.highlights.isEmpty)
            .help("Vurguları dışa aktar")
        case .trash:
            Button("Boşalt") { confirmEmptyTrash = true }
                .disabled(store.trash.isEmpty && store.trashedHighlights.isEmpty)
        default:
            EmptyView()
        }
    }

    // MARK: Tag filter

    /// Tags used in this section, offered as filters under the header.
    private var stripTags: [String] {
        switch section {
        case .readLater, .archive, .bookmarks: Store.cleanTags(sectionItems.flatMap(\.tags))
        case .allFeeds: Store.cleanTags(store.feeds.flatMap(\.tags))
        default: []
        }
    }

    /// The chosen filter, ignored once no item in the section carries it.
    private var activeTag: String? {
        tagFilter.flatMap { stripTags.contains($0) ? $0 : nil }
    }

    private var tagStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(stripTags, id: \.self) { tag in
                    TagChip(tag: tag, selected: tag == activeTag,
                            help: tag == activeTag ? "Süzgeci kaldır" : "Yalnızca #\(tag) olanları göster") {
                        tagFilter = tag == activeTag ? nil : tag
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 10)
    }

    // MARK: Lists

    /// A list with the shared context menu, double-click and Delete behaviour.
    private func list<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        List(selection: $selection, content: rows)
            .listStyle(.plain)
            .contextMenu(forSelectionType: DetailID.self) { ids in
                if ids.count == 1, let id = ids.first { menu(for: id) } else if ids.count > 1 { bulkMenu(ids) }
            } primaryAction: { ids in
                ids.compactMap(url(for:)).forEach(Actions.open)
            }
            .onDeleteCommand { delete(selection) }
    }

    private var sectionItems: [SavedItem] {
        store.items.filter { item in
            switch section {
            case .readLater: item.kind == .readLater && !item.isRead
            case .archive: item.kind == .readLater && item.isRead
            case .bookmarks: item.kind == .bookmark
            default: false
            }
        }
    }

    private var savedItems: [SavedItem] {
        let tag = activeTag
        let list = sectionItems
            .filter { tag == nil || $0.tags.contains(tag!) }
            .filter { query.isEmpty || store.matches($0, query) }
        return section == .readLater ? arranged(list) : list
    }

    /// Okunacaklar's sort order and reading-time filter.
    private func arranged(_ list: [SavedItem]) -> [SavedItem] {
        let minutes = { (item: SavedItem) in ArticleCache.shared.minutes(for: item.url) }
        let filtered = list.filter { item in
            guard queueLength != .all else { return true }
            guard let m = minutes(item) else { return false }
            switch queueLength {
            case .short: return m < 5
            case .medium: return (5...15).contains(m)
            case .long: return m > 15
            case .all: return true
            }
        }
        switch queueSort {
        case .newest: return filtered.sorted { $0.dateAdded > $1.dateAdded }
        case .oldest: return filtered.sorted { $0.dateAdded < $1.dateAdded }
        case .shortest: return filtered.sorted { (minutes($0) ?? .max) < (minutes($1) ?? .max) }
        }
    }

    @ViewBuilder
    private var savedList: some View {
        let items = savedItems
        if items.isEmpty {
            emptyState
        } else {
            list { ForEach(items, id: \.rowKey, content: savedRow) }
        }
    }

    private func savedRow(_ item: SavedItem) -> some View {
        Group {
            if section == .bookmarks {
                BookmarkRow(
                    item: item,
                    onTag: { tagFilter = $0 },
                    onEdit: { editing = item.id },
                    onMove: { store.setKind(item.id, .readLater) },
                    onDelete: { delete([.item(item.id)]) }
                )
            } else {
                SavedRow(item: item)
            }
        }
        .tag(DetailID.item(item.id))
        .draggable(TagTarget.item(item.id).dragToken)
    }

    @ViewBuilder
    private func tagList(_ tag: String) -> some View {
        let tagged = store.items.filter { $0.tags.contains(tag) && (query.isEmpty || store.matches($0, query)) }
        let groups: [(String, [SavedItem])] = [
            ("Okunacaklar", tagged.filter { $0.kind == .readLater && !$0.isRead }),
            ("Yer İmleri", tagged.filter { $0.kind == .bookmark }),
            ("Arşiv", tagged.filter { $0.kind == .readLater && $0.isRead }),
        ].filter { !$0.1.isEmpty }
        let feedIDs = Set(store.feeds.filter { $0.tags.contains(tag) }.map(\.id))
        let entries = store.entries
            .filter { feedIDs.contains($0.feedID) && matches($0.title, $0.summary) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(150)
        if groups.isEmpty && entries.isEmpty {
            emptyState
        } else {
            list {
                ForEach(groups, id: \.0) { group in
                    Section {
                        ForEach(group.1, id: \.rowKey, content: savedRow)
                    } header: {
                        sectionHeader(group.0)
                    }
                }
                if !entries.isEmpty {
                    let queued = queuedKeys
                    Section {
                        ForEach(entries) { entryRow($0, showFeed: true, queued: queued) }
                    } header: {
                        sectionHeader("Akışlar")
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var highlightList: some View {
        let groups = store.highlightGroups { matches($0.text, $0.pageTitle, $0.note ?? "") }
        if groups.isEmpty {
            emptyState
        } else {
            list {
                ForEach(groups, id: \.url) { group in
                    Section {
                        ForEach(group.items) { h in
                            HighlightQuote(highlight: h)
                                .padding(.vertical, 4)
                                .tag(DetailID.highlight(h.id))
                        }
                    } header: {
                        sectionHeader(group.title)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trashList: some View {
        let links = store.trash.filter { matches($0.title, $0.url.absoluteString) }
        let quotes = store.trashedHighlights.filter { matches($0.text, $0.pageTitle) }
        if links.isEmpty && quotes.isEmpty {
            emptyState
        } else {
            list {
                if !links.isEmpty {
                    Section {
                        ForEach(links) { SavedRow(item: $0).tag(DetailID.item($0.id)) }
                    } header: {
                        sectionHeader("Bağlantılar")
                    }
                }
                if !quotes.isEmpty {
                    Section {
                        ForEach(quotes) { h in
                            HighlightQuote(highlight: h).padding(.vertical, 4).tag(DetailID.highlight(h.id))
                        }
                    } header: {
                        sectionHeader("Vurgular")
                    }
                }
            }
        }
    }

    private var feedEntries: [FeedEntry] {
        var feedID: UUID?
        if case .feed(let id) = section { feedID = id }
        let taggedFeeds = activeTag.map { tag in Set(store.feeds.filter { $0.tags.contains(tag) }.map(\.id)) }
        return store.entries
            .filter { feedID == nil || $0.feedID == feedID }
            .filter { taggedFeeds == nil || taggedFeeds!.contains($0.feedID) }
            .filter { !unreadOnly || !$0.isRead || selection.contains(.entry($0.id)) }
            .filter { matches($0.title, $0.summary, $0.link.absoluteString) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    @ViewBuilder
    private var entryList: some View {
        let entries = feedEntries
        if entries.isEmpty {
            emptyState
        } else {
            let queued = queuedKeys
            list { ForEach(entries) { entryRow($0, showFeed: section == .allFeeds, queued: queued) } }
        }
    }

    /// Addresses on the reading list, worked out once per list rather than per row.
    private var queuedKeys: Set<String> {
        Set(store.items.filter { $0.kind == .readLater && !$0.isRead }.map(\.url.dedupeKey))
    }

    private func entryRow(_ entry: FeedEntry, showFeed: Bool, queued: Set<String>) -> some View {
        EntryRow(entry: entry, feedTitle: showFeed ? store.feed(entry.feedID)?.title : nil,
                 queued: queued.contains(entry.link.dedupeKey))
            .tag(DetailID.entry(entry.id))
    }

    // MARK: Actions

    private func url(for id: DetailID) -> URL? {
        switch id {
        case .item(let i): (store.items + store.trash).first { $0.id == i }?.url
        case .entry(let e): store.entries.first { $0.id == e }?.link
        case .highlight(let h): (store.highlights + store.trashedHighlights).first { $0.id == h }?.url
        }
    }

    /// Delete key and "Sil": links and highlights go to the trash; nothing happens inside the trash.
    private func delete(_ ids: Set<DetailID>) {
        guard section != .trash else { return }
        var links = Set<UUID>()
        for id in ids {
            switch id {
            case .item(let i): links.insert(i)
            case .highlight(let h): store.deleteHighlight(h)
            case .entry: continue
            }
        }
        store.deleteItems(links)
        selection.subtract(ids)
    }

    private func restore(_ ids: Set<DetailID>) {
        for id in ids {
            if case .item(let i) = id { store.restoreItem(i) }
            if case .highlight(let h) = id { store.restoreHighlight(h) }
        }
        selection.subtract(ids)
    }

    private func purge(_ ids: Set<DetailID>) {
        for id in ids {
            if case .item(let i) = id { store.purgeItem(i) }
            if case .highlight(let h) = id { store.purgeHighlight(h) }
        }
        selection.subtract(ids)
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(for id: DetailID) -> some View {
        if section == .trash {
            Button("Geri Yükle") { restore([id]) }
            Divider()
            Button("Kalıcı Olarak Sil", role: .destructive) { purge([id]) }
        } else {
            switch id {
            case .item(let itemID):
                if let item = store.items.first(where: { $0.id == itemID }) { savedMenu(item) }
            case .entry(let entryID):
                if let entry = store.entries.first(where: { $0.id == entryID }) { entryMenu(entry) }
            case .highlight(let highlightID):
                if let h = store.highlights.first(where: { $0.id == highlightID }) { highlightMenu(h) }
            }
        }
    }

    @ViewBuilder
    private func savedMenu(_ item: SavedItem) -> some View {
        Button("Tarayıcıda Aç") { Actions.open(item.url) }
        Button("Bağlantıyı Kopyala") { Actions.copy(item.url) }
        Divider()
        Button("Düzenle…") { editing = item.id }
        TagMenu(targets: [.item(item.id)])
        Divider()
        if item.kind == .readLater {
            Button(item.isRead ? "Okunacaklara Geri Al" : "Arşivle") { store.setRead(item.id, !item.isRead) }
            Button("Yer İmlerine Taşı") { store.setKind(item.id, .bookmark) }
        } else {
            Button("Okunacaklara Taşı") { store.setKind(item.id, .readLater) }
        }
        Divider()
        Button("Sil", role: .destructive) { delete([.item(item.id)]) }
    }

    @ViewBuilder
    private func entryMenu(_ entry: FeedEntry) -> some View {
        Button("Tarayıcıda Aç") { Actions.open(entry.link) }
        Button("Bağlantıyı Kopyala") { Actions.copy(entry.link) }
        Divider()
        Button(entry.isRead ? "Okunmadı Olarak İşaretle" : "Okundu Olarak İşaretle") { store.setEntryRead(entry.id, !entry.isRead) }
        Button(store.queuedItem(for: entry.link) != nil ? "Okunacaklardan Çıkar" : "Okunacaklara Ekle") { store.toggleQueued(entry) }
        Button("Yer İmi Olarak Kaydet") { store.save(entry, as: .bookmark) }
        Divider()
        TagMenu(targets: [.feed(entry.feedID)], title: "Akışın Etiketleri")
    }

    @ViewBuilder
    private func highlightMenu(_ h: Highlight) -> some View {
        Button("Metni Kopyala") { Actions.copyText(h.text) }
        Button("Markdown Olarak Kopyala") {
            Actions.copyText(Store.markdown(title: h.pageTitle, url: h.url, highlights: [h]))
        }
        Button("Sayfanın Vurgularını Dışa Aktar…") {
            Actions.saveMarkdown(Store.markdown(title: h.pageTitle, url: h.url, highlights: store.highlights(for: h.url)), name: h.pageTitle)
        }
        Button("Tarayıcıda Aç") { Actions.open(h.url) }
        Divider()
        Button("Vurguyu Sil", role: .destructive) { delete([.highlight(h.id)]) }
    }

    /// Menu for several selected rows.
    @ViewBuilder
    private func bulkMenu(_ ids: Set<DetailID>) -> some View {
        let itemIDs = ids.compactMap { if case .item(let i) = $0 { i } else { nil } }
        let entryIDs = ids.compactMap { if case .entry(let e) = $0 { e } else { nil } }
        if section == .trash {
            Button("\(ids.count) Öğeyi Geri Yükle") { restore(ids) }
            Button("\(ids.count) Öğeyi Kalıcı Olarak Sil", role: .destructive) { purge(ids) }
        } else {
            if !itemIDs.isEmpty {
                Button("Arşivle") { itemIDs.forEach { store.setRead($0, true) } }
                Button("Okunacaklara Geri Al") { itemIDs.forEach { store.setRead($0, false) } }
                TagMenu(targets: itemIDs.map(TagTarget.item), title: "Etiket Ekle")
            }
            if !entryIDs.isEmpty {
                Button("Okundu Olarak İşaretle") { entryIDs.forEach { store.setEntryRead($0, true) } }
                Button("Okunmadı Olarak İşaretle") { entryIDs.forEach { store.setEntryRead($0, false) } }
                Button("Okunacaklara Ekle") {
                    store.entries.filter { entryIDs.contains($0.id) }.forEach { store.save($0, as: .readLater) }
                }
            }
            if entryIDs.count < ids.count {
                Divider()
                Button("\(ids.count - entryIDs.count) Öğeyi Sil", role: .destructive) { delete(ids) }
            }
        }
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            switch section {
            case .readLater where queueLength != .all:
                empty("Bu süreye uyan yazı yok", "Süzgeci sağ üstteki menüden değiştirin.")
            case .readLater:
                empty("Okunacak bir şey yok", "⌘N ile bağlantı ekleyin ya da bir bağlantıyı buraya sürükleyin.")
            case .archive:
                empty("Arşiv boş", "Okuduklarınızı arşivlediğinizde burada görünür.")
            case .bookmarks:
                empty("Yer imi yok", "⌘N ile yer imi ekleyin.")
            case .highlights:
                empty("Henüz vurgu yok", "Bir yazıda metni seçip ⇧⌘H’ye basın.")
            case .trash:
                empty("Çöp kutusu boş", "Silinen bağlantılar ve vurgular \(Store.trashDays) gün burada kalır.")
            case .allFeeds, .feed:
                empty(store.feeds.isEmpty ? "Akış yok" : "Yeni yazı yok",
                      store.feeds.isEmpty ? "⌘N ile bir site ya da RSS adresi ekleyin." : "Hepsini okudunuz.")
            case .tag:
                empty("Bu etikette bir şey yok", "Bağlantıları ya da akışları kenar çubuğundaki etikete sürükleyin.")
            }
        }
    }

    private func empty(_ title: String, _ message: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 15, weight: .medium))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension SavedItem {
    /// Row identity that changes with the text, so the list re-measures the row when the
    /// title or description arrives after the link was added (otherwise it keeps the first height).
    var rowKey: String { "\(id.uuidString)|\(title)|\(excerpt)" }
}
