import SwiftUI

/// Tag chips with a field for adding more; suggests tags already in use.
struct TagEditor: View {
    @EnvironmentObject private var store: Store
    @Binding var tags: [String]
    @State private var text = ""
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let query = Store.normalizedTag(text) ?? ""
        return store.allTags
            .filter { !tags.contains($0) && (query.isEmpty || $0.localizedStandardContains(query)) }
            .prefix(12)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(tag: tag, selected: true) { tags.removeAll { $0 == tag } }
                    }
                }
            }
            TextField("Etiket ekle", text: $text, prompt: Text("Etiket yazıp ↩︎’ye basın"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { add(text) }
                .onChange(of: text) {
                    if text.contains(",") { add(text) }
                }
            if !suggestions.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(suggestions, id: \.self) { tag in
                        TagChip(tag: tag, selected: false) { add(tag) }
                    }
                }
            }
        }
    }

    private func add(_ raw: String) {
        let new = raw.split(separator: ",").compactMap { Store.normalizedTag(String($0)) }
        if !new.isEmpty { tags = Store.cleanTags(tags + new) }
        text = ""
        focused = true
    }
}

/// A tag as a small capsule. Selected chips show a remove mark; the others add on click.
struct TagChip: View {
    let tag: String
    var selected = false
    var help: String?
    var action: (() -> Void)?

    var body: some View {
        Button { action?() } label: {
            HStack(spacing: 4) {
                Text("#" + tag).lineLimit(1)
                if selected && action != nil {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.6)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? Color.okmAccent : .secondary)
            .background(Capsule().fill(selected ? Color.okmAccent.opacity(0.12) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help ?? (selected ? "Etiketi kaldır" : "Etiketi ekle"))
    }
}

/// "Etiketler" submenu with a checkmark per tag in use, for context menus.
/// With several targets, a tag is checked when all of them carry it, and choosing it adds or removes it for all.
struct TagMenu: View {
    @EnvironmentObject private var store: Store
    let targets: [TagTarget]
    var title = "Etiketler"

    var body: some View {
        Menu(title) {
            ForEach(store.allTags, id: \.self) { tag in
                let all = targets.allSatisfy { store.tags(of: $0).contains(tag) }
                Toggle("#" + tag, isOn: Binding(get: { all }, set: { on in
                    for target in targets where store.tags(of: target).contains(tag) != on { store.toggleTag(tag, on: target) }
                }))
            }
            if !store.allTags.isEmpty { Divider() }
            Button("Yeni Etiket…") { store.tagPrompt = targets }
        }
    }
}

/// Lays children out in rows, wrapping like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width += rows[last].indices.isEmpty ? size.width : size.width + spacing
            rows[last].height = max(rows[last].height, size.height)
            rows[last].indices.append(i)
        }
        return rows
    }
}

// MARK: Showing and filtering by tags

extension Color {
    /// A soft color of its own for each tag, the same everywhere and on every launch.
    static func tag(_ name: String) -> Color {
        var hash: UInt32 = 2166136261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let hue = CGFloat(hash % 360) / 360
        // Deep enough to read on light paper, lighter on dark backgrounds.
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hue: hue, saturation: 0.45, brightness: 0.88, alpha: 1)
                : NSColor(hue: hue, saturation: 0.7, brightness: 0.5, alpha: 1)
        })
    }
}

/// A tag on a row: a small tinted capsule, clickable when `action` is given.
struct TagPill: View {
    let tag: String
    var action: (() -> Void)?

    var body: some View {
        let color = Color.tag(tag)
        let label = Text(tag)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.13)))
        if let action {
            Button(action: action) { label.contentShape(Capsule()) }
                .buttonStyle(.plain)
                .help("Yalnızca #\(tag) olanları göster")
        } else {
            label
        }
    }
}

/// A row's tags: the first few as capsules, the rest counted.
struct TagPills: View {
    let tags: [String]
    var limit = 3
    var action: ((String) -> Void)?

    var body: some View {
        // As many as the row has room for, never cut off at the edge.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: min(limit, tags.count), through: 1, by: -1)), id: \.self) { n in
                pills(n)
            }
            Text("+\(tags.count)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .help(tags.map { "#" + $0 }.joined(separator: " "))
        }
    }

    private func pills(_ n: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(n), id: \.self) { tag in
                TagPill(tag: tag, action: action.map { act in { act(tag) } })
            }
            if tags.count > n {
                Text("+\(tags.count - n)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .help(tags.dropFirst(n).map { "#" + $0 }.joined(separator: " "))
            }
        }
        .fixedSize()
    }
}

/// The tags of a list under its title, with how many rows carry each. Clicking one filters by it;
/// several chosen together show only what carries all of them.
struct TagStrip: View {
    let counts: [String: Int]
    @Binding var selected: Set<String>

    private var ordered: [String] {
        // Chosen tags first, then the most used.
        counts.keys.sorted {
            let a = selected.contains($0), b = selected.contains($1)
            if a != b { return a }
            if counts[$0] != counts[$1] { return counts[$0]! > counts[$1]! }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// How many tags show before "+N" when the strip is folded: about two lines in a narrow list.
    private let folded = 8
    @AppStorage("tagStripOpen") private var open = false

    var body: some View {
        let all = ordered
        // Chosen tags come first, so folding never hides one of them.
        let shown = open ? all : Array(all.prefix(max(folded, selected.count)))
        FlowLayout(spacing: 5) {
            ForEach(shown, id: \.self) { tag in chip(tag) }
            if all.count > shown.count {
                textButton("+\(all.count - shown.count) etiket", help: "Bütün etiketleri göster") { open = true }
            } else if open, all.count > folded {
                textButton("Daha az", help: "Yalnızca en çok kullanılanları göster") { open = false }
            }
            if !selected.isEmpty {
                textButton("Temizle", help: "Etiket süzgecini kaldır") { selected = [] }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func textButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15), action) } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.okmAccent)
        .help(help)
    }

    private func chip(_ tag: String) -> some View {
        let on = selected.contains(tag)
        let color = Color.tag(tag)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if on { selected.remove(tag) } else { selected.insert(tag) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("#" + tag).lineLimit(1)
                Text("\(counts[tag] ?? 0)")
                    .monospacedDigit()
                    .opacity(on ? 0.85 : 0.5)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(on ? Color.white : color)
            .background(Capsule().fill(on ? color : color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(on ? 0 : 0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "#\(tag) süzgecini kaldır" : "Yalnızca #\(tag) olanları göster")
    }
}
