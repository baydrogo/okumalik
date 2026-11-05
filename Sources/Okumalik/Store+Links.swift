import Foundation

/// What happened when a link was saved, for the confirmation message.
enum AddResult {
    case added
    case moved
    case alsoIn(ItemKind)

    func message(for kind: ItemKind) -> String {
        switch self {
        case .added: "\(kind.toName) eklendi"
        case .moved: "Zaten \(kind.inName); başa taşındı"
        case .alsoIn(let other): "\(kind.toName) eklendi (\(other.name) listesinde de var)"
        }
    }
}

extension ItemKind {
    var name: String { self == .bookmark ? "Yer İmleri" : "Okunacaklar" }
    /// "Okunacaklar'a" / "Yer İmleri'ne"
    var toName: String { self == .bookmark ? "Yer İmleri'ne" : "Okunacaklar'a" }
    /// "Okunacaklar'da" / "Yer İmleri'nde"
    var inName: String { self == .bookmark ? "Yer İmleri'nde" : "Okunacaklar'da" }
}

extension URL {
    /// The address without tracking parameters, fragment, "www." or trailing slash, to spot the same page saved twice.
    var dedupeKey: String {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return absoluteString }
        c.fragment = nil
        c.queryItems = c.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !["fbclid", "gclid", "mc_cid", "mc_eid"].contains(name)
        }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        var host = (c.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = c.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        return host + path + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}

extension Store {
    // MARK: Saving

