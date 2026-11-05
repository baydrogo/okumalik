import AppKit
import CryptoKit
import WebKit

/// Offline copies of articles, extracted once and opened instantly afterwards.
@MainActor
final class ArticleCache: ObservableObject {
    static let shared = ArticleCache()

    static var directory: URL = {
        let dir = Store.dataDirectory.appendingPathComponent("Articles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Pages whose article couldn't be extracted in the background (this session).
    @Published private(set) var failed: Set<URL> = []
    private var memory: [String: ArticleInfo] = [:]
    private var plainTexts: [String: String] = [:]
    private var queue: [URL] = []
    private var extractor: Extractor?

    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return Self.directory.appendingPathComponent(name + ".json")
    }

    func article(for url: URL) -> ArticleInfo? {
        if let hit = memory[url.absoluteString] { return hit }
        guard let data = try? Data(contentsOf: file(for: url)),
              let info = try? JSONDecoder().decode(ArticleInfo.self, from: data) else { return nil }
        memory[url.absoluteString] = info
        return info
    }

    func contains(_ url: URL) -> Bool {
        memory[url.absoluteString] != nil || FileManager.default.fileExists(atPath: file(for: url).path)
    }

    /// Estimated reading time, if there is a copy.
    func minutes(for url: URL) -> Int? {
        guard let words = article(for: url)?.wordCount, words > 0 else { return nil }
        return max(1, Int((Double(words) / 220).rounded()))
    }

    /// The article's text for searching (its Markdown), if there is a copy.
    func plainText(for url: URL) -> String? {
        if let hit = plainTexts[url.absoluteString] { return hit }
        guard let info = article(for: url) else { return nil }
        let text = info.markdown ?? HTMLTools.stripTags(info.content ?? "")
        plainTexts[url.absoluteString] = text
        return text
    }

    func save(_ info: ArticleInfo, for urls: [URL]) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        objectWillChange.send()
        for url in Set(urls) {
            memory[url.absoluteString] = info
            plainTexts[url.absoluteString] = nil
            failed.remove(url)
            try? data.write(to: file(for: url), options: .atomic)
        }
    }

    func remove(_ url: URL) {
        objectWillChange.send()
        memory[url.absoluteString] = nil
        plainTexts[url.absoluteString] = nil
        try? FileManager.default.removeItem(at: file(for: url))
    }

    /// Tries a failed page again.
    func retry(_ url: URL) {
        failed.remove(url)
        prefetch([url])
    }

    /// Deletes copies saved before `date`, except those for the given addresses.
    func removeCopies(olderThan date: Date, keeping keep: Set<URL>) {
        let keepFiles = Set(keep.map { file(for: $0).lastPathComponent })
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var removed = false
        for file in files where file.pathExtension == "json" && !keepFiles.contains(file.lastPathComponent) {
            let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if saved < date {
                try? fm.removeItem(at: file)
                removed = true
            }
        }
        if removed {
            objectWillChange.send()
            memory.removeAll()
            plainTexts.removeAll()
        }
    }

    /// Extracts the given pages in the background, one at a time.
    func prefetch(_ urls: [URL]) {
        for url in urls where !contains(url) && !queue.contains(url) { queue.append(url) }
        next()
    }

    private func next() {
        guard extractor == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        guard !contains(url) else { return next() }
        let extractor = Extractor()
        self.extractor = extractor
        extractor.run(url) { [weak self] info in
            guard let self else { return }
            if let info {
                self.save(info, for: [url, URL(string: info.url)].compactMap { $0 })
            } else {
                self.failed.insert(url)
            }
            self.extractor = nil
            self.next()
        }
    }
}

/// Loads a page in an invisible web view and extracts its article: first when the document
/// is parsed, again when it has fully loaded, and once more if loading drags on.
@MainActor
private final class Extractor: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private var done: ((ArticleInfo?) -> Void)?
    private var attempting = false

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
        webView.load(URLRequest(url: url, timeoutInterval: 20))
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.attempt(last: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish(nil) }
    }

    private func attempt(last: Bool = false) {
        guard done != nil, !attempting else { return }
        attempting = true
        let library = (DefuddleLibrary.source ?? "") + "\n;true"
        webView.evaluateJavaScript("typeof Defuddle === 'function'", in: nil, in: .defaultClient) { [weak self] loaded in
            guard let self else { return }
            let extract = {
                self.webView.evaluateJavaScript(ReaderScript.extract, in: nil, in: .defaultClient) { result in
                    self.attempting = false
                    let info = (try? result.get() as? String)
                        .flatMap { try? JSONDecoder().decode(ArticleInfo.self, from: Data($0.utf8)) }
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "domReady", contentWorld: .defaultClient)
        done(info)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { attempt() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { attempt(last: true) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { attempt(last: true) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
}

/// The reader layout around an extracted article.
enum ReaderPage {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    static func html(_ info: ArticleInfo, style: ReaderStyle) -> String {
        let site = info.site ?? URL(string: info.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        let title = info.title ?? ""
        var meta: [String] = []
        if let author = info.author, !author.isEmpty, author != site { meta.append(author) }
        if let published = info.published, !published.isEmpty {
            meta.append(DateParsing.parse(published).map(dateFormatter.string) ?? published)
        }
        if let words = info.wordCount, words > 0 { meta.append("\(max(1, Int((Double(words) / 220).rounded()))) dk okuma") }

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'">
        <title>\(escape(title))</title>
        <style>\(ReaderScript.css)\(style.rootCSS)</style></head>
        <body><main id="okm"><p class="okm-site">\(escape(site))</p><h1 class="okm-title">\(escape(title))</h1>\
        <p class="okm-meta">\(escape(meta.joined(separator: "  ·  ")))</p><div>\(info.content ?? "")</div></main></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
