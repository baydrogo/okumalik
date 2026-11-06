import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Cover pictures for the lists: shrunk once to row size off the main thread and kept
/// on disk, so scrolling never has to decode or scale a full-size image.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    /// 58 pt squares at 2x.
    private nonisolated static let side = 116
    private nonisolated static let directory: URL = {
        let dir = Store.cacheDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let memory: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private var failed = Set<URL>()
    private var running: [URL: Task<CGImage?, Never>] = [:]
    private let slots = LoadSlots(limit: 4)

    func cached(_ url: URL) -> NSImage? { memory.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        guard !failed.contains(url) else { return nil }
        if let task = running[url] { return await task.value.map(Self.image) }
        guard await slots.acquire() else { return nil }
        defer { slots.release() }
        if let image = cached(url) { return image }
        if let task = running[url] { return await task.value.map(Self.image) }
        let task = Task.detached(priority: .utility) { await Self.make(url) }
        running[url] = task
        let picture = await task.value
        running[url] = nil
        guard let picture else {
            failed.insert(url)
            return nil
        }
        let image = Self.image(picture)
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    private static func image(_ picture: CGImage) -> NSImage {
        NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
    }

    private nonisolated static func make(_ url: URL) async -> CGImage? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let file = directory.appendingPathComponent(digest.prefix(16).map { String(format: "%02x", $0) }.joined())
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let stored = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return stored
        }
        guard let data = try? await Net.get(url).0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let picture = shrink(source) else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(picture.alphaInfo)
        let type = hasAlpha ? UTType.png : .jpeg
        if let target = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(target, picture, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(target)
        }
        return picture
    }

    /// Scaled so the shorter side fills the square; the view crops the rest.
    private nonisolated static func shrink(_ source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? side
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? side
        let ratio = Double(max(width, height)) / Double(max(min(width, height), 1))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Int(Double(side) * ratio), side * 6),
        ] as CFDictionary)
    }
}
