import Foundation

/// The Defuddle content extractor (github.com/kepano/defuddle), shipped in the app bundle.
enum DefuddleLibrary {
    static var source: String? = Bundle.main.url(forResource: "defuddle", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
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

/// Scripts and styles injected into pages; they run in their own content world.
enum ReaderScript {
    /// Installed at document start; survives the reader rewrite because it lives on `window`.
    static let helpers = #"""
    window.__okm = {
      ensureStyle: function () {
        if (document.getElementById('okm-hl-style')) return;
        var s = document.createElement('style');
        s.id = 'okm-hl-style';
        s.textContent = 'mark.okm-hl{background:var(--okm-hl,rgba(255,210,60,.55));color:inherit;border-radius:2px;padding:1px 0;cursor:pointer}' +
          'mark.okm-noted{border-bottom:1.5px dotted currentColor}';
        (document.head || document.documentElement).appendChild(s);
      },
      setStyle: function (o) {
        var r = document.documentElement.style;
        Object.keys(o).forEach(function (k) { r.setProperty('--okm-' + k, o[k]); });
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

      // Marks the highlights that have a note, and keeps the notes for the popup.
      notes: {},
      setNotes: function (notes) {
        this.notes = notes;
        document.querySelectorAll('mark.okm-hl').forEach(function (m) {
          m.classList.toggle('okm-noted', !!notes[m.getAttribute('data-okm')]);
        });
      },

      // Floating toolbar over a selection or a highlight (Readwise-style).
      post: function (m) {
        try { window.webkit.messageHandlers.okm.postMessage(m); } catch (e) {}
      },
      icons: {
        highlight: '<path d="M9.5 3.5l3 3L7 12H4V9z"/><path d="M3 14.5h10"/>',
        copy: '<rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 3.5v-.5a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h.5"/>',
        note: '<path d="M2.5 3.5h11v7.5H7l-3 2.5V11H2.5z"/>',
        share: '<path d="M8 10V2M5 4.8L8 2l3 2.8"/><path d="M4.5 7H3v7h10V7h-1.5"/>',
        trash: '<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.7 9h5.6l.7-9"/>'
      },
      popup: function () {
        if (this.ui && this.ui.host.isConnected) return this.ui;
        var host = document.createElement('div');
        host.style.cssText = 'all:initial;position:fixed;left:0;top:0;z-index:2147483647;display:none';
        var root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = '<style>' +
          '.box{background:#26231F;border-radius:9px;width:max-content;' +
          'box-shadow:0 8px 28px rgba(0,0,0,.28),0 0 0 .5px rgba(255,255,255,.1);' +
          'font:500 12.5px -apple-system,system-ui,sans-serif}' +
          '.bar{display:flex;align-items:stretch;padding:3px}' +
          '.text{max-width:340px;padding:9px 12px 5px;color:#F4EFE6;font-weight:400;line-height:1.45;white-space:pre-wrap;max-height:130px;overflow:auto}' +
          '.editor{padding:4px;width:310px}' +
          'textarea{all:unset;display:block;box-sizing:border-box;width:100%;height:84px;padding:8px;color:#F4EFE6;font-weight:400;line-height:1.45;white-space:pre-wrap;overflow:auto}' +
          'textarea::placeholder{color:rgba(244,239,230,.45)}' +
          '.actions{display:flex;justify-content:flex-end;gap:2px}' +
          'button{all:unset;display:flex;align-items:center;gap:6px;padding:5px 10px;border-radius:6px;color:#F4EFE6;white-space:nowrap}' +
          'button:hover{background:rgba(255,255,255,.13)}button.danger:hover{background:#D64545}' +
          '.sep{width:1px;margin:5px 2px;background:rgba(255,255,255,.15)}' +
          'svg{width:14px;height:14px;fill:none;stroke:currentColor;stroke-width:1.4;stroke-linecap:round;stroke-linejoin:round}</style>' +
          '<div class="box"><div class="text"></div><div class="bar"></div><div class="editor">' +
          '<textarea placeholder="Notunuzu yazın"></textarea><div class="actions">' +
          '<button class="cancel">Vazgeç</button><button class="save">Kaydet</button></div></div></div>';
        var self = this;
        // Keep the page selection when the toolbar is pressed; the note field needs the press itself.
        host.addEventListener('mousedown', function (e) { if (!self.editing) e.preventDefault(); e.stopPropagation(); });
        document.documentElement.appendChild(host);
        this.ui = { host: host, bar: root.querySelector('.bar'), text: root.querySelector('.text'),
                    editor: root.querySelector('.editor'), area: root.querySelector('textarea') };
        root.querySelector('.save').addEventListener('click', function (e) { e.stopPropagation(); self.commitNote(); });
        root.querySelector('.cancel').addEventListener('click', function (e) { e.stopPropagation(); self.cancelNote(); });
        this.ui.area.addEventListener('keydown', function (e) {
          if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); self.cancelNote(); }
          if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); e.stopPropagation(); self.commitNote(); }
        });
        return this.ui;
      },
      show: function (rect, buttons, note) {
        var ui = this.popup(), self = this;
        ui.bar.innerHTML = '';
        ui.bar.style.display = 'flex';
        ui.editor.style.display = 'none';
        ui.text.style.display = note ? 'block' : 'none';
        ui.text.textContent = note || '';
        buttons.forEach(function (b, i) {
          if (i) { var s = document.createElement('span'); s.className = 'sep'; ui.bar.appendChild(s); }
          var el = document.createElement('button');
          if (b.danger) el.className = 'danger';
          el.innerHTML = '<svg viewBox="0 0 16 16">' + self.icons[b.icon] + '</svg>';
          el.appendChild(document.createTextNode(b.label));
          el.addEventListener('click', function (e) { e.stopPropagation(); self.hide(); b.run(); });
          ui.bar.appendChild(el);
        });
        this.place(rect);
      },
      place: function (rect) {
        var h = this.ui.host;
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
        if (this.ui && !this.editing) this.ui.host.style.display = 'none';
      },
      // The note editor stays open while scrolling and keeps what was typed when clicking elsewhere.
      editing: null,
      noteEditor: function (id, text, isNew) {
        var ui = this.popup();
        this.editing = { id: id, original: text || '', isNew: !!isNew };
        ui.bar.style.display = 'none';
        ui.text.style.display = 'none';
        ui.editor.style.display = 'block';
        ui.area.value = text || '';
        this.place(this.markRect(id));
        ui.area.focus();
        ui.area.setSelectionRange(ui.area.value.length, ui.area.value.length);
      },
      closeNote: function () {
        var e = this.editing;
        this.editing = null;
        this.ui.area.blur();
        this.hide();
        return e;
      },
      commitNote: function () {
        if (!this.editing) return;
        var text = this.ui.area.value.trim(), e = this.closeNote();
        if (e.isNew && !text) this.post({ action: 'discard', id: e.id });
        else if (text !== e.original) this.post({ action: 'note', id: e.id, text: text });
      },
      cancelNote: function () {
        if (!this.editing) return;
        var e = this.closeNote();
        if (e.isNew) this.post({ action: 'discard', id: e.id });
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
        if (this.editing) return;
        var self = this, sel = window.getSelection();
        var a = document.activeElement;
        if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.isContentEditable)) return;
        if (sel && !sel.isCollapsed && sel.rangeCount && sel.toString().trim()) {
          this.show(sel.getRangeAt(0).getBoundingClientRect(), [
            { icon: 'highlight', label: 'Vurgula', run: function () { self.post({ action: 'highlight' }); } },
            { icon: 'note', label: 'Not Ekle', run: function () { self.post({ action: 'highlight', note: true }); } },
            { icon: 'share', label: 'Paylaş', run: function () { self.post({ action: 'share', text: sel.toString() }); } },
            { icon: 'copy', label: 'Kopyala', run: function () { self.post({ action: 'copy', text: sel.toString() }); } }
          ]);
          return;
        }
        var t = e.target && e.target.closest ? e.target : e.target && e.target.parentElement;
        var m = t && t.closest('mark.okm-hl');
        if (!m || t.closest('a')) return;
        var id = m.getAttribute('data-okm'), note = this.notes[id];
        this.show(this.markRect(id), [
          { icon: 'note', label: note ? 'Notu Düzenle' : 'Not Ekle', run: function () { self.noteEditor(id, note, false); } },
          { icon: 'share', label: 'Paylaş', run: function () { self.post({ action: 'shareHighlight', id: id }); } },
          { icon: 'copy', label: 'Kopyala', run: function () { self.post({ action: 'copyHighlight', id: id }); } },
          { icon: 'trash', label: 'Sil', danger: true, run: function () { self.post({ action: 'delete', id: id }); } }
        ], note);
      },
      // Pictures in the reader open enlarged over the article instead of replacing it.
      imageLink: /\.(jpe?g|png|gif|webp|avif|svg)(\?|#|$)/i,
      lightbox: function (src, fallback) {
        this.hide();
        var host = document.createElement('div');
        host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647';
        var root = host.attachShadow({ mode: 'closed' });
        root.innerHTML = '<style>' +
          '.bg{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;' +
          'background:rgba(18,16,14,.86);cursor:zoom-out}' +
          'img{max-width:92vw;max-height:92vh;object-fit:contain;border-radius:4px;box-shadow:0 12px 48px rgba(0,0,0,.45)}' +
          '</style><div class="bg"><img alt=""></div>';
        var img = root.querySelector('img');
        img.onerror = function () { if (fallback && img.src !== fallback) img.src = fallback; };
        img.src = src;
        var onKey = function (e) {
          if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
        };
        var close = function () { host.remove(); document.removeEventListener('keydown', onKey, true); };
        host.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); close(); });
        host.addEventListener('wheel', function (e) { e.preventDefault(); }, { passive: false });
        document.addEventListener('keydown', onKey, true);
        document.documentElement.appendChild(host);
      },
      onClick: function (e) {
        if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || this.inPopup(e)) return;
        var t = e.target && e.target.closest ? e.target : null;
        if (!t || !t.closest('#okm')) return;
        var sel = window.getSelection();
        if (sel && !sel.isCollapsed) return;
        var img = t.closest('img'), a = t.closest('a');
        var linked = a && this.imageLink.test(a.getAttribute('href') || '') ? a.href : null;
        if (!img && !linked) return;
        e.preventDefault();
        e.stopPropagation();
        var shown = img ? (img.currentSrc || img.src) : null;
        this.lightbox(linked || shown, shown);
      },
      restorePosition: function (p) {
        var go = function () {
          var h = document.documentElement.scrollHeight - window.innerHeight;
          if (h > 0) window.scrollTo(0, p * h);
        };
        if (document.readyState === 'complete') go(); else window.addEventListener('load', go, { once: true });
      },
      init: function () {
        var self = this;
        document.addEventListener('click', function (e) { self.onClick(e); }, true);
        document.addEventListener('mousedown', function (e) {
          if (self.inPopup(e)) return;
          self.commitNote();
          self.hide();
        }, true);
        document.addEventListener('mouseup', function (e) {
          if (e.button !== 0 || self.inPopup(e)) return;
          setTimeout(function () { self.onMouseUp(e); }, 0);
        }, true);
        document.addEventListener('contextmenu', function (e) {
          self.hide();
          var t = e.target && e.target.closest ? e.target : e.target && e.target.parentElement;
          var m = t && t.closest('mark.okm-hl');
          var img = t && t.closest('img, picture');
          if (img && img.tagName === 'PICTURE') img = img.querySelector('img');
          self.post({ action: 'context', id: m ? m.getAttribute('data-okm') : null,
                      image: img ? (img.currentSrc || img.src || null) : null });
        }, true);
        document.addEventListener('keydown', function () { self.hide(); }, true);
        window.addEventListener('scroll', function () { self.hide(); }, true);
        window.addEventListener('resize', function () { self.hide(); });
        // Scroll direction, for hiding the floating tool bar while reading on.
        var lastY = window.scrollY, lastDown = false;
        window.addEventListener('scroll', function () {
          var y = window.scrollY, dy = y - lastY;
          if (Math.abs(dy) < 4) return;
          lastY = y;
          var down = dy > 0 && y > 80;
          if (down !== lastDown) { lastDown = down; self.post({ action: 'direction', down: down }); }
        }, { passive: true });
        // Reading progress in the reader page, reported once scrolling settles.
        var settle = null;
        window.addEventListener('scroll', function () {
          if (!document.getElementById('okm')) return;
          clearTimeout(settle);
          settle = setTimeout(function () {
            var h = document.documentElement.scrollHeight - window.innerHeight;
            if (h > 0) self.post({ action: 'progress', value: Math.min(1, Math.max(0, window.scrollY / h)) });
          }, 600);
        }, { passive: true });
      }
    };
    window.__okm.init();
    """#

    static let css = #"""
    :root{--okm-bg:#F7F3EB;--okm-fg:#2B2825;--okm-muted:#8C857A;--okm-link:#2F5FAF;--okm-font:ui-serif,"New York",Georgia,serif;--okm-size:19px}
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
    #okm img{cursor:zoom-in}
    figure{margin:2em 0}figcaption{font-size:.75em;color:var(--okm-muted);margin-top:.5em}
    pre{overflow:auto;font-size:.75em;background:rgba(127,127,127,.1);padding:14px 16px;border-radius:6px}
    code{font-size:.85em}
    blockquote{margin:1.4em 0;padding-left:1em;border-left:2px solid var(--okm-muted);color:var(--okm-muted);font-style:italic}
    a{color:var(--okm-link);text-decoration-thickness:1px;text-underline-offset:2px}
    hr{border:0;border-top:1px solid var(--okm-muted);opacity:.3;margin:2.5em 0}
    table{border-collapse:collapse;font-size:.8em}td,th{border:1px solid rgba(127,127,127,.3);padding:4px 8px}
    ::selection{background:transparent}
    :is(p,li,dt,dd,h1,h2,h3,h4,h5,h6,blockquote,figcaption,pre,td,th)::selection,
    :is(p,li,dt,dd,h1,h2,h3,h4,h5,h6,blockquote,figcaption,pre,td,th) *::selection{background:var(--okm-sel,rgba(0,122,255,.2))}
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
                     wordCount: r.wordCount || 0, image: r.image || '', markdown: r.contentMarkdown || '' };
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
