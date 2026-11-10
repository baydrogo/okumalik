import SwiftUI
import WebKit

/// Lets toolbar buttons and menu commands reach the web view that is on screen.
final class ReaderProxy: ObservableObject {
    weak var coordinator: WebView.Coordinator?
    func highlight() { coordinator?.highlightSelection() }
    func addNote() { coordinator?.highlightSelection(withNote: true) }
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
            extra.append(item("Not Ekle", #selector(noteFromMenu)))
            extra.append(item("Seçimi Paylaş…", #selector(shareSelectionFromMenu)))
        }
        if let id = coordinator?.menuHighlight {
            let noted = coordinator?.hasNote(id) == true
            extra.append(item(noted ? "Notu Düzenle" : "Not Ekle", #selector(editNoteFromMenu), id))
            extra.append(item("Vurguyu Paylaş…", #selector(shareHighlightFromMenu), id))
            extra.append(item("Vurguyu Kopyala", #selector(copyHighlightFromMenu), id))
            extra.append(item("Vurguyu Sil", #selector(deleteHighlightFromMenu), id))
        }
        if let image = coordinator?.menuImage, coordinator?.parent.onSaveImage != nil {
            let save = item("Görsellere Kaydet", #selector(saveImageFromMenu))
            save.representedObject = image
            extra.append(save)
        }
        guard !extra.isEmpty else { return }
        if !menu.items.isEmpty { extra.append(.separator()) }
        for (i, item) in extra.enumerated() { menu.insertItem(item, at: i) }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        coordinator?.menuHighlight = nil
        coordinator?.menuImage = nil
    }

    private func item(_ title: String, _ action: Selector, _ id: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    @objc private func saveImageFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? URL).map { coordinator?.parent.onSaveImage?($0) }
    }

    @objc private func highlightFromMenu() { coordinator?.highlightSelection() }

    @objc private func noteFromMenu() { coordinator?.highlightSelection(withNote: true) }

    @objc private func shareSelectionFromMenu() { coordinator?.shareSelection() }

    @objc private func shareHighlightFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map { coordinator?.shareHighlight($0) }
    }

    @objc private func editNoteFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? UUID).map { coordinator?.editNote($0) }
    }

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
    /// The page's title, for what gets shared from it.
    var title = ""
    let onHighlight: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    /// A note was written for a highlight; empty removes it.
    let onNote: (UUID, String) -> Void
    /// A highlight made only to carry a note, whose note was given up.
    let onDiscard: (UUID) -> Void
    var onProgress: ((Double) -> Void)? = nil
    /// Called when scrolling turns down (true) or up (false).
    var onScrollDirection: ((Bool) -> Void)? = nil
    /// "Görsellere Kaydet" on a picture in the page.
    var onSaveImage: ((URL) -> Void)? = nil

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
        private var knownNotes: [UUID: String] = [:]
        var pendingFocus: UUID?
        var lastFocus: UUID?
        /// The highlight under the pointer when the context menu was requested.
        var menuHighlight: UUID?
        /// The picture under the pointer when the context menu was requested.
        var menuImage: URL?
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
        /// The saved reading position is applied once per reader page.
        private var positionRestored = false

        init(parent: WebView) {
            self.parent = parent
            self.style = parent.style
        }

        // MARK: Reader

        /// Opens a page: from its offline copy in reader mode when there is one, otherwise live.
        func open(_ url: URL) {
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
            if readerActive, !positionRestored {
                positionRestored = true
                if pendingFocus == nil, let p = parent.position, p > 0.02 {
                    run("window.__okm.restorePosition(\(p)); true")
                }
            }
            reveal()
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

        /// Highlights the selection; with a note, opens the note editor on it right away.
        func highlightSelection(withNote: Bool = false) {
            let id = UUID()
            run("window.__okm.add('\(id.uuidString)')") { [weak self] result in
                guard let self, let text = result as? String, !text.isEmpty else {
                    NSSound.beep()
                    return
                }
                self.knownIDs.insert(id)
                self.parent.onHighlight(id, text)
                if withNote { self.openNoteEditor(id, text: "", isNew: true) }
            }
        }

        func hasNote(_ id: UUID) -> Bool { knownNotes[id] != nil }

        func editNote(_ id: UUID) {
            openNoteEditor(id, text: knownNotes[id] ?? "", isNew: false)
        }

        private func openNoteEditor(_ id: UUID, text: String, isNew: Bool) {
            guard let data = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed) else { return }
            run("window.__okm.noteEditor('\(id.uuidString)', \(String(decoding: data, as: UTF8.self)), \(isNew)); true")
        }

        /// Tells the page which highlights have notes, when that has changed.
        private func pushNotes(force: Bool = false) {
            var notes: [UUID: String] = [:]
            for h in parent.highlights { if let note = h.note { notes[h.id] = note } }
            guard force || notes != knownNotes else { return }
            knownNotes = notes
            let payload = Dictionary(uniqueKeysWithValues: notes.map { ($0.key.uuidString, $0.value) })
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            run("window.__okm.setNotes(\(String(decoding: data, as: UTF8.self))); true")
        }

        func share(_ passage: String) {
            guard !passage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Sharing.show(ShareText.passage(passage, title: parent.title, url: parent.url))
        }

        func shareSelection() {
            run("window.getSelection().toString()") { [weak self] in
                if let text = $0 as? String { self?.share(text) }
            }
        }

        func shareHighlight(_ id: UUID) {
            if let h = parent.highlights.first(where: { $0.id == id }) { share(h.text) }
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
            guard !list.isEmpty else { return pushNotes(force: true) }
            let payload = list.map { ["id": $0.id.uuidString, "text": $0.text] }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            run("window.__okm.restore(\(String(decoding: data, as: UTF8.self))); true") { [weak self] _ in
                self?.pushNotes(force: true)
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
            if added { restoreHighlights() } else { pushNotes() }
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

        // MARK: Links

        /// Links in the page open in the browser; footnotes and other anchors within the page stay here.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false,
                  let target = action.request.url else { return decisionHandler(.allow) }
            var a = URLComponents(url: target, resolvingAgainstBaseURL: false)
            var b = webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            a?.fragment = nil
            b?.fragment = nil
            if a == b { return decisionHandler(.allow) }
            decisionHandler(.cancel)
            NSWorkspace.shared.open(target)
        }

        /// Actions from the in-page selection popup and right-clicks.
        private func handlePopup(_ body: Any) {
            guard let body = body as? [String: Any], let action = body["action"] as? String else { return }
            let id = (body["id"] as? String).flatMap(UUID.init(uuidString:))
            switch action {
            case "highlight": highlightSelection(withNote: (body["note"] as? Bool) ?? false)
            case "note": if let id { parent.onNote(id, (body["text"] as? String) ?? "") }
            case "discard": id.map(parent.onDiscard)
            case "copy": (body["text"] as? String).map(Actions.copyText)
            case "share": (body["text"] as? String).map(share)
            case "shareHighlight": id.map(shareHighlight)
            case "copyHighlight": id.map(copyHighlight)
            case "delete": id.map(deleteHighlight)
            case "context":
                menuHighlight = id
                menuImage = (body["image"] as? String).flatMap(URL.init(string:))
            case "direction":
                parent.onScrollDirection?((body["down"] as? Bool) ?? false)
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
