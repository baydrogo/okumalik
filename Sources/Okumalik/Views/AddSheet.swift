import SwiftUI

struct AddSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let initialKind: AddKind
    var initialTags: [String] = []

    @State private var urlText = ""
    @State private var kind: AddKind = .readLater
    @State private var tags: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Tür", selection: $kind) {
                    ForEach(AddKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("Adres", text: $urlText, prompt: Text(kind == .feed ? "site.com ya da akış adresi" : "https://…"))
                    .onSubmit(submit)

                LabeledContent("Etiketler") {
                    TagEditor(tags: $tags)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Vazgeç", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Ekle", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .onAppear {
            kind = initialKind
            tags = initialTags
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               clip.hasPrefix("http"), !clip.contains(" ") {
                urlText = clip
            }
        }
    }

    private func submit() {
        error = nil
        switch kind {
        case .feed:
            busy = true
            Task {
                do {
                    try await store.addFeed(urlText, tags: tags)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                    busy = false
                }
            }
        case .readLater, .bookmark:
            do {
                try store.addLink(urlText, kind: kind == .bookmark ? .bookmark : .readLater, tags: tags)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
