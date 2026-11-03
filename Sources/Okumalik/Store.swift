import AppKit
import Foundation

@MainActor
final class Store: ObservableObject {
    @Published var items: [SavedItem] = [] { didSet { scheduleSave() } }
    @Published var feeds: [Feed] = [] { didSet { scheduleSave() } }
    @Published var entries: [FeedEntry] = [] { didSet { scheduleSave() } }
    @Published var highlights: [Highlight] = [] { didSet { scheduleSave() } }
    @Published var isRefreshing = false
    @Published var showAddSheet = false
    /// Asks the window for a new tag name to add to this target.
    @Published var tagPrompt: TagTarget?

    private static let maxEntriesPerFeed = 200
    /// Entries cleared out after being read; skipped while the site still lists them.
    private var removedEntryIDs = Set<String>()
    private var loaded = false
    private var saveTask: Task<Void, Never>?

    static let dataDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Okumalik", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var dataURL: URL { dataDirectory.appendingPathComponent("library.json") }

    private struct Snapshot: Codable {
        var items: [SavedItem]
        var feeds: [Feed]
        var entries: [FeedEntry]
        var highlights: [Highlight]
        var removedEntries: [String]

        init(items: [SavedItem], feeds: [Feed], entries: [FeedEntry], highlights: [Highlight], removedEntries: [String]) {
            self.items = items
            self.feeds = feeds
            self.entries = entries
            self.highlights = highlights
            self.removedEntries = removedEntries
        }

