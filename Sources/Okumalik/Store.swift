import AppKit
import Foundation

/// The whole library, kept in memory and saved as one JSON file.
@MainActor
final class Store: ObservableObject {
    @Published var items: [SavedItem] = [] {
        didSet {
            itemIndex = nil
            queuedKeys = nil
            itemsVersion &+= 1
            scheduleSave()
        }
    }
    @Published var feeds: [Feed] = [] { didSet { scheduleSave() } }
    @Published var entries: [FeedEntry] = [] {
        didSet {
            entryIndex = nil
            scheduleSave()
        }
    }
    @Published var highlights: [Highlight] = [] { didSet { scheduleSave() } }
    /// Saved pictures, newest first.
    @Published var images: [SavedImage] = [] { didSet { scheduleSave() } }
    /// Deleted links and highlights, kept for `trashDays` days.
    @Published var trash: [SavedItem] = [] { didSet { scheduleSave() } }
    @Published var trashedHighlights: [Highlight] = [] { didSet { scheduleSave() } }
    @Published var isRefreshing = false
    @Published var showAddSheet = false
    /// Asks the window for a new tag name to add to these targets.
    @Published var tagPrompt: [TagTarget] = []
    /// A short message shown at the bottom of the window, optionally with "Geri Al".
    @Published private(set) var toast: Toast?
    /// The window's undo manager, so deletions can be undone with ⌘Z.
    weak var undoManager: UndoManager?

    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        let undo: (() -> Void)?
    }

    /// Where reading stopped in each article (0…1), by address. Not published: it changes while scrolling.
    var positions: [String: Double] = [:] { didSet { scheduleSave() } }
    /// Feed entries cleared out after being read; skipped while the site still lists them.
    var removedEntryIDs = Set<String>()

    static let trashDays = 30
    private var loaded = false
    /// Changes with every change to `items`, so lists can tell whether their results still hold.
    private(set) var itemsVersion = 0
    // Worked out when first asked after a change, so each visible row finds its data at once.
    private var itemIndex: [UUID: Int]?
    private var entryIndex: [String: Int]?
    private var queuedKeys: Set<String>?
    private var dedupeKeys: [URL: String] = [:]
    private var saveTask: Task<Void, Never>?
    /// Library writes run here, in order, so a large library never holds up the window.
    private static let saveQueue = DispatchQueue(label: "okumalik.save", qos: .utility)
    private var toastTask: Task<Void, Never>?

    /// ~/Library/Application Support/Okumalik, or OKUMALIK_DATA_DIR when set (for tests).
    nonisolated static let dataDirectory: URL = {
        let dir = ProcessInfo.processInfo.environment["OKUMALIK_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Okumalik", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Files that can be made again (small pictures); macOS may clear these.
    nonisolated static let cacheDirectory: URL = {
        let dir = ProcessInfo.processInfo.environment["OKUMALIK_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Okumalik", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var dataURL: URL { dataDirectory.appendingPathComponent("library.json") }
    static var backupDirectory: URL { dataDirectory.appendingPathComponent("Backups", isDirectory: true) }

    struct Snapshot: Codable {
        var items: [SavedItem] = []
        var feeds: [Feed] = []
        var entries: [FeedEntry] = []
        var highlights: [Highlight] = []
        var images: [SavedImage] = []
        var trash: [SavedItem] = []
        var trashedHighlights: [Highlight] = []
        var positions: [String: Double] = [:]
        var removedEntries: [String] = []

        init() {}

        // Tolerates files written by older versions that lack newer keys.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decodeIfPresent([SavedItem].self, forKey: .items) ?? []
            feeds = try c.decodeIfPresent([Feed].self, forKey: .feeds) ?? []
            entries = try c.decodeIfPresent([FeedEntry].self, forKey: .entries) ?? []
            highlights = try c.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
            images = try c.decodeIfPresent([SavedImage].self, forKey: .images) ?? []
            trash = try c.decodeIfPresent([SavedItem].self, forKey: .trash) ?? []
            trashedHighlights = try c.decodeIfPresent([Highlight].self, forKey: .trashedHighlights) ?? []
            positions = try c.decodeIfPresent([String: Double].self, forKey: .positions) ?? [:]
            removedEntries = try c.decodeIfPresent([String].self, forKey: .removedEntries) ?? []
        }
    }

    init() {
        if let data = try? Data(contentsOf: Self.dataURL),
           let snapshot = try? JSONDecoder.app.decode(Snapshot.self, from: data) {
            apply(snapshot)
        }
        loaded = true
        backUpDaily()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        startAutoRefresh()
        // Offline copies for the reading list and housekeeping, shortly after launch.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            ArticleCache.shared.prefetch(self.items.filter { $0.kind == .readLater && !$0.isRead }.map(\.url))
            self.cleanUp()
            // Only at launch: during a session, deleted pictures can still be brought back.
            self.sweepImageFiles()
            await self.backfillPageInfo()
        }
    }

    // MARK: Persistence

    private var snapshot: Snapshot {
        var s = Snapshot()
        s.items = items
        s.feeds = feeds
        s.entries = entries
        s.highlights = highlights
        s.images = images
        s.trash = trash
        s.trashedHighlights = trashedHighlights
        s.positions = positions
        s.removedEntries = removedEntryIDs.sorted()
        return s
    }

    private func apply(_ s: Snapshot) {
        items = s.items
        feeds = s.feeds
        entries = s.entries
        highlights = s.highlights
        images = s.images
        trash = s.trash
        trashedHighlights = s.trashedHighlights
        positions = s.positions
        removedEntryIDs = Set(s.removedEntries)
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let snapshot = self.snapshot
            let url = Self.dataURL
            Self.saveQueue.async { Self.write(snapshot, to: url) }
        }
    }

    /// Writes now and waits; earlier writes still in the queue finish first.
    func saveNow() {
        saveTask?.cancel()
        let snapshot = self.snapshot
        let url = Self.dataURL
        Self.saveQueue.sync { Self.write(snapshot, to: url) }
    }

    private nonisolated static func write(_ snapshot: Snapshot, to url: URL) {
        guard let data = try? JSONEncoder.app.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Backups

    /// Keeps a copy of the library file per day, the last ten days.
    private func backUpDaily() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.backupDirectory, withIntermediateDirectories: true)
        let name = "library-\(Date().formatted(.iso8601.year().month().day())).json"
        let target = Self.backupDirectory.appendingPathComponent(name)
        if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: Self.dataURL.path) {
            try? fm.copyItem(at: Self.dataURL, to: target)
        }
        let backups = ((try? fm.contentsOfDirectory(atPath: Self.backupDirectory.path)) ?? [])
            .filter { $0.hasPrefix("library-") }
            .sorted()
        for old in backups.dropLast(10) {
            try? fm.removeItem(at: Self.backupDirectory.appendingPathComponent(old))
        }
    }

    func exportLibrary(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }

    /// Reads a library file without applying it, to show what it holds first.
    static func readLibrary(at url: URL) throws -> Snapshot {
        try JSONDecoder.app.decode(Snapshot.self, from: Data(contentsOf: url))
    }

    /// Replaces the library with a backup; the current state is backed up first.
    func restoreLibrary(_ backup: Snapshot) {
        saveNow()
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.copyItem(
            at: Self.dataURL,
            to: Self.backupDirectory.appendingPathComponent("before-restore-\(stamp).json")
        )
        apply(backup)
        saveNow()
        notify("Yedek geri yüklendi")
    }

    // MARK: Messages

    func notify(_ text: String, undo: (() -> Void)? = nil) {
        toast = Toast(text: text, undo: undo)
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 3 : 6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// Records an undoable change for ⌘Z and offers "Geri Al" in the message.
    func undoable(_ message: String, name: String, undo: @escaping (Store) -> Void) {
        undoManager?.registerUndo(withTarget: self) { store in
            undo(store)
            store.dismissToast()
        }
        undoManager?.setActionName(name)
        // The button restores directly; a later ⌘Z for the same change finds nothing left to restore.
        notify(message) { [weak self] in
            guard let self else { return }
            undo(self)
            self.dismissToast()
        }
    }

    // MARK: Counts

    var unreadLaterCount: Int { items.reduce(0) { $0 + ($1.kind == .readLater && !$1.isRead ? 1 : 0) } }

    /// Unread entries per feed, worked out in one pass for lists that show them all.
    var unreadByFeed: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for entry in entries where !entry.isRead { counts[entry.feedID, default: 0] += 1 }
        return counts
    }

    func unreadCount(feed: UUID?) -> Int {
        entries.filter { !$0.isRead && (feed == nil || $0.feedID == feed) }.count
    }

    func feed(_ id: UUID) -> Feed? { feeds.first { $0.id == id } }

    func item(_ id: UUID) -> SavedItem? {
        if itemIndex == nil { itemIndex = Dictionary(items.indices.map { (items[$0].id, $0) }, uniquingKeysWith: { a, _ in a }) }
        return itemIndex?[id].map { items[$0] }
    }

    func entry(_ id: String) -> FeedEntry? {
        if entryIndex == nil { entryIndex = Dictionary(entries.indices.map { (entries[$0].id, $0) }, uniquingKeysWith: { a, _ in a }) }
        return entryIndex?[id].map { entries[$0] }
    }

    /// Whether this address is on the reading list, unread.
    func isQueued(_ url: URL) -> Bool {
        if queuedKeys == nil {
            queuedKeys = Set(items.filter { $0.kind == .readLater && !$0.isRead }.map { cachedDedupeKey($0.url) })
        }
        return queuedKeys?.contains(cachedDedupeKey(url)) ?? false
    }

    private func cachedDedupeKey(_ url: URL) -> String {
        if let key = dedupeKeys[url] { return key }
        let key = url.dedupeKey
        dedupeKeys[url] = key
        return key
    }

    // MARK: URL scheme

    /// okumalik://add?url=…&title=…&tags=a,b  ·  okumalik://bookmark?url=…  ·  okumalik://feed?url=…  ·  okumalik://image?src=…&page=…
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "okumalik",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if url.host() == "image" {
            // okumalik://image?src=…&page=…&title=…&tags=a,b
            guard let src = query["src"].flatMap(URL.init(string:)) else { return }
            let page = query["page"].flatMap(URL.init(string:))
            let title = query["title"].flatMap { $0.isEmpty ? nil : $0 }
            saveImage(from: src, page: page, title: title, tags: Self.parseTags(query["tags"] ?? ""))
            return
        }
        guard let raw = query["url"], let target = Self.normalizedURL(raw) else { return }
        let title = query["title"].flatMap { $0.isEmpty ? nil : $0 }
        let tags = Self.parseTags(query["tags"] ?? "")
        switch url.host() {
        case "feed":
            Task {
                do {
                    try await addFeed(raw, tags: tags)
                    notify("Akışa abone olundu")
                } catch {
                    notify(error.localizedDescription)
                }
            }
        case "bookmark":
            notify(addLink(target, kind: .bookmark, tags: tags, title: title).message(for: .bookmark))
        default:
            notify(addLink(target, kind: .readLater, tags: tags, title: title).message(for: .readLater))
        }
    }
}
