import SwiftUI

struct ItemListView: View {
    @EnvironmentObject private var store: Store
    let section: SidebarSection
    @Binding var selection: DetailID?
    let search: String
    @AppStorage("unreadOnly") private var unreadOnly = false
    @State private var editing: UUID?
    @State private var tagFilter: String?
    @State private var deleting: SavedItem?

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
        .confirmationDialog(
            "“\(deleting?.title ?? "")” silinsin mi?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Sil", role: .destructive) {
                guard let item = deleting else { return }
                if selection == .item(item.id) { selection = nil }
                store.deleteItem(item.id)
            }
        }
    }

    private struct EditID: Identifiable { let id: UUID }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .readLater, .archive, .bookmarks: savedList
        case .highlights: highlightList
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
        case .allFeeds: "Akışlar"
        case .feed(let id): store.feed(id)?.title ?? "Akış"
        case .tag(let tag): "#" + tag
        }
    }

    private var subtitle: String {
        switch section {
        case .readLater, .archive, .bookmarks: "\(savedItems.count) bağlantı"
        case .highlights: "\(store.highlights.count) vurgu"
        case .allFeeds: "\(store.unreadCount(feed: nil)) okunmamış"
        case .feed(let id): "\(store.unreadCount(feed: id)) okunmamış"
        case .tag(let tag):
            "\(store.items.filter { $0.tags.contains(tag) }.count) bağlantı · \(store.feeds.filter { $0.tags.contains(tag) }.count) akış"
        }
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

    // MARK: Saved items

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
        return sectionItems
            .filter { tag == nil || $0.tags.contains(tag!) }
            .filter { matches($0.title, $0.url.absoluteString, $0.excerpt, $0.tags.joined(separator: " ")) }
    }

    @ViewBuilder
    private var savedList: some View {
        let list = savedItems
        if list.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(list, id: \.rowKey, content: savedRow)
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: DetailID.self) { ids in
                if let id = ids.first { menu(for: id) }
            } primaryAction: { ids in
                ids.first.flatMap(url(for:)).map(Actions.open)
            }
            .onDeleteCommand(perform: deleteSelected)
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
                    onDelete: { deleting = item }
                )
            } else {
                SavedRow(item: item)
            }
        }
        .tag(DetailID.item(item.id))
        .draggable(TagTarget.item(item.id).dragToken)
    }

    private func deleteSelected() {
        switch selection {
        case .item(let id): store.deleteItem(id)
        case .highlight(let id): store.deleteHighlight(id)
        default: return
        }
        selection = nil
    }

    // MARK: Tag

    @ViewBuilder
    private func tagList(_ tag: String) -> some View {
        let tagged = store.items.filter { $0.tags.contains(tag) && matches($0.title, $0.url.absoluteString, $0.excerpt) }
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
            List(selection: $selection) {
                ForEach(groups, id: \.0) { group in
                    Section {
                        ForEach(group.1, id: \.rowKey, content: savedRow)
                    } header: {
                        sectionHeader(group.0)
                    }
                }
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            EntryRow(entry: entry, feedTitle: store.feed(entry.feedID)?.title, queued: store.queuedItem(for: entry.link) != nil)
                                .tag(DetailID.entry(entry.id))
                        }
                    } header: {
                        sectionHeader("Akışlar")
                    }
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: DetailID.self) { ids in
                if let id = ids.first { menu(for: id) }
            } primaryAction: { ids in
                ids.first.flatMap(url(for:)).map(Actions.open)
            }
            .onDeleteCommand(perform: deleteSelected)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: Highlights

    @ViewBuilder
    private var highlightList: some View {
        let groups = store.highlightGroups { matches($0.text, $0.pageTitle) }
        if groups.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(groups, id: \.url) { group in
                    Section {
                        ForEach(group.items) { h in
                            HighlightQuote(highlight: h)
                                .padding(.vertical, 4)
                                .tag(DetailID.highlight(h.id))
                        }
                    } header: {
                        Text(group.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: DetailID.self) { ids in
                if let id = ids.first { menu(for: id) }
            } primaryAction: { ids in
                ids.first.flatMap(url(for:)).map(Actions.open)
            }
            .onDeleteCommand(perform: deleteSelected)
        }
    }

    // MARK: Feed entries

    private var feedEntries: [FeedEntry] {
        var feedID: UUID?
        if case .feed(let id) = section { feedID = id }
        let taggedFeeds = activeTag.map { tag in Set(store.feeds.filter { $0.tags.contains(tag) }.map(\.id)) }
        return store.entries
            .filter { feedID == nil || $0.feedID == feedID }
            .filter { taggedFeeds == nil || taggedFeeds!.contains($0.feedID) }
            .filter { !unreadOnly || !$0.isRead || selection == .entry($0.id) }
            .filter { matches($0.title, $0.summary, $0.link.absoluteString) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    @ViewBuilder
    private var entryList: some View {
        let list = feedEntries
        if list.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(list) { entry in
                    EntryRow(entry: entry, feedTitle: section == .allFeeds ? store.feed(entry.feedID)?.title : nil,
                             queued: store.queuedItem(for: entry.link) != nil)
                        .tag(DetailID.entry(entry.id))
                }
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: DetailID.self) { ids in
                if let id = ids.first { menu(for: id) }
            } primaryAction: { ids in
                ids.first.flatMap(url(for:)).map(Actions.open)
            }
        }
    }

    // MARK: Menus

    private func url(for id: DetailID) -> URL? {
        switch id {
        case .item(let i): store.items.first { $0.id == i }?.url
        case .entry(let e): store.entries.first { $0.id == e }?.link
        case .highlight(let h): store.highlights.first { $0.id == h }?.url
        }
    }

    @ViewBuilder
    private func menu(for id: DetailID) -> some View {
        switch id {
        case .item(let itemID):
            if let item = store.items.first(where: { $0.id == itemID }) { savedMenu(item) }
        case .entry(let entryID):
            if let entry = store.entries.first(where: { $0.id == entryID }) { entryMenu(entry) }
        case .highlight(let highlightID):
            if let h = store.highlights.first(where: { $0.id == highlightID }) { highlightMenu(h) }
        }
    }

    @ViewBuilder
    private func savedMenu(_ item: SavedItem) -> some View {
        Button("Tarayıcıda Aç") { Actions.open(item.url) }
        Button("Bağlantıyı Kopyala") { Actions.copy(item.url) }
        Divider()
        Button("Düzenle…") { editing = item.id }
        TagMenu(target: .item(item.id))
        Divider()
        if item.kind == .readLater {
            Button(item.isRead ? "Okunacaklara Geri Al" : "Arşivle") { store.setRead(item.id, !item.isRead) }
            Button("Yer İmlerine Taşı") { store.setKind(item.id, .bookmark) }
        } else {
            Button("Okunacaklara Taşı") { store.setKind(item.id, .readLater) }
        }
        Divider()
        Button("Sil", role: .destructive) {
            if selection == .item(item.id) { selection = nil }
            store.deleteItem(item.id)
        }
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
        TagMenu(target: .feed(entry.feedID), title: "Akışın Etiketleri")
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
        Button("Vurguyu Sil", role: .destructive) {
            if selection == .highlight(h.id) { selection = nil }
            store.deleteHighlight(h.id)
        }
    }

    // MARK: Helpers

    private func matches(_ fields: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return fields.contains { $0.localizedCaseInsensitiveContains(q) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch section {
            case .readLater:
                empty("Okunacak bir şey yok", "⌘N ile bağlantı ekleyin ya da bir bağlantıyı buraya sürükleyin.")
            case .archive:
                empty("Arşiv boş", "Okuduklarınızı arşivlediğinizde burada görünür.")
            case .bookmarks:
                empty("Yer imi yok", "⌘N ile yer imi ekleyin.")
            case .highlights:
                empty("Henüz vurgu yok", "Bir yazıda metni seçip ⇧⌘H’ye basın.")
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

private func shortHost(_ url: URL) -> String {
    (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
}

struct SavedRow: View {
    let item: SavedItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                if !item.excerpt.isEmpty {
                    Text(item.excerpt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(shortHost(item.url))
                    Text("·")
                    Text(item.dateAdded, format: .relative(presentation: .named))
                    ForEach(item.tags, id: \.self) { Text("#" + $0).foregroundStyle(Color.okmAccent.opacity(0.85)) }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.kind == .bookmark {
                Button { Actions.open(item.url) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Tarayıcıda aç")
            }
        }
        .padding(.vertical, 6)
    }
}

struct EntryRow: View {
    let entry: FeedEntry
    let feedTitle: String?
    var queued = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(entry.isRead ? Color.clear : Color.okmAccent)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 14, weight: entry.isRead ? .regular : .semibold))
                    .foregroundStyle(entry.isRead ? .secondary : .primary)
                    .lineLimit(2)
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let feedTitle {
                        Text(feedTitle)
                        Text("·")
                    }
                    if let date = entry.date { Text(date, format: .relative(presentation: .named)) }
                    if queued {
                        Image(systemName: "tray.full")
                            .foregroundStyle(Color.okmAccent.opacity(0.85))
                            .help("Okunacaklarda")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}
