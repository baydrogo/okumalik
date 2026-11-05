import SwiftUI

extension Store {
    /// A binding to one field of a saved item; edits are stored as they are typed.
    func binding<T>(_ id: UUID, _ key: WritableKeyPath<SavedItem, T>, default value: T) -> Binding<T> {
        Binding(
            get: { self.items.first { $0.id == id }?[keyPath: key] ?? value },
            set: { new in
                guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i][keyPath: key] = new
            }
        )
    }

    func noteBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { self.items.first { $0.id == id }?.note ?? "" }, set: { self.updateItem(id, note: $0) })
    }

    func tagBinding(_ target: TagTarget) -> Binding<[String]> {
        Binding(get: { self.tags(of: target) }, set: { self.setTags($0, on: target) })
    }
}

/// Detail pane for a bookmark: its details, editable in place, instead of a page preview.
struct BookmarkDetail: View {
    @EnvironmentObject private var store: Store
    let item: SavedItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text((item.url.host() ?? "").replacingOccurrences(of: "www.", with: "").uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Başlık", text: store.binding(item.id, \.title, default: ""), axis: .vertical)
                        .font(.system(size: 26, weight: .semibold))
                        .textFieldStyle(.plain)
                    TextField("Açıklama ekleyin", text: store.binding(item.id, \.excerpt, default: ""), axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .textFieldStyle(.plain)
                        .lineLimit(1...12)
                }

                HStack(spacing: 10) {
                    Button { Actions.open(item.url) } label: {
                        Label("Tarayıcıda Aç", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("o")
                    Button("Bağlantıyı Kopyala") { Actions.copy(item.url) }
                }
                .controlSize(.regular)

                Text(item.url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(3)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Etiketler").font(.system(size: 13, weight: .semibold))
                    TagEditor(tags: store.tagBinding(.item(item.id)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Not").font(.system(size: 13, weight: .semibold))
                    TextField("Kendiniz için bir not", text: store.noteBinding(item.id), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...10)
                }

                Text("Eklendi: \(item.dateAdded.formatted(date: .long, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Edit sheet for any saved link (title, description, tags, note).
struct ItemEditSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Başlık", text: store.binding(id, \.title, default: ""), axis: .vertical)
                TextField("Açıklama", text: store.binding(id, \.excerpt, default: ""), axis: .vertical)
                    .lineLimit(2...8)
                LabeledContent("Etiketler") {
                    TagEditor(tags: store.tagBinding(.item(id)))
                }
                TextField("Not", text: store.noteBinding(id), prompt: Text("Kendiniz için bir not"), axis: .vertical)
                    .lineLimit(2...10)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Bitti") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }
}
