import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.undoManager) private var undoManager
    @State private var section: SidebarSection? = .readLater
    @State private var selection = Set<DetailID>()
    @State private var search = ""
    @State private var newTag = ""
    /// Which columns show: all, or without the sidebar.
    @AppStorage("columns") private var columns = "all"
    /// Focus mode: the page alone, filling the window. macOS can't fold a split view's middle
    /// column, so this is a layout of its own rather than a column setting.
    @State private var focusing = false

    private var visibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch columns {
                case "double": .doubleColumn
                default: .all
                }
            },
            set: { columns = $0 == .all ? "all" : "double" }
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
                if focusing { focusing = false }
            }
            .onReceive(NotificationCenter.default.publisher(for: .okmFocus)) { _ in toggleFocus() }
            // Focus mode is for reading: it ends when there's nothing open, and doesn't outlive the app.
            .onAppear { if columns == "detail" { columns = "all" } }  // left by older versions
            .onChange(of: focusable) { if focusing, !focusable { withAnimation { focusing = false } } }
    }

    /// Focus mode needs a page to show; otherwise hiding the columns would leave an empty window.
    private var focusable: Bool { section != .images && opensPage }

    private func toggleFocus() {
        if focusing {
            withAnimation { focusing = false }
        } else if focusable {
            withAnimation { focusing = true }
        } else {
            store.notify("Odak modu için önce bir yazı açın")
        }
    }

    /// The way out of focus mode, at the top corner of the page; Esc does the same.
    @ViewBuilder
    private var focusExit: some View {
        if focusing {
            Button { toggleFocus() } label: {
                Label("Odaktan Çık", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Odak modundan çık (Esc ya da ⇧⌘F)")
            .padding(12)
            .transition(.opacity)
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
        if focusing, let single {
            DetailView(selection: single)
                .overlay(alignment: .topLeading) { focusExit }
        } else if section == .images {
            NavigationSplitView(columnVisibility: visibility) {
                sidebar
            } detail: {
                ImagesView()
            }
        } else if section == .bookmarks, !opensPage {
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
