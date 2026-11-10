import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Picture files of the "Görseller" section, under the data folder.
enum ImageFiles {
    static let directory: URL = {
        let dir = Store.dataDirectory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ image: SavedImage) -> URL { directory.appendingPathComponent(image.file) }

    struct Stored {
        var file: String
        var width: Int
        var height: Int
    }

    /// Checks that the bytes are a picture and writes them. TIFF (what screenshots and some drags
    /// give) is re-encoded so it doesn't fill the disk; pictures only AppKit can draw (SVG) become PNG.
    static func store(_ data: Data, id: UUID) -> Stored? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0,
           let type = CGImageSourceGetType(source) as String?,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var width = properties[kCGImagePropertyPixelWidth] as? Int,
           var height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 {
            // EXIF orientations 5…8 are turned a quarter: the picture shows the other way round.
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            let utType = UTType(type)
            if utType?.conforms(to: .tiff) == true || utType?.conforms(to: .bmp) == true,
               let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return write(picture, id: id)
            }
            let file = id.uuidString + "." + (utType?.preferredFilenameExtension ?? "img")
            guard (try? data.write(to: directory.appendingPathComponent(file), options: .atomic)) != nil else { return nil }
            return Stored(file: file, width: width, height: height)
        }
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = min(2, 4096 / max(image.size.width, image.size.height))
        var rect = NSRect(x: 0, y: 0, width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let picture = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return write(picture, id: id)
    }

    private static func write(_ picture: CGImage, id: UUID) -> Stored? {
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(picture.alphaInfo)
        let type: UTType = hasAlpha ? .png : .jpeg
        let file = id.uuidString + "." + (hasAlpha ? "png" : "jpg")
        guard let target = CGImageDestinationCreateWithURL(directory.appendingPathComponent(file) as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, picture, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { return nil }
        return Stored(file: file, width: picture.width, height: picture.height)
    }

    /// The picture's bytes: downloaded with the page as referrer (some sites refuse pictures
    /// asked for from elsewhere), read from disk, or decoded from a data: address.
    static func load(_ url: URL, referer: URL?) async throws -> Data {
        if url.scheme == "data" {
            let text = url.absoluteString
            guard let comma = text.firstIndex(of: ",") else { throw AppError.invalidURL }
            let header = text[..<comma]
            let payload = String(text[text.index(after: comma)...])
            let data = header.hasSuffix(";base64")
                ? Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
                : (payload.removingPercentEncoding ?? payload).data(using: .utf8)
            guard let data else { throw AppError.invalidURL }
            return data
        }
        if url.isFileURL { return try Data(contentsOf: url) }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/svg+xml,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        if let referer, referer.scheme?.hasPrefix("http") == true {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        let (data, response) = try await Net.session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError.http(http.statusCode)
        }
        return data
    }

    /// Whether an address looks like a picture file by its name.
    static func looksLikeImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return !ext.isEmpty && (UTType(filenameExtension: ext)?.conforms(to: .image) ?? false)
    }
}

extension Store {
    // MARK: Adding

    /// Saves a picture from an address (the browser extension, the reader's right-click menu).
    func saveImage(from source: URL, page: URL?, title: String?, tags: [String] = []) {
        let web = source.scheme?.hasPrefix("http") == true
        if web, let i = images.firstIndex(where: { $0.source == source }) {
            var existing = images.remove(at: i)
            existing.tags = Self.cleanTags(existing.tags + tags)
            existing.dateAdded = Date()
            images.insert(existing, at: 0)
            notify("Bu görsel zaten kayıtlı; başa taşındı")
            return
        }
        Task {
            do {
                let data = try await ImageFiles.load(source, referer: page)
                await addImage(data, source: web ? source : nil, page: page, title: title, tags: tags)
            } catch {
                notify("Görsel indirilemedi")
            }
        }
    }

