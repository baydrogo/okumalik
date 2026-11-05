import Foundation

enum Net {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 Okumalik/1.0"
        ]
        return URLSession(configuration: config)
    }()

    /// Returns the body and the final URL after redirects.
    static func get(_ url: URL) async throws -> (Data, URL) {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError.http(http.statusCode)
        }
        return (data, response.url ?? url)
    }
}

enum PageInfo {
    struct Info {
        var title: String?
        var description: String?
        var author: String?
        var image: URL?
    }

    static func fetch(_ url: URL) async throws -> Info {
        let (data, finalURL) = try await Net.get(url)
        let html = String(HTMLTools.decode(data).prefix(300_000))
        let meta = HTMLTools.metaTags(in: html)
        let title = meta["og:title"] ?? meta["twitter:title"] ?? HTMLTools.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html)
        let description = meta["og:description"] ?? meta["description"] ?? meta["twitter:description"]
        let author = meta["author"] ?? meta["article:author"] ?? meta["twitter:creator"]
        let image = meta["og:image"] ?? meta["twitter:image"]
        return Info(
            title: title.map(HTMLTools.stripTags),
            description: description.map { HTMLTools.excerpt($0) },
            author: author.flatMap { $0.hasPrefix("http") ? nil : HTMLTools.stripTags($0) },
            image: image.flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
        )
    }
}

enum FeedFetcher {
    enum Outcome {
        case notModified
        case updated(FeedParser.Result, etag: String?, lastModified: String?)
    }

    /// Downloads a feed unless the server says it hasn't changed since the last check.
    static func fetch(_ url: URL, etag: String? = nil, lastModified: String? = nil) async throws -> Outcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await Net.session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return .notModified }
        if let code = http?.statusCode, !(200..<300).contains(code) { throw AppError.http(code) }
        guard let result = FeedParser.parse(data) else { throw AppError.noFeedFound }
        return .updated(result, etag: http?.value(forHTTPHeaderField: "ETag"),
                        lastModified: http?.value(forHTTPHeaderField: "Last-Modified"))
    }

    /// Accepts either a feed URL or a web page URL and finds the feed behind it.
    static func discover(_ url: URL) async throws -> (URL, FeedParser.Result) {
        let (data, finalURL) = try await Net.get(url)
        if let result = FeedParser.parse(data) { return (url, result) }

        let html = HTMLTools.decode(data)
        var candidates = HTMLTools.feedLinks(in: html, base: finalURL)
        if candidates.isEmpty {
            candidates = ["feed", "rss", "feed.xml", "rss.xml", "atom.xml", "index.xml", "feed.json"]
                .compactMap { URL(string: "/" + $0, relativeTo: finalURL)?.absoluteURL }
        }
        for candidate in candidates {
            if let response = try? await Net.get(candidate), let result = FeedParser.parse(response.0) {
                return (candidate, result)
            }
        }
        throw AppError.noFeedFound
    }
}

enum HTMLTools {
    static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stripTags(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func excerpt(_ s: String, limit: Int = 280) -> String {
        let plain = stripTags(s)
        guard plain.count > limit else { return plain }
        return String(plain.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = s
        if let regex = try? NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);") {
            let ns = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let hex = !ns.substring(with: match.range(at: 1)).isEmpty
                let digits = ns.substring(with: match.range(at: 2))
                guard let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) else { continue }
                result = (result as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        let named = [
            "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " ",
            "&hellip;": "…", "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘",
            "&ldquo;": "“", "&rdquo;": "”", "&laquo;": "«", "&raquo;": "»",
        ]
        for (entity, char) in named { result = result.replacingOccurrences(of: entity, with: char) }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[range])
    }

    /// Attributes of every tag matching `tag`, keys lowercased.
    static func tags(_ tag: String, in html: String) -> [[String: String]] {
        guard let tagRegex = try? NSRegularExpression(pattern: "<\(tag)\\b[^>]*>", options: [.caseInsensitive]),
              let attrRegex = try? NSRegularExpression(pattern: #"([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [] }
        let ns = html as NSString
        return tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { match in
            let tagText = ns.substring(with: match.range)
            let tns = tagText as NSString
            var attrs: [String: String] = [:]
            for a in attrRegex.matches(in: tagText, range: NSRange(location: 0, length: tns.length)) {
                let key = tns.substring(with: a.range(at: 1)).lowercased()
                let valueRange = a.range(at: 2).location != NSNotFound ? a.range(at: 2) : a.range(at: 3)
                attrs[key] = decodeEntities(tns.substring(with: valueRange))
            }
            return attrs
        }
    }

    static func metaTags(in html: String) -> [String: String] {
        var result: [String: String] = [:]
        for attrs in tags("meta", in: html) {
            guard let key = (attrs["property"] ?? attrs["name"])?.lowercased(),
                  let content = attrs["content"], !content.isEmpty, result[key] == nil else { continue }
            result[key] = content
        }
        return result
    }

    static func feedLinks(in html: String, base: URL) -> [URL] {
        tags("link", in: html).compactMap { attrs in
            guard let type = attrs["type"]?.lowercased(),
                  type.contains("rss+xml") || type.contains("atom+xml") || type.contains("feed+json"),
                  let href = attrs["href"] else { return nil }
            return URL(string: href, relativeTo: base)?.absoluteURL
        }
    }
}
