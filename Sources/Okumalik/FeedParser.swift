import Foundation

/// Minimal RSS 2.0 / RSS 1.0 (RDF) / Atom parser built on XMLParser, plus JSON Feed.
final class FeedParser: NSObject, XMLParserDelegate {
    struct Entry {
        var title = ""
        var link = ""
        var guid = ""
        var date: Date?
        var summary = ""
    }

    struct Result {
        var title: String?
        var siteLink: URL?
        var entries: [Entry]
    }

    private var root: String?
    private var current: Entry?
    private var text = ""
    private var feedTitle: String?
    private var siteLink: String?
    private var entries: [Entry] = []

    static func parse(_ data: Data) -> Result? {
        if data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) == UInt8(ascii: "{") {
            return parseJSON(data)
        }
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let ok = parser.parse()
        guard let root = delegate.root, ["rss", "feed", "rdf:rdf"].contains(root) else { return nil }
        guard ok || !delegate.entries.isEmpty else { return nil }
        return Result(
            title: delegate.feedTitle.map(HTMLTools.stripTags),
            siteLink: delegate.siteLink.flatMap { URL(string: $0) },
            entries: delegate.entries
        )
    }

    /// JSON Feed 1.x (jsonfeed.org).
    private static func parseJSON(_ data: Data) -> Result? {
        guard let feed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (feed["version"] as? String)?.contains("jsonfeed") == true,
              let items = feed["items"] as? [[String: Any]] else { return nil }
        let entries = items.compactMap { item -> Entry? in
            guard let link = (item["url"] ?? item["external_url"]) as? String else { return nil }
            let body = (item["summary"] ?? item["content_text"] ?? item["content_html"]) as? String ?? ""
            return Entry(
                title: HTMLTools.stripTags(item["title"] as? String ?? ""),
                link: link,
                guid: (item["id"] as? String) ?? "",
                date: ((item["date_published"] ?? item["date_modified"]) as? String).flatMap(DateParsing.parse),
                summary: HTMLTools.excerpt(body)
            )
        }
        return Result(
            title: (feed["title"] as? String).map(HTMLTools.stripTags),
            siteLink: (feed["home_page_url"] as? String).flatMap { URL(string: $0) },
            entries: entries
        )
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let n = name.lowercased()
        if root == nil { root = n }
        text = ""
        if n == "item" || n == "entry" { current = Entry() }
        if n == "link", let href = attributes["href"] {
            let rel = attributes["rel"] ?? "alternate"
            guard rel == "alternate" else { return }
            if current != nil {
                if current!.link.isEmpty { current!.link = href }
            } else if siteLink == nil {
                siteLink = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let n = name.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        guard current != nil else {
            if n == "title", feedTitle == nil { feedTitle = value }
            if n == "link", siteLink == nil, !value.isEmpty { siteLink = value }
            return
        }

        switch n {
        case "title":
            if current!.title.isEmpty { current!.title = HTMLTools.stripTags(value) }
        case "link":
            if current!.link.isEmpty, !value.isEmpty { current!.link = value }
        case "guid", "id":
            current!.guid = value
        case "pubdate", "published", "updated", "dc:date":
            if current!.date == nil { current!.date = DateParsing.parse(value) }
        case "description", "summary", "content:encoded", "content":
            if current!.summary.isEmpty { current!.summary = HTMLTools.excerpt(value) }
        case "item", "entry":
            // Some feeds put a permalink in <guid> but no <link>.
            if current!.link.isEmpty, current!.guid.hasPrefix("http") { current!.link = current!.guid }
            entries.append(current!)
            current = nil
        default:
            break
        }
    }
}

/// Reads feed URLs out of an OPML subscription list.
final class OPMLParser: NSObject, XMLParserDelegate {
    struct Outline { var url: URL; var title: String }
    private var outlines: [Outline] = []

    static func parse(_ data: Data) -> [Outline] {
        let delegate = OPMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.outlines
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard name.lowercased() == "outline",
              let raw = attributes["xmlUrl"] ?? attributes["xmlurl"],
              let url = URL(string: raw) else { return }
        let title = attributes["title"] ?? attributes["text"] ?? url.host() ?? raw
        outlines.append(Outline(url: url, title: title))
    }

    static func export(_ feeds: [Feed]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let body = feeds.map {
            "    <outline type=\"rss\" text=\"\(esc($0.title))\" title=\"\(esc($0.title))\" xmlUrl=\"\(esc($0.url.absoluteString))\"\(($0.siteURL).map { " htmlUrl=\"\(esc($0.absoluteString))\"" } ?? "")/>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Okumalık akışları</title></head>
          <body>
        \(body)
          </body>
        </opml>

        """
    }
}

enum DateParsing {
    private static let rfc822: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy",
    ].map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }

    private static let iso: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    static func parse(_ s: String) -> Date? {
        for f in iso { if let d = f.date(from: s) { return d } }
        for f in rfc822 { if let d = f.date(from: s) { return d } }
        return nil
    }
}
