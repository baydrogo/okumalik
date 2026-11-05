import Foundation

extension Store {
    // MARK: Highlights

    func highlights(for url: URL) -> [Highlight] {
        highlights.filter { $0.url == url }.sorted { $0.date < $1.date }
    }

    func addHighlight(id: UUID, url: URL, title: String, text: String) {
        highlights.append(Highlight(id: id, url: url, pageTitle: title, text: text))
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

    // MARK: Markdown

    private static func quoted(_ h: Highlight) -> String {
        var md = "\n" + h.text.components(separatedBy: .newlines).map { "> " + $0 }.joined(separator: "\n") + "\n"
        if let note = h.note { md += "\n**Not:** \(note)\n" }
        return md
    }

    static func markdown(title: String, url: URL, highlights: [Highlight]) -> String {
        "# \(title)\n\n[\(url.host() ?? url.absoluteString)](\(url.absoluteString))\n" + highlights.map(quoted).joined()
    }

    /// Full article as Markdown with YAML properties, then the user's note and highlights.
    static func articleMarkdown(_ article: ArticleInfo, fallbackTitle: String, note: String? = nil, highlights: [Highlight]) -> String {
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
        if let note, !note.isEmpty { md += "\n## Not\n\n\(note)\n" }
        if !highlights.isEmpty { md += "\n## Vurgular\n" + highlights.map(quoted).joined() }
        return md
    }

    func markdownForAllHighlights() -> String {
        highlightGroups()
            .map { Self.markdown(title: $0.title, url: $0.url, highlights: $0.items) }
            .joined(separator: "\n---\n\n")
    }

    // MARK: Obsidian

    /// The vault folder notes are written to; chosen in Settings.
    static let obsidianFolderKey = "obsidianFolder"

    /// Writes a note into the Obsidian folder, never overwriting an existing one.
    @discardableResult
    static func writeToObsidian(_ markdown: String, title: String) throws -> URL {
        guard let path = UserDefaults.standard.string(forKey: obsidianFolderKey) else { throw AppError.noObsidianFolder }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let base = String(fileName(title).prefix(80))
        var target = folder.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        try markdown.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    nonisolated static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>#^[]")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Okumalık" : cleaned
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

    // MARK: Browser bookmarks (Netscape HTML, as Firefox, Chrome and Linkding use)

    /// Adds links from a bookmarks file; returns how many were added and how many were already saved.
    func importBookmarks(_ html: String) -> (added: Int, skipped: Int) {
        var added = 0, skipped = 0
        var known = Set(items.map { "\($0.kind.rawValue)|\($0.url.dedupeKey)" })
        var new: [SavedItem] = []
        for b in BookmarksFile.parse(html) {
            let kind: ItemKind = b.toRead ? .readLater : .bookmark
            guard known.insert("\(kind.rawValue)|\(b.url.dedupeKey)").inserted else { skipped += 1; continue }
            new.append(SavedItem(url: b.url, title: b.title.isEmpty ? (b.url.host() ?? b.url.absoluteString) : b.title,
                                 excerpt: b.description, kind: kind, tags: Self.cleanTags(b.tags), dateAdded: b.date ?? Date()))
            added += 1
        }
        items = (items + new).sorted { $0.dateAdded > $1.dateAdded }
        return (added, skipped)
    }

    func exportBookmarks() -> String { BookmarksFile.export(items) }
}

/// Reads and writes the Netscape bookmark file format.
enum BookmarksFile {
    struct Bookmark {
        var url: URL
        var title: String
        var description: String
        var tags: [String]
        var date: Date?
        var toRead: Bool
    }

    static func parse(_ html: String) -> [Bookmark] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\s([^>]*)>([\s\S]*?)</a>(?:\s*<dd>([^<]*))?"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let attrs = HTMLTools.tags("a", in: "<a " + ns.substring(with: m.range(at: 1)) + ">").first ?? [:]
            guard let href = attrs["href"], let url = URL(string: href), url.scheme?.hasPrefix("http") == true else { return nil }
            let description = m.range(at: 3).location == NSNotFound ? "" : HTMLTools.stripTags(ns.substring(with: m.range(at: 3)))
            return Bookmark(
                url: url,
                title: HTMLTools.stripTags(ns.substring(with: m.range(at: 2))),
                description: description,
                tags: (attrs["tags"] ?? "").split(separator: ",").map(String.init),
                date: attrs["add_date"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) },
                toRead: attrs["toread"] == "1"
            )
        }
    }

    static func export(_ items: [SavedItem]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let rows = items.map { item in
            var row = "<DT><A HREF=\"\(esc(item.url.absoluteString))\" ADD_DATE=\"\(Int(item.dateAdded.timeIntervalSince1970))\""
            if !item.tags.isEmpty { row += " TAGS=\"\(esc(item.tags.joined(separator: ",")))\"" }
            if item.kind == .readLater { row += " TOREAD=\"1\"" }
            row += ">\(esc(item.title))</A>"
            if !item.excerpt.isEmpty { row += "\n<DD>\(esc(item.excerpt))" }
            return row
        }
        return """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Okumalık</TITLE>
        <H1>Okumalık</H1>
        <DL><p>
        \(rows.joined(separator: "\n"))
        </DL><p>

        """
    }
}
