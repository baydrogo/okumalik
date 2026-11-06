import SwiftUI

/// The middle column: the links, highlights or feed entries of the chosen section.
struct ItemListView: View {
    @EnvironmentObject private var store: Store
    let section: SidebarSection
    @Binding var selection: Set<DetailID>
    @Binding var search: String
    @FocusState private var searchFocused: Bool
    @AppStorage("unreadOnly") private var unreadOnly = false
    @AppStorage("queueSort") private var queueSort = QueueSort.newest
    @AppStorage("queueLength") private var queueLength = QueueLength.all
    @State private var editing: UUID?
    @State private var tagFilter: String?
    @State private var confirmEmptyTrash = false
    /// The search being applied: follows `search` after a short pause in typing.
    @State private var query = ""
    /// Pages found by what's inside them: highlights first, offline articles once scanned.
    @State private var searchHits = Set<URL>()
    /// Redraws the list when reading times change what Okunacaklar shows.
    @State private var copyVersion = 0
    @State private var memo = SavedMemo()

    enum QueueSort: String { case newest, oldest, shortest }
    enum QueueLength: String { case all, short, medium, long }

    var body: some View {
        let _ = copyVersion
        // Worked out once per update and handed down: these walk the whole library.
        let results = savedResults
        let counts = results.counts
        let active = results.active
        let saved = results.saved
        VStack(spacing: 0) {
            searchField
            header(counts: counts, active: active, savedCount: results.total)
            Divider().opacity(0.5)
            if query.isEmpty {
                content(saved: saved, active: active)
            } else {
                searchList(results)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .okmSearch)) { _ in searchFocused = true }
        .onChange(of: section) { tagFilter = nil }
        .task(id: search) { await applySearch() }
        .onReceive(ArticleCache.shared.changed) { _ in
            if section == .readLater, query.isEmpty, queueSort == .shortest || queueLength != .all { copyVersion &+= 1 }
        }
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

    /// The section's links, filtered and sorted, kept until something they depend on changes.
    /// Selecting a row, for one, redraws this view without changing any of it.
    private var savedResults: SavedMemo.Results {
        let key = SavedMemo.Key(version: store.itemsVersion, highlights: store.highlights.count, entries: store.entries.count, feedTags: section == .allFeeds ? store.feeds.map(\.tags) : [], section: section,
                                tag: tagFilter, query: query, hits: searchHits, sort: queueSort, length: queueLength, copies: copyVersion)
        if memo.key == key, let results = memo.results { return results }
        if !query.isEmpty {
            let results = searchResults
            memo.key = key
            memo.results = results
            return results
        }
        let base = sectionItems
        let counts = tagCounts(in: base)
        let active = tagFilter.flatMap { counts[$0] != nil ? $0 : nil }
        let results = SavedMemo.Results(counts: counts, active: active, saved: isSavedSection ? savedItems(base, tag: active) : [])
        memo.key = key
        memo.results = results
        return results
    }

    private var isSavedSection: Bool { section == .readLater || section == .archive || section == .bookmarks }

    /// Filters quickly by the link's own texts, then adds pages whose articles match when that scan is done.
    private func applySearch() async {
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            query = ""
            searchHits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        guard Store.tagQuery(text) == nil else {
            searchHits = []
            query = text
            return
        }
        searchHits = store.highlightHits(text)
        query = text
        let found = await ArticleCache.shared.search(text, in: store.items.map(\.url))
        guard !Task.isCancelled else { return }
        searchHits.formUnion(found)
    }

    private func matches(_ fields: String...) -> Bool {
        query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
    }

    @ViewBuilder
    private func content(saved: [SavedItem], active: String?) -> some View {
        switch section {
        case .readLater, .archive, .bookmarks: savedList(saved)
        case .highlights: highlightList
        case .trash: trashList
        case .allFeeds, .feed: entryList(active: active)
        }
    }

    // MARK: Header

    private var title: String {
        if !query.isEmpty { return "Arama" }
        return switch section {
        case .readLater: "Okunacaklar"
        case .archive: "Arşiv"
        case .bookmarks: "Yer İmleri"
        case .highlights: "Vurgular"
        case .trash: "Çöp Kutusu"
        case .allFeeds: "Akışlar"
        case .feed(let id): store.feed(id)?.title ?? "Akış"
        }
    }

    private func subtitle(savedCount: Int) -> String {
        if !query.isEmpty { return "\(savedCount) sonuç" }
        return switch section {
        case .readLater, .archive, .bookmarks: "\(savedCount) bağlantı"
        case .highlights: "\(store.highlights.count) vurgu"
        case .trash: "\(Store.trashDays) gün sonra kalıcı olarak silinir"
        case .allFeeds: "\(store.unreadCount(feed: nil)) okunmamış"
        case .feed(let id): feedStatus(id)
        }
    }

    private func feedStatus(_ id: UUID) -> String {
        let unread = "\(store.unreadCount(feed: id)) okunmamış"
        guard let feed = store.feed(id) else { return unread }
        if let error = feed.lastError { return "Güncellenemedi: \(error)" }
        guard let date = feed.lastUpdated else { return unread }
        return unread + " · güncellendi " + date.formatted(.relative(presentation: .named))
    }

    /// Searches the whole library from any section. ⌥⌘F comes here; Esc clears it.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Tüm kitaplıkta ara", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    search = ""
                    searchFocused = false
                }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Aramayı temizle")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .help("Başlık, özet, not, vurgu ve yazı içinde arar; etiket için #etiket yazın (⌥⌘F)")
    }

    private func header(counts: [String: Int], active: String?, savedCount: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(subtitle(savedCount: savedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let active {
                        TagChip(tag: active, selected: true, help: "Süzgeci kaldır") { tagFilter = nil }
                    }
                }
                // The chip is taller than the text; the list below shouldn't move when it appears.
                .frame(height: active == nil ? nil : 14)
            }
            Spacer()
            Group {
                if query.isEmpty {
                    if !counts.isEmpty { tagMenu(counts: counts, active: active) }
                    headerActions
                }
            }
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

    /// Tags used in this section and how often, offered by the header's "#" menu.
    private func tagCounts(in base: [SavedItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        switch section {
        case .readLater, .archive, .bookmarks:
            for item in base { for tag in item.tags { counts[tag, default: 0] += 1 } }
        case .allFeeds:
            for feed in store.feeds { for tag in feed.tags { counts[tag, default: 0] += 1 } }
        default:
            break
        }
        return counts
    }

    private func tagMenu(counts: [String: Int], active: String?) -> some View {
        Menu {
            if active != nil {
                Button("Tümünü Göster") { tagFilter = nil }
                Divider()
            }
            ForEach(counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { tag in
                Toggle("#\(tag)  \(counts[tag] ?? 0)", isOn: Binding(
                    get: { tag == active },
                    set: { tagFilter = $0 ? tag : nil }
                ))
            }
        } label: {
            Image(systemName: active == nil ? "number.circle" : "number.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Etikete göre süz")
    }

    // MARK: Lists

    /// A list with the shared context menu, double-click and Delete behaviour.
    /// With a key it is built again only when the key changes; its rows follow their own data.
    private func list<Rows: View>(key: ListKey? = nil, @ViewBuilder _ rows: @escaping () -> Rows) -> some View {
        StableList(key: key, selection: $selection, rows: rows) { ids in
            if ids.count == 1, let id = ids.first { menu(for: id) } else if ids.count > 1 { bulkMenu(ids) }
        } open: { ids in
            ids.compactMap(url(for:)).forEach(Actions.open)
        } delete: {
            delete(selection)
        }
        .equatable()
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

    private func savedItems(_ base: [SavedItem], tag: String?) -> [SavedItem] {
        let list = base
            .filter { tag == nil || $0.tags.contains(tag!) }
        return section == .readLater ? arranged(list) : list
    }

    /// Okunacaklar's sort order and reading-time filter.
    private func arranged(_ list: [SavedItem]) -> [SavedItem] {
        let cache = ArticleCache.shared
        let minutes = { (item: SavedItem) in cache.meta(for: item.url)?.minutes }
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
    private func savedList(_ items: [SavedItem]) -> some View {
        if items.isEmpty {
            emptyState
        } else {
            let keys = items.map(\.rowKey)
            list(key: ListKey(section: section, saved: keys)) {
                ForEach(keys, id: \.self) { key in
                    LiveItem(id: key.id, content: savedContent)
                        .tag(DetailID.item(key.id))
                }
            }
        }
    }

    @ViewBuilder
    private func savedContent(_ item: SavedItem) -> some View {
        if section == .bookmarks, query.isEmpty {
            BookmarkRow(
                item: item,
                onTag: { tagFilter = $0 },
                onEdit: { editing = item.id },
                onMove: { store.setKind(item.id, .readLater) },
                onDelete: { delete([.item(item.id)]) }
            )
        } else {
            SavedRow(item: item, progress: store.position(for: item.url)).equatable()
        }
    }

    // MARK: Search results

    private var searchResults: SavedMemo.Results {
        let tag = Store.tagQuery(query)
        let saved = store.items
            .filter { store.matches($0, query, hits: searchHits) }
            .sorted { $0.dateAdded > $1.dateAdded }
        let quotes = tag != nil ? [] : store.highlights
            .filter { matches($0.text, $0.pageTitle, $0.note ?? "") }
            .sorted { $0.date > $1.date }
        let taggedFeeds = tag.map { tag in Set(store.feeds.filter { $0.tags.contains(tag) }.map(\.id)) }
        let entries = store.entries
            .filter { entry in taggedFeeds.map { $0.contains(entry.feedID) } ?? matches(entry.title, entry.summary, entry.link.absoluteString) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .prefix(200)
        return SavedMemo.Results(counts: [:], active: nil, saved: saved, quotes: quotes.map(\.id), entries: entries.map(\.id))
    }

    @ViewBuilder
    private func searchList(_ results: SavedMemo.Results) -> some View {
        if results.total == 0 {
            emptyState
        } else {
            let groups: [(String, [SavedItem.RowKey])] = [
                ("Okunacaklar", results.saved.filter { $0.kind == .readLater && !$0.isRead }.map(\.rowKey)),
                ("Yer İmleri", results.saved.filter { $0.kind == .bookmark }.map(\.rowKey)),
                ("Arşiv", results.saved.filter { $0.kind == .readLater && $0.isRead }.map(\.rowKey)),
            ].filter { !$0.1.isEmpty }
            let key = ListKey(section: section, saved: groups.flatMap(\.1), entries: results.entries,
                              quotes: results.quotes, groups: groups.map(\.1.count))
            list(key: key) {
                ForEach(groups, id: \.0) { group in
                    Section {
                        ForEach(group.1, id: \.self) { key in
                            LiveItem(id: key.id, content: savedContent).tag(DetailID.item(key.id))
                        }
                    } header: {
                        sectionHeader(group.0)
                    }
                }
                if !results.quotes.isEmpty {
                    Section {
                        ForEach(results.quotes, id: \.self) { id in
                            LiveHighlight(id: id) { HighlightQuote(highlight: $0).padding(.vertical, 4) }
                                .tag(DetailID.highlight(id))
                        }
                    } header: {
                        sectionHeader("Vurgular")
                    }
                }
                if !results.entries.isEmpty {
                    Section {
                        ForEach(results.entries, id: \.self) { id in
                            LiveEntry(id: id) { entryContent($0, showFeed: true) }.tag(DetailID.entry(id))
                        }
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
        let groups = store.highlightGroups()
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
        let links = store.trash
        let quotes = store.trashedHighlights
        if links.isEmpty && quotes.isEmpty {
            emptyState
        } else {
            list {
                if !links.isEmpty {
                    Section {
                        ForEach(links) { SavedRow(item: $0).equatable().tag(DetailID.item($0.id)) }
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

    private func feedEntries(active: String?) -> [FeedEntry] {
        var feedID: UUID?
        if case .feed(let id) = section { feedID = id }
        let taggedFeeds = active.map { tag in Set(store.feeds.filter { $0.tags.contains(tag) }.map(\.id)) }
        return store.entries
            .filter { feedID == nil || $0.feedID == feedID }
            .filter { taggedFeeds == nil || taggedFeeds!.contains($0.feedID) }
            .filter { !unreadOnly || !$0.isRead || selection.contains(.entry($0.id)) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    @ViewBuilder
    private func entryList(active: String?) -> some View {
        let entries = feedEntries(active: active)
        if entries.isEmpty {
            emptyState
        } else {
            let ids = entries.map(\.id)
            let showFeed = section == .allFeeds
            list(key: ListKey(section: section, entries: ids)) {
                ForEach(ids, id: \.self) { id in
                    LiveEntry(id: id) { entryContent($0, showFeed: showFeed) }
                        .tag(DetailID.entry(id))
                }
            }
        }
    }

    private func entryContent(_ entry: FeedEntry, showFeed: Bool) -> EntryRow {
        EntryRow(entry: entry, feedTitle: showFeed ? store.feed(entry.feedID)?.title : nil,
                 queued: store.isQueued(entry.link))
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
        guard !inTrash else { return }
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

    /// The trash is on screen, rather than search results over it.
    private var inTrash: Bool { section == .trash && query.isEmpty }

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
        if inTrash {
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
        if inTrash {
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

/// Holds the last results between redraws; a class so that storing them doesn't cause another.
private final class SavedMemo {
    struct Key: Equatable {
        let version, highlights, entries: Int
        let feedTags: [[String]]
        let section: SidebarSection
        let tag: String?
        let query: String
        let hits: Set<URL>
        let sort: ItemListView.QueueSort
        let length: ItemListView.QueueLength
        let copies: Int
    }

    struct Results {
        let counts: [String: Int]
        let active: String?
        let saved: [SavedItem]
        var quotes: [UUID] = []
        var entries: [String] = []

        var total: Int { saved.count + quotes.count + entries.count }
    }

    var key: Key?
    var results: Results?
}

/// What decides a list's rows and their order.
private struct ListKey: Equatable {
    let section: SidebarSection
    var saved: [SavedItem.RowKey] = []
    var entries: [String] = []
    var quotes: [UUID] = []
    var groups: [Int] = []
}

/// The list itself, built again only when its key changes: rebuilding walks every row, however
/// long the list is, so it mustn't happen each time something in the library changes.
/// Without a key it follows every update, for lists that stay short.
private struct StableList<Rows: View, Menu: View>: View, Equatable {
    let key: ListKey?
    @Binding var selection: Set<DetailID>
    let rows: () -> Rows
    @ViewBuilder let menu: (Set<DetailID>) -> Menu
    let open: (Set<DetailID>) -> Void
    let delete: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key != nil && a.key == b.key }

    var body: some View {
        List(selection: $selection, content: rows)
            .listStyle(.plain)
            .contextMenu(forSelectionType: DetailID.self, menu: menu, primaryAction: open)
            .onDeleteCommand(perform: delete)
    }
}

/// A row that reads its link from the library itself, so only rows on screen follow changes.
private struct LiveItem<Content: View>: View {
    @EnvironmentObject private var store: Store
    let id: UUID
    @ViewBuilder let content: (SavedItem) -> Content

    // Always one view, never "maybe one": a row count that can vary makes the list walk every row.
    var body: some View {
        ZStack(alignment: .leading) {
            if let item = store.item(id) { content(item) }
        }
    }
}

private struct LiveEntry<Content: View>: View {
    @EnvironmentObject private var store: Store
    let id: String
    @ViewBuilder let content: (FeedEntry) -> Content

    var body: some View {
        ZStack(alignment: .leading) {
            if let entry = store.entry(id) { content(entry) }
        }
    }
}

private struct LiveHighlight<Content: View>: View {
    @EnvironmentObject private var store: Store
    let id: UUID
    @ViewBuilder let content: (Highlight) -> Content

    var body: some View {
        ZStack(alignment: .leading) {
            if let highlight = store.highlights.first(where: { $0.id == id }) { content(highlight) }
        }
    }
}

private extension SavedItem {
    /// Row identity that changes with the text, so the list re-measures the row when the
    /// title or description arrives after the link was added (otherwise it keeps the first height).
    /// Lengths rather than the texts: this is worked out for every row on every update.
    struct RowKey: Hashable {
        let id: UUID
        let title, excerpt: Int
        let image: Bool
    }

    var rowKey: RowKey { RowKey(id: id, title: title.utf8.count, excerpt: excerpt.utf8.count, image: imageURL != nil) }
}