        // Tolerates files written by older versions that lack newer keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decodeIfPresent([SavedItem].self, forKey: .items) ?? []
            feeds = try c.decodeIfPresent([Feed].self, forKey: .feeds) ?? []
            entries = try c.decodeIfPresent([FeedEntry].self, forKey: .entries) ?? []
            highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
            removedEntries = try c.decodeIfPresent([String].self, forKey: .removedEntries) ?? []
        }
    }

    init() {
        load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        startAutoRefresh()
        // Offline copies for the reading list, made in the background after launch.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            ArticleCache.shared.prefetch(self.items.filter { $0.kind == .readLater && !$0.isRead }.map(\.url))
            self.cleanUp()
        }
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: Self.dataURL),
           let snapshot = try? JSONDecoder.app.decode(Snapshot.self, from: data) {
            items = snapshot.items
            feeds = snapshot.feeds
            entries = snapshot.entries
            highlights = snapshot.highlights
            removedEntryIDs = Set(snapshot.removedEntries)
        }
        loaded = true
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let snapshot = Snapshot(items: items, feeds: feeds, entries: entries, highlights: highlights,
                                removedEntries: removedEntryIDs.sorted())
        guard let data = try? JSONEncoder.app.encode(snapshot) else { return }
        try? data.write(to: Self.dataURL, options: .atomic)
    }

    // MARK: Counts

    var unreadLaterCount: Int { items.filter { $0.kind == .readLater && !$0.isRead }.count }

    func unreadCount(feed: UUID?) -> Int {
        entries.filter { !$0.isRead && (feed == nil || $0.feedID == feed) }.count
    }

    func feed(_ id: UUID) -> Feed? { feeds.first { $0.id == id } }

    // MARK: Saved links

    static func normalizedURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    func addLink(_ text: String, kind: ItemKind, tags: [String] = []) throws {
        guard let url = Self.normalizedURL(text) else { throw AppError.invalidURL }
        addLink(url, kind: kind, tags: tags)
    }

    func addLink(_ url: URL, kind: ItemKind, tags: [String] = [], title: String? = nil, excerpt: String? = nil) {
        if let i = items.firstIndex(where: { $0.url == url && $0.kind == kind }) {
            var existing = items.remove(at: i)
            existing.isRead = false
            existing.dateAdded = Date()
            existing.tags = Self.cleanTags(existing.tags + tags)
            items.insert(existing, at: 0)
            return
        }
        let item = SavedItem(
            url: url,
            title: title ?? url.host() ?? url.absoluteString,
            excerpt: excerpt ?? "",
            kind: kind,
            tags: Self.cleanTags(tags)
        )
        items.insert(item, at: 0)
        if kind == .readLater { ArticleCache.shared.prefetch([url]) }
        if title == nil || excerpt == nil {
            Task { await fetchInfo(for: item.id, keepTitle: title != nil) }
        }
    }

    private func fetchInfo(for id: UUID, keepTitle: Bool) async {
        guard let url = items.first(where: { $0.id == id })?.url,
              let info = try? await PageInfo.fetch(url),
              let i = items.firstIndex(where: { $0.id == id }) else { return }
        if !keepTitle, let title = info.title, !title.isEmpty { items[i].title = title }
        if items[i].excerpt.isEmpty, let description = info.description { items[i].excerpt = description }
    }

    func setRead(_ id: UUID, _ read: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isRead = read
    }

    func setKind(_ id: UUID, _ kind: ItemKind) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].kind = kind
        items[i].isRead = false
    }

    func updateItem(_ id: UUID, title: String? = nil, excerpt: String? = nil, tags: [String]? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[i].title = title }
        if let excerpt { items[i].excerpt = excerpt }
        if let tags { items[i].tags = Self.cleanTags(tags) }
    }

    func deleteItem(_ id: UUID) {
        guard let url = items.first(where: { $0.id == id })?.url else { return }
        items.removeAll { $0.id == id }
        if !items.contains(where: { $0.url == url }) && highlights(for: url).isEmpty {
            ArticleCache.shared.remove(url)
        }
    }

    static func parseTags(_ text: String) -> [String] {
        cleanTags(text.split(separator: ",").map(String.init))
    }

    static func normalizedTag(_ text: String) -> String? {
        let tag = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))
            .lowercased(with: Locale(identifier: "tr_TR"))
        return tag.isEmpty ? nil : tag
    }

    static func cleanTags(_ tags: [String]) -> [String] {
        Array(Set(tags.compactMap(normalizedTag))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Tags

    var allTags: [String] { Self.cleanTags(items.flatMap(\.tags) + feeds.flatMap(\.tags)) }

    func tags(of target: TagTarget) -> [String] {
        switch target {
        case .item(let id): items.first { $0.id == id }?.tags ?? []
        case .feed(let id): feeds.first { $0.id == id }?.tags ?? []
        }
    }

    func setTags(_ tags: [String], on target: TagTarget) {
        switch target {
        case .item(let id): updateItem(id, tags: tags)
        case .feed(let id):
            guard let i = feeds.firstIndex(where: { $0.id == id }) else { return }
            feeds[i].tags = Self.cleanTags(tags)
        }
    }

    func addTag(_ tag: String, to target: TagTarget) {
        setTags(tags(of: target) + [tag], on: target)
    }

    func toggleTag(_ tag: String, on target: TagTarget) {
        let current = tags(of: target)
        setTags(current.contains(tag) ? current.filter { $0 != tag } : current + [tag], on: target)
    }

    /// Saved links plus subscriptions carrying the tag.
    func tagCount(_ tag: String) -> Int {
        items.filter { $0.tags.contains(tag) }.count + feeds.filter { $0.tags.contains(tag) }.count
    }

    func renameTag(_ old: String, to new: String) {
        guard let new = Self.normalizedTag(new), new != old else { return }
        for i in items.indices where items[i].tags.contains(old) {
            items[i].tags = Self.cleanTags(items[i].tags.filter { $0 != old } + [new])
        }
        for i in feeds.indices where feeds[i].tags.contains(old) {
            feeds[i].tags = Self.cleanTags(feeds[i].tags.filter { $0 != old } + [new])
        }
    }

    func deleteTag(_ tag: String) {
        for i in items.indices where items[i].tags.contains(tag) { items[i].tags.removeAll { $0 == tag } }
        for i in feeds.indices where feeds[i].tags.contains(tag) { feeds[i].tags.removeAll { $0 == tag } }
    }

    // MARK: Feeds

    func addFeed(_ text: String, tags: [String] = []) async throws {
        guard let url = Self.normalizedURL(text) else { throw AppError.invalidURL }
        let (feedURL, result) = try await FeedFetcher.discover(url)
        guard !feeds.contains(where: { $0.url == feedURL }) else { throw AppError.duplicateFeed }
        let feed = Feed(
            url: feedURL,
            title: result.title.flatMap { $0.isEmpty ? nil : $0 } ?? feedURL.host() ?? "Akış",
            siteURL: result.siteLink,
            lastUpdated: Date(),
            tags: Self.cleanTags(tags)
        )
        feeds.append(feed)
        merge(result.entries, into: feed)
    }

    func removeFeed(_ id: UUID) {
        feeds.removeAll { $0.id == id }
        entries.removeAll { $0.feedID == id }
        removedEntryIDs = removedEntryIDs.filter { !$0.hasPrefix(id.uuidString + "|") }
    }

    func renameFeed(_ id: UUID, to title: String) {
        guard let i = feeds.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        feeds[i].title = title
    }

    func refreshAll() async {
        guard !isRefreshing, !feeds.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = feeds
        await withTaskGroup(of: (UUID, FeedParser.Result?).self) { group in
            for feed in snapshot {
                let url = feed.url
                group.addTask { (feed.id, try? await FeedFetcher.fetch(url)) }
            }
            for await (id, result) in group {
                guard let result, let i = feeds.firstIndex(where: { $0.id == id }) else { continue }
                feeds[i].lastUpdated = Date()
                merge(result.entries, into: feeds[i])
            }
        }
        cleanUp()
    }

    // MARK: Clean-up

    /// Days after which read feed entries are removed (0: never). Shared with Settings.
    static let readRetentionKey = "readRetentionDays"
    /// Days after which offline copies not tied to saved links or highlights are removed (0: never).
    static let copyRetentionKey = "copyRetentionDays"

    private static func days(_ key: String) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? 30
    }

    /// Removes long-read feed entries and stale offline copies, as set in Settings.
    func cleanUp(now: Date = Date()) {
        let readDays = Self.days(Self.readRetentionKey)
        if readDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(readDays) * 86400)
            let old = entries.filter { $0.isRead && ($0.readDate ?? $0.date ?? .distantPast) < cutoff }
            if !old.isEmpty {
                let ids = Set(old.map(\.id))
                removedEntryIDs.formUnion(ids)
                entries.removeAll { ids.contains($0.id) }
            }
        }
        let copyDays = Self.days(Self.copyRetentionKey)
        if copyDays > 0 {
            let keep = Set(items.map(\.url) + highlights.map(\.url))
            ArticleCache.shared.removeCopies(olderThan: now.addingTimeInterval(-Double(copyDays) * 86400), keeping: keep)
        }
    }

    private func merge(_ parsed: [FeedParser.Entry], into feed: Feed) {
        let base = feed.siteURL ?? feed.url
        let old = Dictionary(entries.filter { $0.feedID == feed.id }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var merged: [FeedEntry] = []
        let now = Date()
        for p in parsed {
            guard let link = URL(string: p.link.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL else { continue }
            let id = feed.id.uuidString + "|" + (p.guid.isEmpty ? link.absoluteString : p.guid)
            guard seen.insert(id).inserted, !removedEntryIDs.contains(id) else { continue }
            let previous = old[id]
            merged.append(FeedEntry(
                id: id,
                feedID: feed.id,
                title: p.title.isEmpty ? (link.host() ?? "Başlıksız") : p.title,
                link: link,
                date: p.date ?? previous?.date ?? now,
                summary: p.summary,
                isRead: previous?.isRead ?? false,
                readDate: previous?.readDate
            ))
        }
        // Keep entries that have dropped out of the feed so history isn't lost.
        merged += old.values.filter { !seen.contains($0.id) }
        merged.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        entries = entries.filter { $0.feedID != feed.id } + merged.prefix(Self.maxEntriesPerFeed)
        // Forget removed entries once the site no longer lists them.
        let prefix = feed.id.uuidString + "|"
        removedEntryIDs = removedEntryIDs.filter { !$0.hasPrefix(prefix) || seen.contains($0) }
    }

    func setEntryRead(_ id: String, _ read: Bool) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].isRead != read else { return }
        entries[i].isRead = read
        entries[i].readDate = read ? Date() : nil
    }

    func markAllRead(feed: UUID?) {
        let now = Date()
        for i in entries.indices where !entries[i].isRead && (feed == nil || entries[i].feedID == feed) {
            entries[i].isRead = true
            entries[i].readDate = now
        }
    }

    /// The unread reading-list item for this address, if it is queued.
    func queuedItem(for url: URL) -> SavedItem? {
        items.first { $0.kind == .readLater && !$0.isRead && $0.url == url }
    }

    /// Adds a feed entry to the reading list, or takes it off again if it is already there.
    func toggleQueued(_ entry: FeedEntry) {
        if let item = queuedItem(for: entry.link) { deleteItem(item.id) } else { save(entry, as: .readLater) }
    }

    func save(_ entry: FeedEntry, as kind: ItemKind) {
        addLink(entry.link, kind: kind, tags: feed(entry.feedID)?.tags ?? [], title: entry.title, excerpt: entry.summary)
    }

    private func startAutoRefresh() {
        Task { [weak self] in
            while let self {
                await self.refreshAll()
                let minutes = UserDefaults.standard.integer(forKey: "refreshMinutes")
                try? await Task.sleep(for: .seconds(max(minutes == 0 ? 30 : minutes, 5) * 60))
            }
        }
    }

    // MARK: Highlights

    func highlights(for url: URL) -> [Highlight] {
        highlights.filter { $0.url == url }.sorted { $0.date < $1.date }
    }

    func addHighlight(id: UUID, url: URL, title: String, text: String) {
        highlights.append(Highlight(id: id, url: url, pageTitle: title, text: text))
    }

    func deleteHighlight(_ id: UUID) {
        highlights.removeAll { $0.id == id }
    }

    /// Highlights grouped by page, most recently highlighted page first.
    func highlightGroups(matching filter: (Highlight) -> Bool = { _ in true }) -> [(url: URL, title: String, items: [Highlight])] {
        Dictionary(grouping: highlights.filter(filter), by: \.url)
            .map { url, list in
                let sorted = list.sorted { $0.date < $1.date }
                return (url, sorted.last?.pageTitle ?? url.absoluteString, sorted)
            }
            .sorted { ($0.items.last?.date ?? .distantPast) > ($1.items.last?.date ?? .distantPast) }
    }

    static func markdown(title: String, url: URL, highlights: [Highlight]) -> String {
        var md = "# \(title)\n\n[\(url.host() ?? url.absoluteString)](\(url.absoluteString))\n"
        for h in highlights {
            md += "\n" + h.text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n"
        }
        return md
    }

    /// Full article as Markdown with YAML properties and the page's highlights at the end.
    static func articleMarkdown(_ article: ArticleInfo, fallbackTitle: String, highlights: [Highlight]) -> String {
        func yaml(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
        let title = article.title.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        var props = ["title: \(yaml(title))", "source: \(yaml(article.url))"]
        if let author = article.author, !author.isEmpty { props.append("author: \(yaml(author))") }
        if let published = article.published, !published.isEmpty { props.append("published: \(yaml(published))") }
        if let site = article.site, !site.isEmpty { props.append("site: \(yaml(site))") }
        if let description = article.description, !description.isEmpty { props.append("description: \(yaml(description))") }
        props.append("created: \(Date().formatted(.iso8601.year().month().day()))")

        var md = "---\n" + props.joined(separator: "\n") + "\n---\n\n# \(title)\n\n"
        md += (article.markdown ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if !highlights.isEmpty {
            md += "\n## Vurgular\n"
            for h in highlights {
                md += "\n" + h.text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n"
            }
        }
        return md
    }

    func markdownForAllHighlights() -> String {
        highlightGroups()
            .map { Self.markdown(title: $0.title, url: $0.url, highlights: $0.items) }
            .joined(separator: "\n---\n\n")
    }

    // MARK: OPML

    func importOPML(_ data: Data) async -> Int {
        var added = 0
        for outline in OPMLParser.parse(data) where !feeds.contains(where: { $0.url == outline.url }) {
            feeds.append(Feed(url: outline.url, title: outline.title))
            added += 1
        }
        await refreshAll()
        return added
    }

    func exportOPML() -> String { OPMLParser.export(feeds) }

    // MARK: URL scheme

    /// okumalik://add?url=…&title=…  ·  okumalik://bookmark?url=…  ·  okumalik://feed?url=…
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "okumalik",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let raw = query["url"], let target = Self.normalizedURL(raw) else { return }
        let title = query["title"].flatMap { $0.isEmpty ? nil : $0 }
        let tags = Self.parseTags(query["tags"] ?? "")
        switch url.host() {
        case "feed":
            Task { try? await addFeed(raw, tags: tags) }
        case "bookmark":
            addLink(target, kind: .bookmark, tags: tags, title: title)
        default:
            addLink(target, kind: .readLater, tags: tags, title: title)
        }
    }
}
