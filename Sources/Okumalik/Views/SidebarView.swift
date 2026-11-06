import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: Store
    @Binding var selection: SidebarSection?
    @State private var renaming: Feed?
    @State private var removing: Feed?
    @State private var newName = ""
    @State private var renamingTag: String?
    @State private var deletingTag: String?
    @State private var dropTarget: String?

    var body: some View {
        let unread = store.unreadByFeed
        let tagCounts = store.tagCounts
        List(selection: $selection) {
            Section("Kitaplık") {
                Label("Okunacaklar", systemImage: "tray")
                    .badge(store.unreadLaterCount)
                    .tag(SidebarSection.readLater)
                Label("Yer İmleri", systemImage: "bookmark")
                    .tag(SidebarSection.bookmarks)
                Label("Vurgular", systemImage: "highlighter")
                    .tag(SidebarSection.highlights)
                Label("Arşiv", systemImage: "archivebox")
                    .tag(SidebarSection.archive)
                Label("Çöp Kutusu", systemImage: "trash")
                    .tag(SidebarSection.trash)
            }

            Section("Akışlar") {
                Label("Tümü", systemImage: "circle.grid.2x2")
                    .badge(unread.values.reduce(0, +))
                    .tag(SidebarSection.allFeeds)
                ForEach(store.feeds) { feed in
                    Label {
                        HStack(spacing: 4) {
                            Text(feed.title).lineLimit(1)
                            if let error = feed.lastError {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.okmAccent)
                                    .help("Güncellenemedi: \(error)")
                            }
                        }
                    } icon: {
                        SiteIcon(url: feed.siteURL ?? feed.url) {
                            Circle().fill(.tertiary).frame(width: 5, height: 5)
                        }
                    }
                    .badge(unread[feed.id] ?? 0)
                    .tag(SidebarSection.feed(feed.id))
                    .draggable(TagTarget.feed(feed.id).dragToken)
                    .contextMenu {
                        Button("Tümünü Okundu Say") { store.markAllRead(feed: feed.id) }
                        Button("Yeniden Adlandır…") { newName = feed.title; renaming = feed }
                        TagMenu(targets: [.feed(feed.id)])
                        if let site = feed.siteURL {
                            Button("Siteyi Aç") { Actions.open(site) }
                        }
                        Button("Akış Adresini Kopyala") { Actions.copy(feed.url) }
                        Divider()
                        Button("Akışı Sil…", role: .destructive) { removing = feed }
                    }
                }
            }

            let tags = tagCounts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if !tags.isEmpty {
                Section("Etiketler") {
                    ForEach(tags, id: \.self) { tag in
                        Label(tag, systemImage: "number")
                            .badge(tagCounts[tag] ?? 0)
                            .tag(SidebarSection.tag(tag))
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.okmAccent.opacity(dropTarget == tag ? 0.22 : 0))
                                    .padding(.horizontal, -6)
                                    .padding(.vertical, -3)
                            )
                            .dropDestination(for: String.self) { tokens, _ in
                                let targets = tokens.compactMap(TagTarget.init(dragToken:))
                                targets.forEach { store.addTag(tag, to: $0) }
                                return !targets.isEmpty
                            } isTargeted: { over in
                                dropTarget = over ? tag : (dropTarget == tag ? nil : dropTarget)
                            }
                            .contextMenu {
                                Button("Yeniden Adlandır…") { newName = tag; renamingTag = tag }
                                Button("Etiketi Sil…", role: .destructive) { deletingTag = tag }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .alert("Akışı Yeniden Adlandır", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Ad", text: $newName)
            Button("Kaydet") { if let feed = renaming { store.renameFeed(feed.id, to: newName) } }
            Button("Vazgeç", role: .cancel) {}
        }
        .alert("Etiketi Yeniden Adlandır", isPresented: Binding(get: { renamingTag != nil }, set: { if !$0 { renamingTag = nil } })) {
            TextField("Ad", text: $newName)
            Button("Kaydet") {
                guard let old = renamingTag, let new = Store.normalizedTag(newName) else { return }
                store.renameTag(old, to: new)
                if selection == .tag(old) { selection = .tag(new) }
            }
            Button("Vazgeç", role: .cancel) {}
        }
        .confirmationDialog(
            "“\(removing?.title ?? "")” akışı silinsin mi?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Akışı Sil", role: .destructive) {
                guard let feed = removing else { return }
                if selection == .feed(feed.id) { selection = .allFeeds }
                store.removeFeed(feed.id)
            }
        } message: {
            Text("Akışın yazıları da silinir. Okunacaklar'a ya da Yer İmleri'ne kaydettikleriniz kalır.")
        }
        .confirmationDialog(
            "“#\(deletingTag ?? "")” etiketi silinsin mi?",
            isPresented: Binding(get: { deletingTag != nil }, set: { if !$0 { deletingTag = nil } })
        ) {
            Button("Etiketi Sil", role: .destructive) {
                guard let tag = deletingTag else { return }
                if selection == .tag(tag) { selection = .readLater }
                store.deleteTag(tag)
            }
        } message: {
            Text("Bağlantılar ve akışlar silinmez, yalnızca bu etiket kaldırılır.")
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { store.showAddSheet = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .help("Ekle (⌘N)")
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await store.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .help("Akışları yenile (⌘R)")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
