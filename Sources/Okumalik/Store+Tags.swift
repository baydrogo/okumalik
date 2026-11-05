import Foundation

extension Store {
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
}
