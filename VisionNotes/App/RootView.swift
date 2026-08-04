import SwiftUI

struct RootView: View {
    enum Tab: Hashable {
        case library
        case importSources
        case academic
        case search
    }

    let storeWarning: String?

    @State private var selectedTab: Tab = .library
    @State private var showsStoreWarning: Bool

    init(storeWarning: String?) {
        self.storeWarning = storeWarning
        _showsStoreWarning = State(initialValue: storeWarning != nil)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(onImportRequested: { selectedTab = .importSources })
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(Tab.library)

            ImportView()
                .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
                .tag(Tab.importSources)

            MathNotesView()
                .tabItem { Label("Academic", systemImage: "function") }
                .tag(Tab.academic)

            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
        }
        .tint(Theme.accent)
        .alert("Storage problem", isPresented: $showsStoreWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storeWarning ?? "")
        }
    }
}

#Preview {
    RootView(storeWarning: nil)
        .modelContainer(ModelContainerProvider.makeContainer(inMemory: true).container)
}
