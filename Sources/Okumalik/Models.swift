import Foundation

enum ItemKind: String, Codable {
    case readLater
    case bookmark
}

/// A link saved by the user: either something to read later or a bookmark.
struct SavedItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var excerpt: String = ""
    var kind: ItemKind
    var isRead = false
    var tags: [String] = []
    var dateAdded = Date()
}

struct Feed: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var siteURL: URL?
    var lastUpdated: Date?
    /// Labels for the subscription; its entries show up under these tags too.
    var tags: [String] = []
}

extension Feed {
    // Tolerates files written before feeds had tags.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        siteURL = try c.decodeIfPresent(URL.self, forKey: .siteURL)
        lastUpdated = try c.decodeIfPresent(Date.self, forKey: .lastUpdated)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

struct FeedEntry: Identifiable, Codable, Hashable {
    var id: String
    var feedID: UUID
    var title: String
    var link: URL
    var date: Date?
    var summary: String
    var isRead = false
    /// When it was marked read; read entries are cleared out some days later.
    var readDate: Date?
}

/// A passage the user marked on a page.
struct Highlight: Identifiable, Codable, Hashable {
    var id: UUID
    var url: URL
    var pageTitle: String
    var text: String
    var date = Date()
}

/// Article text and metadata extracted by Defuddle.
/// An article as extracted by the reader (Defuddle), also the format of the offline copy.
struct ArticleInfo: Codable {
    var url: String
    var title: String?
    var site: String?
    var author: String?
    var published: String?
    var description: String?
    var wordCount: Int?
    var markdown: String?
    /// Cleaned article HTML.
    var content: String?
}

enum SidebarSection: Hashable {
    case readLater, archive, bookmarks, highlights, allFeeds
    case feed(UUID)
    case tag(String)
}

/// Something that can carry tags; also the payload of in-app drags ("okumalik-item:<id>").
enum TagTarget: Hashable {
    case item(UUID)
    case feed(UUID)

    var dragToken: String {
        switch self {
        case .item(let id): "okumalik-item:\(id.uuidString)"
        case .feed(let id): "okumalik-feed:\(id.uuidString)"
        }
    }

    init?(dragToken: String) {
        let parts = dragToken.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "okumalik-item": self = .item(id)
        case "okumalik-feed": self = .feed(id)
        default: return nil
        }
    }
}

enum DetailID: Hashable {
    case item(UUID)
    case entry(String)
    case highlight(UUID)
}

enum AddKind: String, CaseIterable, Identifiable {
    case readLater = "Sonra Oku"
    case bookmark = "Yer İmi"
    case feed = "RSS Akışı"
    var id: Self { self }
}

enum AppError: LocalizedError {
    case invalidURL
    case noFeedFound
    case duplicateFeed
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Geçerli bir adres girin."
        case .noFeedFound: "Bu adreste RSS/Atom akışı bulunamadı."
        case .duplicateFeed: "Bu akış zaten ekli."
        case .http(let code): "Sunucu hata döndürdü (\(code))."
        }
    }
}

extension JSONEncoder {
    static let app: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let app: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
