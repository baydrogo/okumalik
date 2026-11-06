import AppKit
import Combine
import CryptoKit
import WebKit

/// What the lists show about an offline copy, kept in memory so rows never touch the disk.
struct ArticleMeta: Codable {
    var author: String?
    var image: String?
    var words: Int?

    var minutes: Int? {
        guard let words, words > 0 else { return nil }
        return max(1, Int((Double(words) / 220).rounded()))
    }
}

/// Offline copies of articles, extracted once and opened instantly afterwards.
@MainActor
final class ArticleCache: ObservableObject {
    static let shared = ArticleCache()

    nonisolated static let directory: URL = {
        let dir = Store.dataDirectory.appendingPathComponent("Articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private nonisolated static var indexFile: URL { Store.dataDirectory.appendingPathComponent("articles-index.json") }
    /// File work runs here, in order, off the main thread.
    private static let disk = DispatchQueue(label: "okumalik.articles", qos: .utility)
    private static let recentLimit = 8
    /// Pages one extractor handles before it is replaced, to give back the web view's memory.
    private static let extractorPages = 25

    /// Sends the address whose copy changed, or nil when many did. Rows listen for their own.
    let changed = PassthroughSubject<URL?, Never>()
    /// Pages whose article couldn't be extracted in the background (this session).
    @Published private(set) var failed: Set<URL> = []
    /// One entry per copy on disk, by file name; ready shortly after launch.
    private var metas: [String: ArticleMeta] = [:]
    private var ready = false
    /// The few full articles opened last.
    private var recent: [(url: String, info: ArticleInfo)] = []
    private var names: [URL: String] = [:]
    private var waiting: [URL] = []
    private var queue: [URL] = []
    private var queued = Set<URL>()
    private var extractor: Extractor?
    private var extracting = false
    private var extractorUses = 0
    private var indexSave: Task<Void, Never>?

    private init() { loadIndex() }

    private nonisolated static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func name(for url: URL) -> String {
        if let name = names[url] { return name }
        let name = Self.fileName(for: url)
        names[url] = name
        return name
    }

    private func file(for url: URL) -> URL { Self.directory.appendingPathComponent(name(for: url)) }

    // MARK: Index

    /// Reads the saved index and looks inside only the copies it doesn't know yet.
    private func loadIndex() {
        Self.disk.async {
            let saved = (try? Data(contentsOf: Self.indexFile)).flatMap { try? JSONDecoder().decode([String: ArticleMeta].self, from: $0) } ?? [:]
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? []).filter { $0.hasSuffix(".json") }
            var metas: [String: ArticleMeta] = [:]
            metas.reserveCapacity(names.count)
            for name in names {
                metas[name] = saved[name] ?? autoreleasepool {
                    let url = Self.directory.appendingPathComponent(name)
                    return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ArticleMeta.Stored.self, from: $0) }?.meta ?? ArticleMeta()
                }
            }
            if metas.count != saved.count || names.contains(where: { saved[$0] == nil }) {
                try? JSONEncoder().encode(metas).write(to: Self.indexFile, options: .atomic)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.metas.merge(metas) { current, _ in current }
                    self.ready = true
                    self.objectWillChange.send()
                    self.changed.send(nil)
                    let urls = self.waiting
                    self.waiting = []
                    self.prefetch(urls)
                }
            }
        }
    }

    private func scheduleIndexSave() {
        indexSave?.cancel()
        indexSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let metas = self?.metas else { return }
            Self.disk.async { try? JSONEncoder().encode(metas).write(to: Self.indexFile, options: .atomic) }
        }
    }

    // MARK: Reading

    /// The whole article, read from disk unless opened recently. For the page being read, not for lists.
    func article(for url: URL) -> ArticleInfo? {
        let key = url.absoluteString
        if let hit = recent.first(where: { $0.url == key }) { return hit.info }
        if ready, !contains(url) { return nil }
        guard let data = try? Data(contentsOf: file(for: url)),
              let info = try? JSONDecoder().decode(ArticleInfo.self, from: data) else { return nil }
        remember(info, for: key)
        return info
    }

    private func remember(_ info: ArticleInfo, for key: String) {
        recent.removeAll { $0.url == key }
        recent.append((key, info))
        if recent.count > Self.recentLimit { recent.removeFirst() }
    }

    func meta(for url: URL) -> ArticleMeta? { metas[name(for: url)] }

    func contains(_ url: URL) -> Bool { metas[name(for: url)] != nil }

    /// Estimated reading time, if there is a copy.
    func minutes(for url: URL) -> Int? { meta(for: url)?.minutes }

    /// The saved pages whose article text contains the query. Runs off the main thread and stops when cancelled.
    func search(_ query: String, in urls: [URL]) async -> Set<URL> {
        let candidates = urls.filter(contains)
        return await Self.scan(candidates, for: query)
    }

    private nonisolated static func scan(_ urls: [URL], for query: String) async -> Set<URL> {
        var found = Set<URL>()
        for url in Set(urls) {
            if Task.isCancelled { break }
            let hit: Bool = autoreleasepool {
                let file = directory.appendingPathComponent(fileName(for: url))
                guard let data = try? Data(contentsOf: file),
                      let text = try? JSONDecoder().decode(ArticleMeta.Text.self, from: data) else { return false }
                return (text.markdown ?? HTMLTools.stripTags(text.content ?? "")).localizedStandardContains(query)
            }
            if hit { found.insert(url) }
        }
        return found
    }

    // MARK: Changing

    func save(_ info: ArticleInfo, for urls: [URL]) {
        objectWillChange.send()
        let meta = ArticleMeta(author: info.author, image: info.image, words: info.wordCount)
        let files = Set(urls).map { file(for: $0) }
        for url in Set(urls) {
            metas[name(for: url)] = meta
            remember(info, for: url.absoluteString)
            failed.remove(url)
        }
        Self.disk.async {
            guard let data = try? JSONEncoder().encode(info) else { return }
            for file in files { try? data.write(to: file, options: .atomic) }
        }
        scheduleIndexSave()
        Set(urls).forEach { changed.send($0) }
    }

    func remove(_ url: URL) {
        objectWillChange.send()
        let key = url.absoluteString
        recent.removeAll { $0.url == key }
        metas[name(for: url)] = nil
        let file = file(for: url)
        Self.disk.async { try? FileManager.default.removeItem(at: file) }
        scheduleIndexSave()
        changed.send(url)
    }

    /// Tries a failed page again.
    func retry(_ url: URL) {
        failed.remove(url)
        changed.send(url)
        prefetch([url])
    }

    /// Deletes copies saved before `date`, except those for the given addresses.
    func removeCopies(olderThan date: Date, keeping keep: Set<URL>) {
        let keepFiles = Set(keep.map(name(for:)))
        Self.disk.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            var removed: [String] = []
            for file in files where file.pathExtension == "json" && !keepFiles.contains(file.lastPathComponent) {
                let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
                if saved < date {
                    try? fm.removeItem(at: file)
                    removed.append(file.lastPathComponent)
                }
            }
            guard !removed.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.objectWillChange.send()
                    removed.forEach { self.metas[$0] = nil }
                    self.recent.removeAll()
                    self.scheduleIndexSave()
                    self.changed.send(nil)
                }
            }
        }
    }

    // MARK: Extraction

    /// Extracts the given pages in the background, one at a time.
    func prefetch(_ urls: [URL]) {
        guard ready else {
            waiting += urls
            return
        }
        for url in urls where !contains(url) && queued.insert(url).inserted { queue.append(url) }
        next()
    }

    private func next() {
        guard !extracting else { return }
        while !queue.isEmpty {
            let url = queue.removeFirst()
            queued.remove(url)
            guard !contains(url) else { continue }
            if extractorUses >= Self.extractorPages { closeExtractor() }
            let extractor = extractor ?? Extractor()
            self.extractor = extractor
            extractorUses += 1
            extracting = true
            extractor.run(url) { [weak self] info in
                guard let self else { return }
                if let info {
                    self.save(info, for: [url, URL(string: info.url)].compactMap { $0 })
                } else {
                    self.failed.insert(url)
                    self.changed.send(url)
                }
                self.extracting = false
                self.next()
            }
            return
        }
        closeExtractor()
    }

    private func closeExtractor() {
        extractor?.close()
        extractor = nil
        extractorUses = 0
    }
}

