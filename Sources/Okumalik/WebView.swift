import SwiftUI
import WebKit

/// Lets toolbar buttons and menu commands reach the web view that is on screen.
final class ReaderProxy: ObservableObject {
    weak var coordinator: WebView.Coordinator?
    /// True after following a link away from the article (or, outside reader mode, when there is history).
    @Published var canGoBack = false
    func goBack() { coordinator?.goBack() }
    func highlight() { coordinator?.highlightSelection() }
    func scroll(to id: UUID) { coordinator?.scroll(to: id) }
    func refetch() { coordinator?.refetch() }

    /// Finds text in the page; `done` says whether there was a match.
    func find(_ text: String, backwards: Bool = false, done: @escaping (Bool) -> Void) {
        guard let webView = coordinator?.webView, !text.isEmpty else { return done(false) }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { done($0.matchFound) }
    }

    func article(_ done: @escaping (ArticleInfo?) -> Void) {
        if let coordinator { coordinator.article(done) } else { done(nil) }
    }
}

/// Adds "Vurgula" to the right-click menu when text is selected, and "Vurguyu Sil" on a highlight.
final class ReaderWebView: WKWebView {
    weak var coordinator: WebView.Coordinator?

    /// Hides the page behind a plain sheet while it keeps rendering underneath
    /// (a hidden or transparent web view stops painting, so its stale frame would flash on reveal).
    private var sheet: NSView?

    var isCovered: Bool { sheet != nil }

    func cover(with color: NSColor) {
        if sheet == nil {
            let v = NSView(frame: bounds)
            v.wantsLayer = true
            v.autoresizingMask = [.width, .height]
            addSubview(v)
            sheet = v
        }
        sheet?.layer?.backgroundColor = color.cgColor
    }

