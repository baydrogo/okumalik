import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// "Görseller": saved pictures in columns, like a pin board. Pictures come in from the
/// Firefox extension, the reader's right-click menu, dropping files or pasting.
struct ImagesView: View {
    @EnvironmentObject private var store: Store
    @State private var search = ""
    @State private var tagFilter = Set<String>()
    @State private var open: UUID?
    @State private var dropping = false
    @FocusState private var gridFocused: Bool

    private var shown: [SavedImage] {
        let query = search.trimmingCharacters(in: .whitespaces)
        // A chosen tag that no picture carries any more (renamed, deleted) no longer filters.
        let inUse = Set(store.images.flatMap(\.tags))
        let active = tagFilter.filter(inUse.contains)
        return store.images.filter { image in
            if !active.allSatisfy(image.tags.contains) { return false }
            guard !query.isEmpty else { return true }
            if query.hasPrefix("#") {
                let tag = Store.normalizedTag(query) ?? ""
                return image.tags.contains { $0.hasPrefix(tag) }
            }
            return [image.pageTitle, image.note, image.page?.host(), image.tags.joined(separator: " ")]
                .contains { $0?.localizedStandardContains(query) == true }
        }
    }

    private var tagCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for image in store.images { for tag in image.tags { counts[tag, default: 0] += 1 } }
        return counts
    }

    var body: some View {
        let images = shown
        VStack(spacing: 0) {
            header(count: images.count)
            Divider().opacity(0.5)
            if store.images.isEmpty {
                empty
            } else if images.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        Masonry(images: images, width: geometry.size.width - 36) { image in
                            open = image.id
                        }
                        .padding(18)
                    }
                }
            }
        }
        .themed(.list)
        .focusable()
        .focusEffectDisabled()
        .focused($gridFocused)
        .onAppear { gridFocused = true }
        .onPasteCommand(of: [.fileURL, .image, .url]) { providers in store.addImages(from: providers) }
        .onDrop(of: [.fileURL, .image, .url], isTargeted: $dropping) { providers in
            store.addImages(from: providers)
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.okmAccent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.okmAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let id = open, store.image(id) != nil {
                ImageViewer(order: images.map(\.id), current: $open)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: open)
        .onChange(of: open) { if open == nil { gridFocused = true } }
    }

    private func header(count: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Görsellerde ara", text: $search)
                    .textFieldStyle(.plain)
                    .onExitCommand { search = "" }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .help("Sayfa başlığı, site, not ve etiketlerde arar; etiket için #etiket yazın")

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Görseller").font(.system(size: 22, weight: .semibold))
                    Text(store.images.isEmpty ? "Henüz görsel yok" : "\(count) görsel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Group {
                    Button { addFromFiles() } label: { Image(systemName: "plus") }
                        .help("Dosyadan görsel ekle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 12)

            let counts = tagCounts
            if !counts.isEmpty {
                TagStrip(counts: counts, selected: Binding(
                    get: { tagFilter.filter { counts[$0] != nil } },
                    set: { tagFilter = $0 }
                ))
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Görsel yok", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Firefox'ta bir resme sağ tıklayıp “Görseli Okumalık'a gönder”i seçin, okuyucuda bir resme sağ tıklayın ya da resimleri buraya sürükleyin veya ⌘V ile yapıştırın.")
        }
    }

    private func addFromFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .svg]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        store.addImages(from: panel.urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider(object: $0 as NSURL) })
    }
}

// MARK: Grid

/// Pictures laid out in columns of equal width, each added to the shortest column.
private struct Masonry: View {
    let images: [SavedImage]
    let width: CGFloat
    let open: (SavedImage) -> Void

    private let spacing: CGFloat = 14

