import AppKit

/// Limits how many pictures are fetched at once; a row scrolled away gives up its turn.
@MainActor
final class LoadSlots {
    private let limit: Int
    private var active = 0

    init(limit: Int) { self.limit = limit }

    func acquire() async -> Bool {
        while active >= limit {
            try? await Task.sleep(for: .milliseconds(60))
            if Task.isCancelled { return false }
        }
        active += 1
        return true
    }

    func release() { active -= 1 }
}

/// Small site icons for the lists, fetched once from each site itself and kept on disk.
@MainActor
final class SiteIcons {
    static let shared = SiteIcons()

    nonisolated static let directory: URL = {
        let dir = Store.dataDirectory.appendingPathComponent("Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var memory: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var running: [String: Task<NSImage?, Never>] = [:]
    private let slots = LoadSlots(limit: 4)

    nonisolated static func key(for url: URL) -> String? {
        url.host()?.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    private nonisolated static func file(_ key: String, _ ext: String) -> URL {
        directory.appendingPathComponent(key + "." + ext)
    }

    /// The icon if it's already in memory.
    func cached(for page: URL) -> NSImage? {
        Self.key(for: page).flatMap { memory[$0] }
    }

    /// The icon from disk, or from the site the first time.
    func load(for page: URL) async -> NSImage? {
        guard let key = Self.key(for: page), !missing.contains(key) else { return nil }
        if let image = memory[key] { return image }
        if let task = running[key] { return await task.value }
        let task = Task<NSImage?, Never> {
            var png = await Self.stored(key)
            if png == nil, await !Self.markedMissing(key), await slots.acquire() {
                png = await Self.fetch(key, page)
                slots.release()
            }
            return png.flatMap(NSImage.init(data:))
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image { memory[key] = image } else { missing.insert(key) }
        return image
    }

    private nonisolated static func stored(_ key: String) async -> Data? {
        try? Data(contentsOf: file(key, "png"))
    }

    private nonisolated static func markedMissing(_ key: String) async -> Bool {
        FileManager.default.fileExists(atPath: file(key, "none").path)
    }

    private nonisolated static func fetch(_ key: String, _ page: URL) async -> Data? {
        if let image = await download(page), let png = png(image) {
            try? png.write(to: file(key, "png"), options: .atomic)
            return png
        }
        // Remember the miss so the site isn't asked again on every launch.
        FileManager.default.createFile(atPath: file(key, "none").path, contents: nil)
        return nil
    }

    /// Icons declared in the page's <link> tags first, then /favicon.ico.
    private nonisolated static func download(_ page: URL) async -> NSImage? {
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

    private nonisolated static func png(_ image: NSImage) -> Data? {
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
