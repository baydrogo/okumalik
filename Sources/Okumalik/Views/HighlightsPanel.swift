import SwiftUI

/// Inspector listing the highlights of the page on screen.
struct HighlightsPanel: View {
    @EnvironmentObject private var store: Store
    let url: URL
    let title: String
    let proxy: ReaderProxy
    @State private var noting: Highlight?
    @State private var noteText = ""

    var body: some View {
        let list = store.highlights(for: url)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Vurgular").font(.system(size: 15, weight: .semibold, design: .serif))
                Spacer()
                if !list.isEmpty {
                    Text("\(list.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if list.isEmpty {
                Spacer()
                Text("Metni seçip ⇧⌘H’ye basın ya da sağ tıklayıp “Vurgula”yı seçin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(list) { h in
                            HighlightQuote(highlight: h)
                                .contentShape(Rectangle())
                                .onTapGesture { proxy.scroll(to: h.id) }
                                .contextMenu {
                                    Button("Metni Kopyala") { Actions.copyText(h.text) }
                                    Button("Markdown Olarak Kopyala") {
                                        Actions.copyText(Store.markdown(title: title, url: url, highlights: [h]))
                                    }
                                    Button(h.note == nil ? "Not Ekle…" : "Notu Düzenle…") {
                                        noteText = h.note ?? ""
                                        noting = h
                                    }
                                    Divider()
                                    Button("Vurguyu Sil", role: .destructive) { store.deleteHighlight(h.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                Divider()
                HStack {
                    Button("Markdown Kopyala") {
                        Actions.copyText(Store.markdown(title: title, url: url, highlights: list))
                    }
                    Spacer()
                    Button("Dışa Aktar…") {
                        Actions.saveMarkdown(Store.markdown(title: title, url: url, highlights: list), name: title)
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(12)
            }
        }
        .alert("Vurguya Not", isPresented: Binding(get: { noting != nil }, set: { if !$0 { noting = nil } })) {
            TextField("Not", text: $noteText, axis: .vertical)
            Button("Kaydet") { if let h = noting { store.setHighlightNote(h.id, noteText) } }
            Button("Vazgeç", role: .cancel) {}
        }
    }
}
