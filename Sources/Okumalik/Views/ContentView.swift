import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.undoManager) private var undoManager
    @State private var section: SidebarSection? = .readLater
    @State private var selection = Set<DetailID>()
    @State private var search = ""
    @State private var newTag = ""
    /// Which columns show: all, without the sidebar, or the reading pane alone (focus mode).
    @AppStorage("columns") private var columns = "all"

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch columns {
                case "double": .doubleColumn
                case "detail": .detailOnly
                default: .all
                }
            },
            set: { columns = $0 == .detailOnly ? "detail" : $0 == .doubleColumn ? "double" : "all" }
        )
    }

    /// The detail column shows a page only when exactly one row is selected.
    private var single: DetailID? { selection.count == 1 ? selection.first : nil }

    var body: some View {
        split
            .sheet(isPresented: $store.showAddSheet) {
                AddSheet(initialKind: addKind)
            }
            .alert("Yeni Etiket", isPresented: Binding(get: { !store.tagPrompt.isEmpty }, set: { if !$0 { store.tagPrompt = [] } })) {
                TextField("Etiket", text: $newTag)
                Button("Ekle") {
                    if let tag = Store.normalizedTag(newTag) { store.tagPrompt.forEach { store.addTag(tag, to: $0) } }
                    newTag = ""
                }
                Button("Vazgeç", role: .cancel) { newTag = "" }
            }
            .overlay(alignment: .bottom) { toast }
            .onChange(of: section) { selection = [] }
            // A search result opened from Yer İmleri brought the reading pane; back to the plain list.
            .onChange(of: search) { if search.isEmpty, section == .bookmarks { selection = [] } }
            .onChange(of: selection) {
                if case .entry(let id) = single { store.setEntryRead(id, true) }
            }
            .onOpenURL { store.handleOpenURL($0) }
            .onAppear { store.undoManager = undoManager }
            .onChange(of: undoManager) { store.undoManager = undoManager }
            .onReceive(NotificationCenter.default.publisher(for: .okmSearch)) { _ in
                if columns == "detail" { columns = "all" }
            }
            .onReceive(NotificationCenter.default.publisher(for: .okmFocus)) { _ in
                withAnimation { columns = columns == "detail" ? "all" : "detail" }
            }
    }

    /// A row in the list that needs the reading pane: anything but a bookmark.
    private var opensPage: Bool {
        guard let single else { return false }
        if case .item(let id) = single { return store.item(id)?.kind != .bookmark }
        return true
    }

    /// Bookmarks need no preview: their list takes the whole width next to the sidebar.
    @ViewBuilder
    private var split: some View {
        if section == .bookmarks, !opensPage {
            NavigationSplitView(columnVisibility: visibility) {
                sidebar
            } detail: {
                ItemListView(section: .bookmarks, selection: $selection, search: $search)
            }
        } else {
            NavigationSplitView(columnVisibility: visibility) {
                sidebar
            } content: {
                ItemListView(section: section ?? .readLater, selection: $selection, search: $search)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 480)
            } detail: {
                DetailView(selection: single)
            }
        }
    }

    private var sidebar: some View {
        SidebarView(selection: $section)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = store.toast {
            HStack(spacing: 14) {
                Text(message.text)
                if let undo = message.undo {
                    Button("Geri Al") { undo() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.okmAccent)
                        .fontWeight(.semibold)
                }
            }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: message.id)
        }
    }

    private var addKind: AddKind {
        switch section {
        case .bookmarks: .bookmark
        case .allFeeds, .feed: .feed
        default: .readLater
        }
    }
}
