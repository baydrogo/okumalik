import AppKit

/// Small site icons for the bookmark list, fetched once from each site itself and kept on disk.
@MainActor
final class SiteIcons: ObservableObject {
    static let shared = SiteIcons()

    static var directory: URL = {
        let dir = Store.dataDirectory.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Bumped when an icon arrives so rows redraw.
    @Published private(set) var version = 0
    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var loading: Set<String> = []

    static func key(for url: URL) -> String? {
        url.host()?.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    private func file(_ key: String, _ ext: String) -> URL {
        Self.directory.appendingPathComponent(key + "." + ext)
    }

    /// The icon if known; otherwise starts fetching it and returns nil.
    func icon(for page: URL) -> NSImage? {
        guard let key = Self.key(for: page) else { return nil }
        if let image = memory[key] { return image }
        if missing.contains(key) { return nil }
        if let image = NSImage(contentsOf: file(key, "png")) {
            memory[key] = image
            return image
        }
        if FileManager.default.fileExists(atPath: file(key, "none").path) {
            missing.insert(key)
            return nil
        }
        fetch(key, page)
        return nil
    }

    private func fetch(_ key: String, _ page: URL) {
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task {
            let image = await Self.download(page)
            loading.remove(key)
            if let image, let png = Self.png(image) {
                try? png.write(to: file(key, "png"), options: .atomic)
                memory[key] = image
            } else {
                // Remember the miss so the site isn't asked again on every launch.
                FileManager.default.createFile(atPath: file(key, "none").path, contents: nil)
                missing.insert(key)
            }
            version += 1
        }
    }

    /// Icons declared in the page's <link> tags first, then /favicon.ico.
    private static func download(_ page: URL) async -> NSImage? {
        var candidates: [URL] = []
        if let response = try? await Net.get(page) {
            let (data, finalURL) = response
            let html = HTMLTools.decode(data)
            let links = HTMLTools.tags("link", in: html).filter { ($0["rel"] ?? "").lowercased().contains("icon") }
            // Prefer apple-touch-icon (large, square), then the rest in page order.
            let sorted = links.sorted { ($0["rel"] ?? "").contains("apple") && !($1["rel"] ?? "").contains("apple") }
            candidates += sorted.compactMap { $0["href"].flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL } }
        }
        var root = URLComponents()
        root.scheme = page.scheme
        root.host = page.host()
        root.path = "/favicon.ico"
        if let url = root.url { candidates.append(url) }

        for url in candidates {
            if let data = try? await Net.get(url).0, let image = NSImage(data: data), image.isValid, image.size.width > 0 {
                return image
            }
        }
        return nil
    }

    private static func png(_ image: NSImage) -> Data? {
        let size = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // Fit without stretching; wide logos get transparent bands.
        let side = CGFloat(size)
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let w = image.size.width * scale, h = image.size.height * scale
        image.draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