extension ArticleMeta {
    /// The fields of a copy's file that lists need; the article text in it is skipped.
    fileprivate struct Stored: Decodable {
        var author: String?
        var image: String?
        var wordCount: Int?
        var meta: ArticleMeta { ArticleMeta(author: author, image: image, words: wordCount) }
    }

    fileprivate struct Text: Decodable {
        var markdown: String?
        var content: String?
    }
}

/// Loads pages in one invisible web view and extracts their articles: first when the document
/// is parsed, again when it has fully loaded, and once more if loading drags on.
@MainActor
private final class Extractor: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private var done: ((ArticleInfo?) -> Void)?
    private var attempting = false
    /// Counts pages, so late answers about an earlier page are ignored.
    private var run = 0
    private var navigation: WKNavigation?

    override init() {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(WKUserScript(
            source: "window.webkit.messageHandlers.domReady.postMessage(true);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        super.init()
        config.userContentController.add(self, contentWorld: .defaultClient, name: "domReady")
        webView.navigationDelegate = self
    }

    func run(_ url: URL, done: @escaping (ArticleInfo?) -> Void) {
        self.done = done
        attempting = false
        run += 1
        let current = run
        navigation = webView.load(URLRequest(url: url, timeoutInterval: 20))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.run == current { self?.attempt(last: true) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.run == current { self?.finish(nil) }
        }
    }

    /// Releases the web view; needed because the script handler keeps this object alive.
    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "domReady", contentWorld: .defaultClient)
    }

    private func attempt(last: Bool = false) {
        guard done != nil, !attempting else { return }
        attempting = true
        let current = run
        let library = (DefuddleLibrary.source ?? "") + "\n;true"
        webView.evaluateJavaScript("typeof Defuddle === 'function'", in: nil, in: .defaultClient) { [weak self] loaded in
            guard let self, self.run == current else { return }
            let extract = {
                self.webView.evaluateJavaScript(ReaderScript.extract, in: nil, in: .defaultClient) { result in
                    guard self.run == current else { return }
                    self.attempting = false
                    let info = ArticleInfo(json: try? result.get())
                    if info != nil || last { self.finish(info) }
                }
            }
            if (try? loaded.get() as? Bool) == true { extract() } else {
                self.webView.evaluateJavaScript(library, in: nil, in: .defaultClient) { _ in extract() }
            }
        }
    }

    private func finish(_ info: ArticleInfo?) {
        guard let done else { return }
        self.done = nil
        webView.stopLoading()
        done(info)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { attempt() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === self.navigation { attempt(last: true) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { attempt(last: true) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if navigation === self.navigation { finish(nil) }
    }
}
