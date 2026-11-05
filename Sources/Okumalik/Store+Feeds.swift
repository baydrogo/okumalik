import Foundation

extension Store {
    private static let maxEntriesPerFeed = 200

    // MARK: Subscriptions

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

    // MARK: Refreshing

    func refreshAll() async {
        guard !isRefreshing, !feeds.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = feeds
        await withTaskGroup(of: (UUID, Result<FeedFetcher.Outcome, Error>).self) { group in
            for feed in snapshot {
                group.addTask {
                    do {
                        return (feed.id, .success(try await FeedFetcher.fetch(feed.url, etag: feed.etag, lastModified: feed.lastModified)))
                    } catch {
                        return (feed.id, .failure(error))
                    }
                }
            }
            for await (id, outcome) in group {
                guard let i = feeds.firstIndex(where: { $0.id == id }) else { continue }
                switch outcome {
                case .success(.notModified):
                    feeds[i].lastUpdated = Date()
                    feeds[i].lastError = nil
                case .success(.updated(let result, let etag, let lastModified)):
                    feeds[i].lastUpdated = Date()
                    feeds[i].lastError = nil
                    feeds[i].etag = etag
                    feeds[i].lastModified = lastModified
                    merge(result.entries, into: feeds[i])
                case .failure(let error):
                    feeds[i].lastError = error.localizedDescription
                }
            }
        }
        cleanUp()
    }

    func startAutoRefresh() {
        Task { [weak self] in
            while let self {
                await self.refreshAll()
                let minutes = UserDefaults.standard.integer(forKey: "refreshMinutes")
                try? await Task.sleep(for: .seconds(max(minutes == 0 ? 30 : minutes, 5) * 60))
            }
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

    // MARK: Read state

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
        let key = url.dedupeKey
        return items.first { $0.kind == .readLater && !$0.isRead && $0.url.dedupeKey == key }
    }

    /// Adds a feed entry to the reading list, or takes it off again if it is already there.
    func toggleQueued(_ entry: FeedEntry) {
        if let item = queuedItem(for: entry.link) { deleteItem(item.id) } else { save(entry, as: .readLater) }
    }

    func save(_ entry: FeedEntry, as kind: ItemKind) {
        addLink(entry.link, kind: kind, tags: feed(entry.feedID)?.tags ?? [], title: entry.title, excerpt: entry.summary)
    }

    // MARK: Clean-up

    /// Days after which read feed entries are removed (0: never). Shared with Settings.
    static let readRetentionKey = "readRetentionDays"
    /// Days after which offline copies not tied to saved links or highlights are removed (0: never).
    static let copyRetentionKey = "copyRetentionDays"

    private static func days(_ key: String) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? 30
    }

    /// Removes long-read feed entries, stale offline copies and old trash.
    func cleanUp(now: Date = Date()) {
        let readDays = Self.days(Self.readRetentionKey)
        if readDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(readDays) * 86400)
            let old = Set(entries.filter { $0.isRead && ($0.readDate ?? $0.date ?? .distantPast) < cutoff }.map(\.id))
            if !old.isEmpty {
                removedEntryIDs.formUnion(old)
                entries.removeAll { old.contains($0.id) }
            }
        }
        let copyDays = Self.days(Self.copyRetentionKey)
        if copyDays > 0 {
            ArticleCache.shared.removeCopies(olderThan: now.addingTimeInterval(-Double(copyDays) * 86400), keeping: addressesInUse)
        }
        purgeOldTrash(now: now)
        // Reading positions only for what is still around.
        let live = Set(addressesInUse.map(\.absoluteString) + entries.map(\.link.absoluteString))
        if positions.keys.contains(where: { !live.contains($0) }) {
            positions = positions.filter { live.contains($0.key) }
        }
    }
}
