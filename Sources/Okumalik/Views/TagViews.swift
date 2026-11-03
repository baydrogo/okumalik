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
                Text("#" + tag)
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
struct TagMenu: View {
    @EnvironmentObject private var store: Store
    let target: TagTarget
    var title = "Etiketler"

    var body: some View {
        Menu(title) {
            let current = store.tags(of: target)
            ForEach(store.allTags, id: \.self) { tag in
                Toggle("#" + tag, isOn: Binding(get: { current.contains(tag) }, set: { _ in store.toggleTag(tag, on: target) }))
            }
            if !store.allTags.isEmpty { Divider() }
            Button("Yeni Etiket…") { store.tagPrompt = target }
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
