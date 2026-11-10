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
    var note: String?
    var author: String?
    /// The page's cover picture (og:image), for the list.
    var imageURL: URL?
    /// Set while the link is in the trash.
    var deletedAt: Date?
}

struct Feed: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var siteURL: URL?
    /// Last successful check.
    var lastUpdated: Date?
    /// Labels for the subscription; its entries show up under these tags too.
    var tags: [String] = []
    /// Why the last check failed; nil once it works again.
    var lastError: String?
    /// Validators from the last response, so unchanged feeds aren't downloaded again.
    var etag: String?
    var lastModified: String?
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
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
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
    var note: String?
    /// Set while the highlight is in the trash.
    var deletedAt: Date?
}

/// A picture saved from a web page or dropped in, kept as a file under Images/.
struct SavedImage: Identifiable, Codable, Hashable {
    var id = UUID()
    /// File name inside the Images folder.
    var file: String
    /// Where the picture itself came from, when it came from the web.
    var source: URL?
    /// The page it was on.
    var page: URL?
    var pageTitle: String?
    var width: Int
    var height: Int
    var tags: [String] = []
    var note: String?
    var dateAdded = Date()

    var aspect: Double { height > 0 && width > 0 ? Double(height) / Double(width) : 1 }
}

/// An article as extracted by the reader (Defuddle), also the format of the offline copy.
struct ArticleInfo: Codable {
    var url: String
    var title: String?
    var site: String?
    var author: String?
    var published: String?
    var description: String?
    var wordCount: Int?
    /// Cover picture address.
    var image: String?
    var markdown: String?
    /// Cleaned article HTML.
    var content: String?
}

extension ArticleInfo {
    /// Decodes the JSON string the page scripts return.
    init?(json: Any?) {
        guard let text = json as? String,
              let info = try? JSONDecoder().decode(ArticleInfo.self, from: Data(text.utf8)) else { return nil }
        self = info
    }
}

enum SidebarSection: Hashable {
    case readLater, archive, bookmarks, images, highlights, trash, allFeeds
    case feed(UUID)
}

/// Something that can carry tags.
enum TagTarget: Hashable {
    case item(UUID)
    case feed(UUID)
    case image(UUID)
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
    case noObsidianFolder

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Geçerli bir adres girin."
        case .noFeedFound: "Bu adreste RSS/Atom akışı bulunamadı."
        case .duplicateFeed: "Bu akış zaten ekli."
        case .http(let code): "Sunucu hata döndürdü (\(code))."
        case .noObsidianFolder: "Önce Ayarlar'dan Obsidian klasörünü seçin."
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