    var body: some View {
        let count = max(1, Int((width + spacing) / (210 + spacing)))
        let column = max(80, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        let columns = arrange(count: count, column: column)
        HStack(alignment: .top, spacing: spacing) {
            ForEach(columns.indices, id: \.self) { c in
                LazyVStack(spacing: spacing) {
                    ForEach(columns[c]) { image in
                        ImageTile(image: image, width: column)
                            .onTapGesture { open(image) }
                    }
                }
                .frame(width: column)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arrange(count: Int, column: CGFloat) -> [[SavedImage]] {
        var columns = Array(repeating: [SavedImage](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for image in images {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(image)
            heights[shortest] += column * ImageTile.aspect(image) + spacing
        }
        return columns
    }
}

private struct ImageTile: View {
    @EnvironmentObject private var store: Store
    let image: SavedImage
    let width: CGFloat
    @State private var picture: NSImage?
    @State private var hovering = false

    /// Very tall or wide pictures are cropped in the grid so one can't take over a column.
    static func aspect(_ image: SavedImage) -> CGFloat { min(max(CGFloat(image.aspect), 0.4), 2.2) }

    init(image: SavedImage, width: CGFloat) {
        self.image = image
        self.width = width
        _picture = State(initialValue: ImageThumbs.shared.cached(image))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.primary.opacity(0.06))
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: width * Self.aspect(image))
                    .clipped()
            }
            if hovering, let label = image.pageTitle ?? image.page?.host() {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
        }
        .frame(width: width, height: width * Self.aspect(image))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .task(id: image.id) {
            if picture == nil { picture = await ImageThumbs.shared.load(image) }
        }
        .contextMenu { ImageMenu(image: image) }
        .help(image.note ?? "")
    }
}

/// The actions for one picture, shared by the grid's context menu and the viewer.
struct ImageMenu: View {
    @EnvironmentObject private var store: Store
    let image: SavedImage

    var body: some View {
        if let page = image.page {
            Button("Sayfayı Aç") { Actions.open(page) }
        }
        Button("Önizleme'de Aç") { Actions.open(ImageFiles.url(image)) }
        Button("Görseli Kopyala") { ImageActions.copy(image) }
        if let source = image.source {
            Button("Görsel Adresini Kopyala") { Actions.copy(source) }
        }
        Button("Finder'da Göster") { NSWorkspace.shared.activateFileViewerSelecting([ImageFiles.url(image)]) }
        TagMenu(targets: [.image(image.id)])
        Divider()
        Button("Sil", role: .destructive) { store.deleteImages([image.id]) }
    }
}

enum ImageActions {
    static func copy(_ image: SavedImage) {
        let url = ImageFiles.url(image)
        guard let picture = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([picture])
    }
}

// MARK: Viewer

/// One picture large, over the grid, with its details beside it. ← → step through, Esc closes.
private struct ImageViewer: View {
    @EnvironmentObject private var store: Store
    let order: [UUID]
    @Binding var current: UUID?
    @FocusState private var focused: Bool

    private var index: Int? { current.flatMap { order.firstIndex(of: $0) } }

    var body: some View {
        if let id = current, let image = store.image(id) {
            HStack(spacing: 0) {
                ZStack {
                    Color.black.opacity(0.9)
                        .contentShape(Rectangle())
                        .onTapGesture { current = nil }
                    AnimatedImage(url: ImageFiles.url(image))
                        .padding(28)
                        .allowsHitTesting(false)
                    HStack {
                        stepButton("chevron.left", -1)
                        Spacer()
                        stepButton("chevron.right", 1)
                    }
                    .padding(.horizontal, 10)
                }
                .overlay(alignment: .topLeading) {
                    Button { current = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(14)
                    .help("Kapat (Esc)")
                }
                ImageDetails(image: image) { remove(image) }
                    .frame(width: 290)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(.escape) { current = nil; return .handled }
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onDeleteCommand { remove(image) }
        }
    }

    private func stepButton(_ symbol: String, _ by: Int) -> some View {
        let enabled = index.map { order.indices.contains($0 + by) } ?? false
        return Button { step(by) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    private func step(_ by: Int) {
        guard let index, order.indices.contains(index + by) else { return }
        current = order[index + by]
    }

    /// Deletes and moves on to the next picture, or closes after the last one.
    private func remove(_ image: SavedImage) {
        let next = index.flatMap { i in order.indices.contains(i + 1) ? order[i + 1] : (i > 0 ? order[i - 1] : nil) }
        store.deleteImages([image.id])
        current = next
        focused = true
    }
}

private struct ImageDetails: View {
    @EnvironmentObject private var store: Store
    let image: SavedImage
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let host = image.page?.host() ?? image.source?.host() {
                    Text(host.replacingOccurrences(of: "www.", with: "").uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                }
                if let title = image.pageTitle {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .textSelection(.enabled)
                }
                if let page = image.page {
                    Button { Actions.open(page) } label: { Label("Sayfayı Aç", systemImage: "arrow.up.right") }
                        .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 8) {
                    Button("Kopyala") { ImageActions.copy(image) }
                    Button("Önizleme'de Aç") { Actions.open(ImageFiles.url(image)) }
                }
                .controlSize(.small)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Etiketler").font(.system(size: 13, weight: .semibold))
                    TagEditor(tags: store.tagBinding(.image(image.id)))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not").font(.system(size: 13, weight: .semibold))
                    TextField("Kendiniz için bir not", text: store.imageNoteBinding(image.id), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...10)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(image.width) × \(image.height) piksel")
                    Text("Eklendi: \(image.dateAdded.formatted(date: .long, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)

                Button(role: .destructive) { delete() } label: { Label("Sil", systemImage: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shows a picture file fitted to the space; GIFs play.
private struct AnimatedImage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.shown != url else { return }
        context.coordinator.shown = url
        view.image = NSImage(contentsOf: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var shown: URL? }
}

// MARK: Thumbnails

/// Grid-sized copies of the pictures, made once off the main thread and kept in Caches.
@MainActor
final class ImageThumbs {
    static let shared = ImageThumbs()

    /// Columns are about 210–300 pt wide; 2x that.
    private nonisolated static let side = 640
    private nonisolated static let directory: URL = {
        let dir = Store.cacheDirectory.appendingPathComponent("ImageThumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private let slots = LoadSlots(limit: 4)

    func cached(_ image: SavedImage) -> NSImage? { memory.object(forKey: image.file as NSString) }

    func load(_ image: SavedImage) async -> NSImage? {
        if let picture = cached(image) { return picture }
        guard await slots.acquire() else { return nil }
        defer { slots.release() }
        if let picture = cached(image) { return picture }
        let original = ImageFiles.url(image)
        let name = image.id.uuidString
        guard let made = await Task.detached(priority: .utility, operation: { Self.make(original, name: name) }).value else { return nil }
        let picture = NSImage(cgImage: made, size: NSSize(width: made.width, height: made.height))
        memory.setObject(picture, forKey: image.file as NSString)
        return picture
    }

    private nonisolated static func make(_ original: URL, name: String) -> CGImage? {
        for ext in ["jpg", "png"] {
            let file = directory.appendingPathComponent(name + "." + ext)
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
               let stored = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                return stored
            }
        }
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else { return nil }
        // The size limit is for the longer side; tall pictures need more so their width stays sharp.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? side
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? side
        let ratio = Double(max(width, height)) / Double(max(min(width, height), 1))
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(Int(Double(side) * max(1, ratio)), side * 3),
        ] as CFDictionary) else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(picture.alphaInfo)
        let type: UTType = hasAlpha ? .png : .jpeg
        let file = directory.appendingPathComponent(name + "." + (hasAlpha ? "png" : "jpg"))
        if let target = CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(target, picture, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            CGImageDestinationFinalize(target)
        }
        return picture
    }
}