    func uncover() {
        sheet?.removeFromSuperview()
        sheet = nil
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        var extra: [NSMenuItem] = []
        if menu.items.contains(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) {
            extra.append(item("Vurgula", #selector(highlightFromMenu)))
        }
        if let id = coordinator?.menuHighlight {
            extra.append(item("Vurguyu Kopyala", #selector(copyHighlightFromMenu), id))
            extra.append(item("Vurguyu Sil", #selector(deleteHighlightFromMenu), id))
        }
        guard !extra.isEmpty else { return }
        if !menu.items.isEmpty { extra.append(.separator()) }
        for (i, item) in extra.enumerated() { menu.insertItem(item, at: i) }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        coordinator?.menuHighlight = nil
    }

    private func item(_ title: String, _ action: Selector, _ id: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    @objc private func highlightFromMenu() { coordinator?.highlightSelection() }

    @objc private func copyHighlightFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map { coordinator?.copyHighlight($0) }
    }

    @objc private func deleteHighlightFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map { coordinator?.deleteHighlight($0) }
    }
}

/// Shows a page, optionally rewritten into a clean reader layout, with the user's highlights.
struct WebView: NSViewRepresentable {
    let url: URL
    let reader: Bool
    let style: ReaderStyle
    let highlights: [Highlight]
    var focus: UUID?
    let proxy: ReaderProxy
    /// Where reading stopped last time (0…1).
    var position: Double? = nil
    let onHighlight: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    var onProgress: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ReaderWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        // Our scripts run in their own JS world so page scripts can't interfere with them (or Defuddle).
        let world = WKContentWorld.defaultClient
        controller.addUserScript(WKUserScript(source: ReaderScript.helpers, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        controller.addUserScript(WKUserScript(
            source: "window.webkit.messageHandlers.domReady.postMessage(true);",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: world
        ))
        controller.add(context.coordinator, contentWorld: world, name: "domReady")
        controller.add(context.coordinator, contentWorld: world, name: "okm")

        let webView = ReaderWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.coordinator = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: ReaderWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        proxy.coordinator = c
        webView.underPageBackgroundColor = reader ? style.backgroundColor : nil

        if c.loadedURL != url {
            c.loadedURL = url
            c.wantsReader = reader
            c.style = style
            c.knownIDs = []
            c.pendingFocus = focus
            c.lastFocus = focus
            c.open(url)
            return
        }
        if c.style != style {
            c.style = style
            c.applyStyle()
        }
        c.setReader(reader)
        c.syncHighlights()
        if let focus, focus != c.lastFocus {
            c.lastFocus = focus
            c.scroll(to: focus)
        }
    }

    static func dismantleNSView(_ webView: ReaderWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: "domReady", contentWorld: .defaultClient)
        controller.removeScriptMessageHandler(forName: "okm", contentWorld: .defaultClient)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WebView
        weak var webView: ReaderWebView?
        var loadedURL: URL?
        var wantsReader = false
        var style: ReaderStyle
        var knownIDs = Set<UUID>()
        var pendingFocus: UUID?
        var lastFocus: UUID?
        /// The highlight under the pointer when the context menu was requested.
        var menuHighlight: UUID?
        /// The reader page on screen is built from this extracted article.
        private var article: ArticleInfo?
        private var readerNavigation: WKNavigation?
        /// The address the current page was requested with (before redirects).
        private var pageURL: URL?
        private var readerActive = false
        private var readerPending = false
        /// Between finishing an extraction and the reader page starting to load.
        private var switching = false
        private var navigationCount = 0
        /// A link inside the article was followed; "Geri" returns to the article.
        private var away = false
        private var articleScroll: Double?
        private var pendingScroll: Double?
        /// The saved reading position is applied once per reader page.
        private var positionRestored = false

        init(parent: WebView) {
            self.parent = parent
            self.style = parent.style
        }

        // MARK: Reader

        /// Opens a page: from its offline copy in reader mode when there is one, otherwise live.
        func open(_ url: URL) {
            setAway(false)
            if wantsReader, let info = ArticleCache.shared.article(for: url) {
                show(info, for: url)
            } else {
                webView?.load(URLRequest(url: url))
            }
        }

        /// Throws away the offline copy and extracts the article again from the live page.
        func refetch() {
            guard let url = pageURL ?? loadedURL else { return }
            ArticleCache.shared.remove(url)
            if let original = article.flatMap({ URL(string: $0.url) }) { ArticleCache.shared.remove(original) }
            article = nil
            webView?.load(URLRequest(url: url))
        }

        func setReader(_ on: Bool) {
            guard on != wantsReader else { return }
            wantsReader = on
            if on {
                if let url = pageURL ?? loadedURL, let info = ArticleCache.shared.article(for: url) {
                    show(info, for: url)
                } else {
                    applyReader()
                }
            } else if readerActive, let url = pageURL ?? loadedURL {
                readerActive = false
                webView?.load(URLRequest(url: url))
            }
        }

        /// Extracts the live page's article, keeps a copy and shows it as a reader page.
        private func applyReader() {
            guard !readerPending else { return }
            readerPending = true
            withDefuddle { [weak self] in
                self?.run(ReaderScript.extract) { result in
                    guard let self else { return }
                    self.readerPending = false
                    guard let info = ArticleInfo(json: result), let url = self.pageURL ?? URL(string: info.url) else { return self.pageReady() }
                    ArticleCache.shared.save(info, for: [url, URL(string: info.url)].compactMap { $0 })
                    self.show(info, for: url)
                }
            }
        }

        private func show(_ info: ArticleInfo, for url: URL) {
            article = info
            pageURL = url
            readerActive = true
            switching = true
            positionRestored = false
            readerNavigation = webView?.loadHTMLString(ReaderPage.html(info, style: style), baseURL: URL(string: info.url) ?? url)
        }

        /// Loads Defuddle into the page once, then continues.
        private func withDefuddle(_ then: @escaping () -> Void) {
            guard let library = DefuddleLibrary.source else { return then() }
            run("typeof Defuddle === 'function'") { [weak self] loaded in
                if (loaded as? Bool) == true { return then() }
                self?.run(library + "\n;true") { _ in then() }
            }
        }

        private func run(_ js: String, _ done: ((Any?) -> Void)? = nil) {
            guard let webView else { done?(nil); return }
            webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                done?(try? result.get())
            }
        }

        func applyStyle() {
            run(style.script)
        }

        /// The article's metadata and Markdown, extracted with Defuddle.
        func article(_ done: @escaping (ArticleInfo?) -> Void) {
            if let article { return done(article) }
            withDefuddle { [weak self] in
                self?.run(ReaderScript.articleExport) { done(ArticleInfo(json: $0)) }
            }
        }

        /// Runs once the page (or its reader version) is in place.
        private func pageReady() {
            applyStyle()
            restoreHighlights()
            if let y = pendingScroll {
                pendingScroll = nil
                positionRestored = true
                run("window.scrollTo(0, \(y)); true")
            }
            if readerActive, !positionRestored {
                positionRestored = true
                if pendingFocus == nil, let p = parent.position, p > 0.02 {
                    run("window.__okm.restorePosition(\(p)); true")
                }
            }
            reveal()
            updateBack()
        }

        /// Shows the view only after the page has painted its new DOM; revealing straight away
        /// flashes the last frame of the original layout.
        private func reveal() {
            guard let webView, webView.isCovered else { return }
            let painted = "await new Promise(function (done) { requestAnimationFrame(function () { requestAnimationFrame(done); }); setTimeout(done, 250); });"
            webView.callAsyncJavaScript(painted, arguments: [:], in: nil, in: .defaultClient) { [weak webView] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { webView?.uncover() }
            }
        }

        // MARK: Highlights

        func highlightSelection() {
            let id = UUID()
            run("window.__okm.add('\(id.uuidString)')") { [weak self] result in
                guard let self, let text = result as? String, !text.isEmpty else {
                    NSSound.beep()
                    return
                }
                self.knownIDs.insert(id)
                self.parent.onHighlight(id, text)
            }
        }

        func copyHighlight(_ id: UUID) {
            if let h = parent.highlights.first(where: { $0.id == id }) { Actions.copyText(h.text) }
        }

        func deleteHighlight(_ id: UUID) {
            parent.onDelete(id)
        }

        private func restoreHighlights() {
            let list = parent.highlights
            knownIDs = Set(list.map(\.id))
            guard !list.isEmpty else { return }
            let payload = list.map { ["id": $0.id.uuidString, "text": $0.text] }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            run("window.__okm.restore(\(String(decoding: data, as: UTF8.self))); true") { [weak self] _ in
                guard let self, let id = self.pendingFocus else { return }
                self.pendingFocus = nil
                self.scroll(to: id)
            }
        }

        func syncHighlights() {
            let current = Set(parent.highlights.map(\.id))
            for id in knownIDs.subtracting(current) {
                run("window.__okm.remove('\(id.uuidString)'); true")
            }
            let added = !current.subtracting(knownIDs).isEmpty
            knownIDs = current
            if added { restoreHighlights() }
        }

        func scroll(to id: UUID) {
            run("window.__okm.scrollTo('\(id.uuidString)'); true")
        }

        // MARK: Navigation

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "okm" { return handlePopup(message.body) }
            guard !switching else { return }
            if wantsReader && !readerActive { applyReader() } else { pageReady() }
        }

        // MARK: Back

        /// Returns to the article (in reader mode) or to the previous page.
        func goBack() {
            if wantsReader, away, let url = loadedURL {
                pendingScroll = articleScroll
                open(url)
            } else {
                webView?.goBack()
            }
        }

        private func setAway(_ value: Bool) {
            away = value
            updateBack()
        }

        private func updateBack() {
            let value = wantsReader ? away : (webView?.canGoBack ?? false)
            // Published from outside SwiftUI's update pass.
            DispatchQueue.main.async { [weak self] in
                guard let proxy = self?.parent.proxy, proxy.canGoBack != value else { return }
                proxy.canGoBack = value
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame == true, wantsReader else { return decisionHandler(.allow) }
            switch action.navigationType {
            case .backForward:
                // Swiping back would land on the reader page as a plain page; reopen the article instead.
                decisionHandler(.cancel)
                if away { goBack() }
            case .linkActivated:
                let target = action.request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                let current = webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                var a = target, b = current
                a?.fragment = nil
                b?.fragment = nil
                // Footnotes and other in-page anchors stay on the article.
                guard a != b else { return decisionHandler(.allow) }
                if away { return decisionHandler(.allow) }
                run("window.scrollY") { [weak self] y in
                    self?.articleScroll = y as? Double
                    self?.setAway(true)
                    decisionHandler(.allow)
                }
            default:
                decisionHandler(.allow)
            }
        }

        /// Actions from the in-page selection popup and right-clicks.
        private func handlePopup(_ body: Any) {
            guard let body = body as? [String: Any], let action = body["action"] as? String else { return }
            let id = (body["id"] as? String).flatMap(UUID.init(uuidString:))
            switch action {
            case "highlight": highlightSelection()
            case "copy": (body["text"] as? String).map(Actions.copyText)
            case "copyHighlight": id.map(copyHighlight)
            case "delete": id.map(deleteHighlight)
            case "context": menuHighlight = id
            case "progress":
                if readerActive, let value = body["value"] as? Double { parent.onProgress?(value) }
            default: break
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            if navigation === readerNavigation {
                switching = false
                readerActive = true
                return
            }
            readerActive = false
            readerPending = false
            switching = false
            article = nil
            pageURL = webView.url
            guard wantsReader else { return }
            // Cover the original layout so only the reader view shows.
            self.webView?.cover(with: style.backgroundColor)
            navigationCount += 1
            let current = navigationCount
            // Safety net; ignored if another page has started loading since.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.navigationCount == current { self?.webView?.uncover() }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Client-rendered pages may only have content after full load.
            guard !switching else { return }
            if wantsReader && !readerActive { applyReader() } else { pageReady() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.webView?.uncover()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.webView?.uncover()
        }

        // target="_blank" links open in the default browser.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