    static func normalizedURL(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host(), host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    /// Lists the address is already saved in.
    func savedKinds(for url: URL) -> [ItemKind] {
        let key = url.dedupeKey
        return items.filter { $0.url.dedupeKey == key }.map(\.kind)
    }

    @discardableResult
    func addLink(_ text: String, kind: ItemKind, tags: [String] = []) throws -> AddResult {
        guard let url = Self.normalizedURL(text) else { throw AppError.invalidURL }
        return addLink(url, kind: kind, tags: tags)
    }

    /// Saves a link; the same page already in that list is moved to the top instead.
    @discardableResult
    func addLink(_ url: URL, kind: ItemKind, tags: [String] = [], title: String? = nil, excerpt: String? = nil) -> AddResult {
        let key = url.dedupeKey
        if let i = items.firstIndex(where: { $0.kind == kind && $0.url.dedupeKey == key }) {
            var existing = items.remove(at: i)
            existing.isRead = false
            existing.dateAdded = Date()
            existing.tags = Self.cleanTags(existing.tags + tags)
            items.insert(existing, at: 0)
            return .moved
        }
        let other = items.first { $0.url.dedupeKey == key }?.kind
        let item = SavedItem(url: url, title: title ?? url.host() ?? url.absoluteString, excerpt: excerpt ?? "",
                             kind: kind, tags: Self.cleanTags(tags))
        items.insert(item, at: 0)
        if kind == .readLater { ArticleCache.shared.prefetch([url]) }
        if title == nil || excerpt == nil {
            Task { await fetchInfo(for: item.id, keepTitle: title != nil) }
        }
        return other.map(AddResult.alsoIn) ?? .added
    }

    private func fetchInfo(for id: UUID, keepTitle: Bool) async {
        guard let url = items.first(where: { $0.id == id })?.url,
              let info = try? await PageInfo.fetch(url),
              let i = items.firstIndex(where: { $0.id == id }) else { return }
        if !keepTitle, let title = info.title, !title.isEmpty { items[i].title = title }
        if items[i].excerpt.isEmpty, let description = info.description { items[i].excerpt = description }
    }

    // MARK: Editing

    func setRead(_ id: UUID, _ read: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isRead = read
    }

    func setKind(_ id: UUID, _ kind: ItemKind) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].kind = kind
        items[i].isRead = false
    }

    func updateItem(_ id: UUID, title: String? = nil, excerpt: String? = nil, tags: [String]? = nil, note: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[i].title = title }
        if let excerpt { items[i].excerpt = excerpt }
        if let tags { items[i].tags = Self.cleanTags(tags) }
        if let note { items[i].note = note.isEmpty ? nil : note }
    }

    func setHighlightNote(_ id: UUID, _ note: String) {
        guard let i = highlights.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        highlights[i].note = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Trash

    /// Moves links to the trash.
    func deleteItems(_ ids: Set<UUID>) {
        let now = Date()
        let moved = items.filter { ids.contains($0.id) }
        guard !moved.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        trash.insert(contentsOf: moved.map { var item = $0; item.deletedAt = now; return item }, at: 0)
        notify(moved.count == 1 ? "Çöp kutusuna taşındı" : "\(moved.count) bağlantı çöp kutusuna taşındı")
    }

    func deleteItem(_ id: UUID) { deleteItems([id]) }

    func deleteHighlight(_ id: UUID) {
        guard let i = highlights.firstIndex(where: { $0.id == id }) else { return }
        var h = highlights.remove(at: i)
        h.deletedAt = Date()
        trashedHighlights.insert(h, at: 0)
    }

    func restoreItem(_ id: UUID) {
        guard let i = trash.firstIndex(where: { $0.id == id }) else { return }
        var item = trash.remove(at: i)
        item.deletedAt = nil
        items.insert(item, at: 0)
    }

    func restoreHighlight(_ id: UUID) {
        guard let i = trashedHighlights.firstIndex(where: { $0.id == id }) else { return }
        var h = trashedHighlights.remove(at: i)
        h.deletedAt = nil
        highlights.append(h)
    }

    func purgeItem(_ id: UUID) {
        guard let item = trash.first(where: { $0.id == id }) else { return }
        trash.removeAll { $0.id == id }
        dropCopyIfUnused(item.url)
    }

    func purgeHighlight(_ id: UUID) {
        trashedHighlights.removeAll { $0.id == id }
    }

    func emptyTrash() {
        let urls = trash.map(\.url)
        trash = []
        trashedHighlights = []
        urls.forEach(dropCopyIfUnused)
    }

    /// Removes trash older than `trashDays`.
    func purgeOldTrash(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.trashDays) * 86400)
        let old = trash.filter { ($0.deletedAt ?? now) < cutoff }
        if !old.isEmpty {
            trash.removeAll { ($0.deletedAt ?? now) < cutoff }
            old.map(\.url).forEach(dropCopyIfUnused)
        }
        if trashedHighlights.contains(where: { ($0.deletedAt ?? now) < cutoff }) {
            trashedHighlights.removeAll { ($0.deletedAt ?? now) < cutoff }
        }
    }

    /// Addresses whose offline copy must be kept.
    var addressesInUse: Set<URL> {
        Set(items.map(\.url) + trash.map(\.url) + highlights.map(\.url) + trashedHighlights.map(\.url))
    }

    private func dropCopyIfUnused(_ url: URL) {
        if !addressesInUse.contains(url) { ArticleCache.shared.remove(url) }
    }

    // MARK: Reading position

    func position(for url: URL) -> Double? { positions[url.absoluteString] }

    func setPosition(_ value: Double, for url: URL) {
        let rounded = (value * 100).rounded() / 100
        guard positions[url.absoluteString] != rounded else { return }
        positions[url.absoluteString] = rounded
    }

    // MARK: Search

    /// Everything searchable about a saved link: its texts, tags, note, highlights and offline article.
    func matches(_ item: SavedItem, _ query: String) -> Bool {
        let fields = [item.title, item.url.absoluteString, item.excerpt, item.tags.joined(separator: " "), item.note ?? ""]
        if fields.contains(where: { $0.localizedStandardContains(query) }) { return true }
        if highlights(for: item.url).contains(where: { $0.text.localizedStandardContains(query) || ($0.note ?? "").localizedStandardContains(query) }) {
            return true
        }
        return ArticleCache.shared.plainText(for: item.url)?.localizedStandardContains(query) ?? false
    }
}
