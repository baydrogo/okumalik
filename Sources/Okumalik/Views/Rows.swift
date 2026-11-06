import Combine
import SwiftUI

private func shortHost(_ url: URL) -> String {
    (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
}

/// A site's own icon at 16 pt; `placeholder` until (or unless) one is found.
struct SiteIcon<Placeholder: View>: View {
    let url: URL
    @ViewBuilder var placeholder: Placeholder
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let image = loaded ?? SiteIcons.shared.cached(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                placeholder.frame(width: 16, height: 16)
            }
        }
        .task(id: url) {
            if SiteIcons.shared.cached(for: url) == nil { loaded = await SiteIcons.shared.load(for: url) }
        }
    }
}

/// A link in Okunacaklar, Arşiv, the trash or a tag page: title, description and the
/// "site · author · time" line, a cover picture on the right and a reading-progress line.
struct SavedRow: View, Equatable {
    @AppStorage("compactList") private var compact = false
    /// Redraws this row alone when its own offline copy changes.
    @State private var copyVersion = 0
    let item: SavedItem
    var progress: Double?

    private var cache: ArticleCache { .shared }

    nonisolated static func == (a: SavedRow, b: SavedRow) -> Bool { a.item == b.item && a.progress == b.progress }

    var body: some View {
        let _ = copyVersion
        let meta = cache.meta(for: item.url)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(compact ? 1 : 2)
                if !compact, !item.excerpt.isEmpty {
                    Text(item.excerpt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 5) {
                    Text(byline(meta))
                    ForEach(item.tags, id: \.self) { Text("#" + $0).foregroundStyle(Color.okmAccent.opacity(0.85)) }
                    Spacer(minLength: 0)
                    status
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                if let p = progress, p > 0.03, item.deletedAt == nil {
                    ProgressLine(value: p).padding(.top, 2)
                }
            }
            if !compact, let image = item.imageURL ?? meta?.image.flatMap(URL.init(string:)) {
                Cover(url: image).id(image)
            }
        }
        .padding(.vertical, compact ? 3 : 6)
        .onReceive(cache.changed.filter { [url = item.url] in $0 == nil || $0 == url }) { _ in copyVersion &+= 1 }
    }

    /// "site · author · 6 dk · 2 gün önce"
    private func byline(_ meta: ArticleMeta?) -> String {
        var parts = [shortHost(item.url)]
        if let author = (meta?.author ?? item.author).flatMap({ $0.isEmpty ? nil : $0 }), author != parts[0] { parts.append(author) }
        if let minutes = meta?.minutes { parts.append("\(minutes) dk") }
        if let deleted = item.deletedAt {
            parts.append("silindi " + RelativeDate.string(deleted))
        } else {
            parts.append(RelativeDate.string(item.dateAdded))
        }
        return parts.joined(separator: " · ")
    }

    /// Whether the offline copy exists, for links on the reading list.
    @ViewBuilder
    private var status: some View {
        if item.kind == .readLater, item.deletedAt == nil {
            if cache.failed.contains(item.url) {
                Button { cache.retry(item.url) } label: { Image(systemName: "exclamationmark.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.okmAccent)
                    .help("Çevrimdışı kopya alınamadı; yeniden denemek için tıklayın")
            } else if cache.contains(item.url) {
                Image(systemName: "arrow.down.circle").help("Çevrimdışı okunabilir")
            }
        }
    }
}

/// How far an article has been read.
struct ProgressLine: View {
    let value: Double

    var body: some View {
        Capsule().fill(.quaternary)
            .overlay(Capsule().fill(Color.okmAccent.opacity(0.7)).scaleEffect(x: min(1, value), anchor: .leading))
            .frame(height: 2)
        .help("%\(Int(value * 100)) okundu")
    }
}

/// A page's cover picture, cropped to a small square.
struct Cover: View {
    let url: URL
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let image = loaded ?? Thumbnails.shared.cached(url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary.opacity(0.5))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            if Thumbnails.shared.cached(url) == nil { loaded = await Thumbnails.shared.load(url) }
        }
    }
}

/// A bookmark in the full-width list (after Linkding): title, tags and description, then date and actions.
struct BookmarkRow: View {
    let item: SavedItem
    var onTag: (String) -> Void
    var onEdit: () -> Void
    var onMove: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                SiteIcon(url: item.url) {
                    Text(String(shortHost(item.url).prefix(1)).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(width: 16, height: 16))
                }
                Button { Actions.open(item.url) } label: {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.okmAccent)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(item.url.absoluteString)
            }

            if !item.tags.isEmpty || !item.excerpt.isEmpty {
                HStack(spacing: 6) {
                    ForEach(item.tags, id: \.self) { tag in
                        Button("#" + tag) { onTag(tag) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.okmAccent.opacity(0.8))
                            .help("Yalnızca #\(tag) olanları göster")
                    }
                    if !item.tags.isEmpty && !item.excerpt.isEmpty {
                        Text("|").foregroundStyle(.tertiary)
                    }
                    if !item.excerpt.isEmpty {
                        Text(item.excerpt).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.system(size: 13))
            }

            HStack(spacing: 10) {
                Text(RelativeDate.string(item.dateAdded))
                Text("|")
                Group {
                    Button("Aç") { Actions.open(item.url) }
                    Button("Düzenle", action: onEdit)
                    Button("Okunacaklara Taşı", action: onMove)
                    Button("Sil", action: onDelete)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: 920, alignment: .leading)
    }
}

struct EntryRow: View {
    @AppStorage("compactList") private var compact = false
    let entry: FeedEntry
    let feedTitle: String?
    var queued = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(entry.isRead ? Color.clear : Color.okmAccent)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.system(size: 14, weight: entry.isRead ? .regular : .semibold))
                    .foregroundStyle(entry.isRead ? .secondary : .primary)
                    .lineLimit(compact ? 1 : 2)
                if !compact, !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    if let feedTitle {
                        Text(feedTitle)
                        Text("·")
                    }
                    if let date = entry.date { Text(RelativeDate.string(date)) }
                    if queued {
                        Image(systemName: "tray.full")
                            .foregroundStyle(Color.okmAccent.opacity(0.85))
                            .help("Okunacaklarda")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A highlight as a quote with a yellow rule, and its note below.
struct HighlightQuote: View {
    let highlight: Highlight

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 0.95, green: 0.76, blue: 0.20))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(highlight.text)
                    .font(.system(size: 13, design: .serif))
                    .lineSpacing(2)
                if let note = highlight.note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
