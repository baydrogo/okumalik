import AppKit

/// What a shared passage or a page's highlights look like as a message.
enum ShareText {
    /// Letters and digits stay readable; everything else, also what the link format itself uses (- , &), is escaped.
    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")

    static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: plain) ?? ""
    }

    /// The address without tracking parameters or its own anchor.
    static func cleanAddress(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        c.queryItems = c.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !["fbclid", "gclid", "mc_cid", "mc_eid"].contains(name)
        }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.string ?? url.absoluteString
    }

    /// A link that opens the page at this passage and marks it, in browsers that support text fragments.
    /// Long passages or ones spanning paragraphs are given by their first and last words.
    static func link(to url: URL, passage: String) -> String {
        let address = cleanAddress(url)
        let words = passage.split(whereSeparator: \.isWhitespace).map(String.init)
        guard url.scheme?.hasPrefix("http") == true, !words.isEmpty else { return address }
        let spansLines = passage.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline)
        if words.count > 12 || (spansLines && words.count > 1) {
            let edge = min(6, words.count / 2)
            let start = words.prefix(edge).joined(separator: " ")
            let end = words.suffix(edge).joined(separator: " ")
            return address + "#:~:text=" + escape(start) + "," + escape(end)
        }
        return address + "#:~:text=" + escape(words.joined(separator: " "))
    }

    /// “Passage”, then the page's title and a link to the spot.
    static func passage(_ text: String, title: String, url: URL) -> String {
        let quote = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "“\(quote)”\n\n\(title)\n\(link(to: url, passage: quote))"
    }

    /// The page's title and link, then its highlights. Notes stay out: they may be personal.
    static func highlights(_ list: [Highlight], title: String, url: URL) -> String {
        let quotes = list.map { "• “\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))”" }
        return "\(title)\n\(cleanAddress(url))\n\n" + quotes.joined(separator: "\n\n")
    }
}

/// The share menu at the pointer: what macOS offers, plus copying and WhatsApp, which isn't always among them.
@MainActor
final class Sharing: NSObject, NSSharingServicePickerDelegate {
    private static var current: Sharing?
    private let text: String

    private init(text: String) { self.text = text }

    /// Comes from a click, so the pointer is where the menu belongs. Without a window the text is copied.
    static func show(_ text: String) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return Actions.copyText(text) }
        let sharing = Sharing(text: text)
        current = sharing
        let picker = NSSharingServicePicker(items: [text])
        picker.delegate = sharing
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        picker.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// The WhatsApp app when it is installed, otherwise WhatsApp's page in the browser.
    static func whatsAppURL(_ text: String) -> URL? {
        let hasApp = URL(string: "whatsapp://send").flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) != nil
        return URL(string: (hasApp ? "whatsapp://send?text=" : "https://wa.me/?text=") + ShareText.escape(text))
    }

    static func services(for text: String, proposed: [NSSharingService]) -> [NSSharingService] {
        var list = [NSSharingService(title: "Kopyala", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage(),
                                     alternateImage: nil) { Actions.copyText(text) }]
        if !proposed.contains(where: { $0.title.localizedCaseInsensitiveContains("WhatsApp") }) {
            list.append(NSSharingService(title: "WhatsApp", image: NSImage(systemSymbolName: "message", accessibilityDescription: nil) ?? NSImage(),
                                         alternateImage: nil) {
                if let url = whatsAppURL(text) { NSWorkspace.shared.open(url) }
            })
        }
        return list + proposed
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] {
        Self.services(for: text, proposed: proposed)
    }
}
