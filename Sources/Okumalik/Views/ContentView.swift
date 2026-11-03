import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @State private var section: SidebarSection? = .readLater
    @State private var selection: DetailID?
    @State private var search = ""
    @State private var newTag = ""

    var body: some View {
        split
        .searchable(text: $search, placement: .sidebar, prompt: "Ara")
        .sheet(isPresented: $store.showAddSheet) {
            AddSheet(initialKind: addKind, initialTags: currentTag.map { [$0] } ?? [])
        }
        .alert("Yeni Etiket", isPresented: Binding(get: { store.tagPrompt != nil }, set: { if !$0 { store.tagPrompt = nil } })) {
            TextField("Etiket", text: $newTag)
            Button("Ekle") {
                if let target = store.tagPrompt, let tag = Store.normalizedTag(newTag) { store.addTag(tag, to: target) }
                newTag = ""
            }
            Button("Vazgeç", role: .cancel) { newTag = "" }
        }
        .onChange(of: section) { selection = nil }
        .onChange(of: selection) {
            if case .entry(let id) = selection { store.setEntryRead(id, true) }
        }
        .onOpenURL { store.handleOpenURL($0) }
    }

    /// Bookmarks need no preview: their list takes the whole width next to the sidebar.
    @ViewBuilder
    private var split: some View {
        if section == .bookmarks {
            NavigationSplitView {
                sidebar
            } detail: {
                ItemListView(section: .bookmarks, selection: $selection, search: search)
            }
        } else {
            NavigationSplitView {
                sidebar
            } content: {
                ItemListView(section: section ?? .readLater, selection: $selection, search: search)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
            } detail: {
                DetailView(selection: selection)
            }
        }
    }

    private var sidebar: some View {
        SidebarView(selection: $section)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
    }

    private var currentTag: String? {
        if case .tag(let tag) = section { tag } else { nil }
    }

    private var addKind: AddKind {
        switch section {
        case .bookmarks: .bookmark
        case .allFeeds, .feed: .feed
        default: .readLater
        }
    }
}
