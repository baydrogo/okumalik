import SwiftUI
import WebKit

/// Lets toolbar buttons and menu commands reach the web view that is on screen.
final class ReaderProxy: ObservableObject {
    weak var coordinator: WebView.Coordinator?
    func highlight() { coordinator?.highlightSelection() }
    func scroll(to id: UUID) { coordinator?.scroll(to: id) }
    func refetch() { coordinator?.refetch() }

    func article(_ done: @escaping (ArticleInfo?) -> Void) {
        guard let coordinator else { return done(nil) }
        coordinator.article(done)
    }
}

/// The Defuddle content extractor (github.com/kepano/defuddle), shipped in the app bundle.
enum DefuddleLibrary {
    static var source: String? = Bundle.main.url(forResource: "defuddle", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
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
    let onHighlight: (UUID, String) -> Void
    let onDelete: (UUID) -> Void

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
                    let info = (result as? String).flatMap { try? JSONDecoder().decode(ArticleInfo.self, from: Data($0.utf8)) }
                    guard let info, let url = self.pageURL ?? URL(string: info.url) else { return self.pageReady() }
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
                self?.run(ReaderScript.articleExport) { result in
                    let info = (result as? String)
                        .flatMap { try? JSONDecoder().decode(ArticleInfo.self, from: Data($0.utf8)) }
                    done(info)
                }
            }
        }

        /// Runs once the page (or its reader version) is in place.
        private func pageReady() {
            applyStyle()
            restoreHighlights()
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

enum ReaderScript {
    /// Installed at document start; survives the reader rewrite because it lives on `window`.
    static let helpers = #"""
    window.__okm = {
      ensureStyle: function () {
        if (document.getElementById('okm-hl-style')) return;
        var s = document.createElement('style');
        s.id = 'okm-hl-style';
        s.textContent = 'mark.okm-hl{background:var(--okm-hl,rgba(255,210,60,.55));color:inherit;border-radius:2px;padding:1px 0;cursor:pointer}';
        (document.head || document.documentElement).appendChild(s);
      },
      setStyle: function (o) {
        var r = document.documentElement.style;
        ['bg', 'fg', 'muted', 'link', 'font', 'size', 'hl'].forEach(function (k) { r.setProperty('--okm-' + k, o[k]); });
      },
      wrap: function (range, id) {
        var root = range.commonAncestorContainer, nodes = [];
        if (root.nodeType === 3) {
          nodes.push(root);
        } else {
          var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: function (n) { return range.intersectsNode(n) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; }
          });
          while (walker.nextNode()) nodes.push(walker.currentNode);
        }
        // Work out offsets before touching the DOM; wrapping mutates the live range.
        var parts = nodes.map(function (n) {
          return { node: n,
                   start: n === range.startContainer ? range.startOffset : 0,
                   end: n === range.endContainer ? range.endOffset : n.length };
        });
        parts.forEach(function (p) {
          if (p.end <= p.start || !p.node.data.slice(p.start, p.end).trim()) return;
          var r = document.createRange();
          r.setStart(p.node, p.start);
          r.setEnd(p.node, p.end);
          var m = document.createElement('mark');
          m.className = 'okm-hl';
          m.setAttribute('data-okm', id);
          r.surroundContents(m);
        });
      },
      add: function (id) {
        var sel = window.getSelection();
        if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
        var text = sel.toString().trim();
        if (!text) return null;
        this.ensureStyle();
        this.wrap(sel.getRangeAt(0), id);
        sel.removeAllRanges();
        return text;
      },
      restore: function (list) {
        this.ensureStyle();
        var x = window.scrollX, y = window.scrollY, sel = window.getSelection(), self = this;
        list.forEach(function (h) {
          if (document.querySelector('mark[data-okm="' + h.id + '"]')) return;
          // Passages spanning paragraphs may not be found whole; fall back to the first line.
          var tries = [h.text, h.text.split('\n')[0].trim()];
          for (var i = 0; i < tries.length; i++) {
            if (!tries[i]) continue;
            sel.removeAllRanges();
            if (window.find(tries[i], false, false, true) && sel.rangeCount) {
              self.wrap(sel.getRangeAt(0), h.id);
              break;
            }
          }
        });
        sel.removeAllRanges();
        window.scrollTo(x, y);
      },
      remove: function (id) {
        document.querySelectorAll('mark[data-okm="' + id + '"]').forEach(function (m) {
          var p = m.parentNode;
          while (m.firstChild) p.insertBefore(m.firstChild, m);
          p.removeChild(m);
          p.normalize();
        });
      },
      scrollTo: function (id) {
        var m = document.querySelector('mark[data-okm="' + id + '"]');
        if (m) m.scrollIntoView({ block: 'center', behavior: 'smooth' });
      },

      // Floating toolbar over a selection or a highlight (Readwise-style).
      post: function (m) {
        try { window.webkit.messageHandlers.okm.postMessage(m); } catch (e) {}
      },
      icons: {
        highlight: '<path d="M9.5 3.5l3 3L7 12H4V9z"/><path d="M3 14.5h10"/>',
        copy: '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 3.5v-.5a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h.5"/>',
        trash: '<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.7 9h5.6l.7-9"/>'
      },
      popup: function () {
        if (this.ui && this.ui.host.isConnected) return this.ui;
        var host = document.createElement('div');
        host.style.cssText = 'all:initial;position:fixed;left:0;top:0;z-index:2147483647;display:none';
        var root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = '<style>' +
          '.bar{display:flex;align-items:stretch;padding:3px;background:#26231F;border-radius:9px;' +
          'box-shadow:0 8px 28px rgba(0,0,0,.28),0 0 0 .5px rgba(255,255,255,.1);' +
          'font:500 12.5px -apple-system,system-ui,sans-serif}' +
          'button{all:unset;display:flex;align-items:center;gap:6px;padding:5px 10px;border-radius:6px;color:#F4EFE6;white-space:nowrap}' +
          'button:hover{background:rgba(255,255,255,.13)}button.danger:hover{background:#B04833}' +
          '.sep{width:1px;margin:5px 2px;background:rgba(255,255,255,.15)}' +
          'svg{width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:1.4;stroke-linecap:round;stroke-linejoin:round}</style><div class="bar"></div>';
        // Keep the page selection when the toolbar is pressed.
        host.addEventListener('mousedown', function (e) { e.preventDefault(); e.stopPropagation(); });
        document.documentElement.appendChild(host);
        this.ui = { host: host, bar: root.querySelector('.bar') };
        return this.ui;
      },
      show: function (rect, buttons) {
        var ui = this.popup(), self = this;
        ui.bar.innerHTML = '';
        buttons.forEach(function (b, i) {
          if (i) { var s = document.createElement('span'); s.className = 'sep'; ui.bar.appendChild(s); }
          var el = document.createElement('button');
          if (b.danger) el.className = 'danger';
          el.innerHTML = '<svg viewBox="0 0 16 16">' + self.icons[b.icon] + '</svg>';
          el.appendChild(document.createTextNode(b.label));
          el.addEventListener('click', function (e) { e.stopPropagation(); self.hide(); b.run(); });
          ui.bar.appendChild(el);
        });
        var h = ui.host;
        h.style.visibility = 'hidden';
        h.style.display = 'block';
        var w = h.offsetWidth, ht = h.offsetHeight, vw = document.documentElement.clientWidth;
        var x = Math.max(8, Math.min(vw - w - 8, rect.left + rect.width / 2 - w / 2));
        var y = rect.top - ht - 10;
        if (y < 8) y = rect.bottom + 10;
        h.style.left = x + 'px';
        h.style.top = y + 'px';
        h.style.visibility = 'visible';
      },
      hide: function () {
        if (this.ui) this.ui.host.style.display = 'none';
      },
      markRect: function (id) {
        var l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
        document.querySelectorAll('mark[data-okm="' + id + '"]').forEach(function (m) {
          var c = m.getBoundingClientRect();
          l = Math.min(l, c.left); t = Math.min(t, c.top); r = Math.max(r, c.right); b = Math.max(b, c.bottom);
        });
        return { left: l, top: t, width: r - l, bottom: b };
      },
      inPopup: function (e) {
        return !!this.ui && e.composedPath().indexOf(this.ui.host) >= 0;
      },
      onMouseUp: function (e) {
        var self = this, sel = window.getSelection();
        var a = document.activeElement;
        if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.isContentEditable)) return;
        if (sel && !sel.isCollapsed && sel.rangeCount && sel.toString().trim()) {
          this.show(sel.getRangeAt(0).getBoundingClientRect(), [
            { icon: 'highlight', label: 'Vurgula', run: function () { self.post({ action: 'highlight' }); } },
            { icon: 'copy', label: 'Kopyala', run: function () { self.post({ action: 'copy', text: sel.toString() }); } }
          ]);
          return;
        }
        var t = e.target && e.target.closest ? e.target : e.target && e.target.parentElement;
        var m = t && t.closest('mark.okm-hl');
        if (!m || t.closest('a')) return;
        var id = m.getAttribute('data-okm');
        this.show(this.markRect(id), [
          { icon: 'copy', label: 'Kopyala', run: function () { self.post({ action: 'copyHighlight', id: id }); } },
          { icon: 'trash', label: 'Sil', danger: true, run: function () { self.post({ action: 'delete', id: id }); } }
        ]);
      },
      init: function () {
        var self = this;
        document.addEventListener('mousedown', function (e) { if (!self.inPopup(e)) self.hide(); }, true);
        document.addEventListener('mouseup', function (e) {
          if (e.button !== 0 || self.inPopup(e)) return;
          setTimeout(function () { self.onMouseUp(e); }, 0);
        }, true);
        document.addEventListener('contextmenu', function (e) {
          self.hide();
          var t = e.target && e.target.closest ? e.target : e.target && e.target.parentElement;
          var m = t && t.closest('mark.okm-hl');
          self.post({ action: 'context', id: m ? m.getAttribute('data-okm') : null });
        }, true);
        document.addEventListener('keydown', function () { self.hide(); }, true);
        window.addEventListener('scroll', function () { self.hide(); }, true);
        window.addEventListener('resize', function () { self.hide(); });
      }
    };
    window.__okm.init();
    """#

    static let css = #"""
    :root{--okm-bg:#F7F3EB;--okm-fg:#2B2825;--okm-muted:#8C857A;--okm-link:#9A3B26;--okm-font:ui-serif,"New York",Georgia,serif;--okm-size:19px}
    html,body{background:var(--okm-bg)}
    body{margin:0;color:var(--okm-fg);font-family:var(--okm-font);font-size:var(--okm-size);line-height:1.7;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
    #okm{max-width:36em;margin:0 auto;padding:64px 32px 140px}
    .okm-site{font:500 11px -apple-system,sans-serif;letter-spacing:.14em;text-transform:uppercase;color:var(--okm-muted);margin:0 0 16px}
    .okm-title{font-size:1.8em;line-height:1.18;font-weight:600;letter-spacing:-.01em;margin:0 0 .6em}
    .okm-meta{font:400 13px -apple-system,sans-serif;color:var(--okm-muted);margin:0 0 3em}
    .okm-meta:empty{margin-bottom:2em}
    sup a,.footnote-backref{text-decoration:none}
    .footnotes{font-size:.85em;color:var(--okm-muted)}
    h2,h3,h4{line-height:1.3;margin:1.8em 0 .6em;font-weight:600}
    p{margin:0 0 1.1em}
    img,video,svg,figure,iframe{max-width:100%;height:auto}
    img{border-radius:3px}
    figure{margin:2em 0}figcaption{font-size:.75em;color:var(--okm-muted);margin-top:.5em}
    pre{overflow:auto;font-size:.75em;background:rgba(127,127,127,.1);padding:14px 16px;border-radius:6px}
    code{font-size:.85em}
    blockquote{margin:1.4em 0;padding-left:1em;border-left:2px solid var(--okm-muted);color:var(--okm-muted);font-style:italic}
    a{color:var(--okm-link);text-decoration-thickness:1px;text-underline-offset:2px}
    hr{border:0;border-top:1px solid var(--okm-muted);opacity:.3;margin:2.5em 0}
    table{border-collapse:collapse;font-size:.8em}td,th{border:1px solid rgba(127,127,127,.3);padding:4px 8px}
    ::selection{background:rgba(176,72,51,.22)}
    """#

    /// Extracts the page's article as JSON (`ArticleInfo` with `content`), or null if there is none.
    static let extract = #"""
    (function(){
      var host = location.hostname.replace(/^www\./, '');
      var body = null, info = null;

      // 1. Defuddle.
      try {
        if (typeof Defuddle === 'function') {
          var r = new Defuddle(document, { url: location.href, separateMarkdown: true }).parse();
          var box = document.createElement('div');
          box.innerHTML = r.content || '';
          if ((box.textContent || '').trim().length > 200) {
            body = box;
            info = { url: location.href, title: r.title || document.title, site: r.site || host, author: r.author || '',
                     published: r.published || '', description: r.description || '',
                     wordCount: r.wordCount || 0, markdown: r.contentMarkdown || '' };
            box.querySelectorAll('[style]').forEach(function(e){ e.removeAttribute('style'); });
          }
        }
      } catch (e) {}

      // 2. Fallback: the element with the most paragraph text.
      if (!body) {
        var cands = document.querySelectorAll('article, main, [role=main], div, section, td');
        var best = null, bestScore = 0;
        for (var i = 0; i < cands.length; i++) {
          var el = cands[i], s = 0;
          for (var j = 0; j < el.children.length; j++) {
            var t = el.children[j].tagName;
            if (t === 'P' || t === 'PRE' || t === 'BLOCKQUOTE' || t === 'UL' || t === 'OL') s += (el.children[j].textContent || '').length;
          }
          if (el.tagName === 'ARTICLE') s *= 1.25;
          if (s > bestScore) { bestScore = s; best = el; }
        }
        if (!best || bestScore < 400) return null;
        var h = document.querySelector('h1');
        body = best.cloneNode(true);
        body.querySelectorAll('script,style,link,iframe:not([src*="youtube"]),form,nav,aside,button,input,noscript,footer,[aria-hidden=true],[role=complementary]').forEach(function(e){ e.remove(); });
        body.querySelectorAll('img').forEach(function(img){
          var src = img.getAttribute('data-src') || img.getAttribute('data-lazy-src') || img.getAttribute('data-original');
          if (src) img.setAttribute('src', src);
          img.removeAttribute('loading');
        });
        body.querySelectorAll('*').forEach(function(e){ e.removeAttribute('style'); e.removeAttribute('class'); e.removeAttribute('id'); });
        info = { url: location.href, title: (h && h.textContent.trim()) || document.title, site: host,
                 wordCount: (body.textContent || '').split(/\s+/).filter(Boolean).length };
      }

      body.querySelectorAll('script,noscript').forEach(function(e){ e.remove(); });
      body.querySelectorAll('h1').forEach(function(e){ if (e.textContent.trim() === (info.title || '').trim()) e.remove(); });
      body.querySelectorAll('img').forEach(function(img){ img.removeAttribute('width'); img.removeAttribute('height'); });
      info.content = body.innerHTML;
      return JSON.stringify(info);
    })();
    """#

    /// Returns the live page's article as JSON with Markdown.
    static let articleExport = #"""
    (function(){
      if (typeof Defuddle !== 'function') return null;
      var r = new Defuddle(document, { url: location.href, markdown: true }).parse();
      return JSON.stringify({ url: location.href, title: r.title || document.title, site: r.site || location.hostname,
                              author: r.author || '', published: r.published || '', description: r.description || '',
                              markdown: r.content || '' });
    })();
    """#
}
