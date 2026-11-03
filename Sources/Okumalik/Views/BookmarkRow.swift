import SwiftUI

/// A bookmark in the full-width list (after Linkding): title, tags and description, then date and actions.
struct BookmarkRow: View {
    @ObservedObject private var icons = SiteIcons.shared
    let item: SavedItem
    var onTag: (String) -> Void
    var onEdit: () -> Void
    var onMove: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                siteIcon
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
                Text(item.dateAdded, format: .relative(presentation: .named))
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

    @ViewBuilder
    private var siteIcon: some View {
        let _ = icons.version
        if let image = icons.icon(for: item.url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Text(String((SiteIcons.key(for: item.url) ?? "?").prefix(1)).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
        }
    }
}