    /// Stores picture bytes as a new entry at the top of the gallery.
    @discardableResult
    func addImage(_ data: Data, source: URL? = nil, page: URL? = nil, title: String? = nil,
                  tags: [String] = [], quiet: Bool = false) async -> Bool {
        let id = UUID()
        let stored = await Task.detached(priority: .userInitiated) { ImageFiles.store(data, id: id) }.value
        guard let stored else {
            if !quiet { notify("Bu dosya bir görsel değil") }
            return false
        }
        let image = SavedImage(id: id, file: stored.file, source: source, page: page,
                               pageTitle: title.flatMap { $0.isEmpty ? nil : $0 },
                               width: stored.width, height: stored.height, tags: Self.cleanTags(tags))
        images.insert(image, at: 0)
        if !quiet { notify("Görsellere kaydedildi") }
        return true
    }

    /// Pictures dropped on the gallery or pasted into it: files, picture data or web addresses.
    func addImages(from providers: [NSItemProvider]) {
        Task {
            var added = 0
            for provider in providers {
                if let data = await Self.pictureData(from: provider),
                   await addImage(data.bytes, source: data.source, page: nil, title: nil, quiet: true) {
                    added += 1
                }
            }
            notify(added == 0 ? "Görsel bulunamadı" : added == 1 ? "Görsellere kaydedildi" : "\(added) görsel kaydedildi")
        }
    }

    private struct Picked {
        var bytes: Data
        var source: URL?
    }

    private static func pictureData(from provider: NSItemProvider) async -> Picked? {
        // A file from Finder or a download.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider), url.isFileURL,
           let data = try? Data(contentsOf: url) {
            return Picked(bytes: data, source: nil)
        }
        // Browsers put the picture's address next to its pixels; the original file is better than
        // their redrawn copy. A picture inside a link carries the link's address, so only take
        // addresses that name a picture file.
        let web = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? await loadURL(provider) : nil
        if let web, web.scheme?.hasPrefix("http") == true, ImageFiles.looksLikeImage(web),
           let data = try? await ImageFiles.load(web, referer: nil) {
            return Picked(bytes: data, source: web)
        }
        for type in [UTType.png, .jpeg, .gif, .webP, .heic, .tiff, .image]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await loadData(provider, type) { return Picked(bytes: data, source: web) }
        }
        if let web, web.scheme?.hasPrefix("http") == true, let data = try? await ImageFiles.load(web, referer: nil) {
            return Picked(bytes: data, source: web)
        }
        return nil
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
        }
    }

    private static func loadData(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in done.resume(returning: data) }
        }
    }

    // MARK: Changing

    func image(_ id: UUID) -> SavedImage? { images.first { $0.id == id } }

    func imageNoteBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.images.first { $0.id == id }?.note ?? "" },
            set: { text in
                guard let i = self.images.firstIndex(where: { $0.id == id }) else { return }
                self.images[i].note = text.isEmpty ? nil : text
            }
        )
    }

    /// Removes pictures; their files stay until the next launch, so "Geri Al" can bring them back.
    func deleteImages(_ ids: Set<UUID>) {
        let removed = images.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        images.removeAll { ids.contains($0.id) }
        let message = removed.count == 1 ? "Görsel silindi" : "\(removed.count) görsel silindi"
        undoable(message, name: "Görseli Sil") { store in
            let present = Set(store.images.map(\.id))
            store.images = (store.images + removed.filter { !present.contains($0.id) }).sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    /// Picture files no entry points to any more go to the macOS Trash, where they can still be found.
    func sweepImageFiles() {
        // An empty gallery may be a library that failed to load; leave the files alone then.
        guard !images.isEmpty else { return }
        let inUse = Set(images.map(\.file))
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let names = (try? fm.contentsOfDirectory(atPath: ImageFiles.directory.path)) ?? []
            for name in names where !name.hasPrefix(".") && !inUse.contains(name) {
                try? fm.trashItem(at: ImageFiles.directory.appendingPathComponent(name), resultingItemURL: nil)
            }
        }
    }
}
