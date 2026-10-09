import SwiftUI

struct SearchView: View {
    @Environment(AppStore.self) private var store
    @State private var query = ""
    @State private var results: [RemoteShow] = []
    @State private var searching = false
    @State private var message: String?
    var body: some View {
        List {
            if store.settings.demoMode {
                ContentUnavailableView("Connect to discover shows", systemImage: "magnifyingglass", description: Text("Search uses Trakt. Connect your account in Settings to add real programmes."))
            } else if !store.connected {
                ContentUnavailableView("Connect Trakt first", systemImage: "person.crop.circle", description: Text("Open Settings to sign in."))
            } else {
                if searching { ProgressView("Searching…") }
                if let message { Text(message).foregroundStyle(.secondary) }
                if !searching && results.isEmpty && query.count >= 2 && message == nil { Text("No shows found.").foregroundStyle(.secondary) }
                ForEach(results) { show in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(show.title).font(.headline)
                            if let year = show.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button("Follow", systemImage: "plus") { Task { await store.follow(show) } }
                            .buttonStyle(.bordered).disabled(store.busy)
                    }
                }
            }
        }.navigationTitle("Search")
            .searchable(text: $query, prompt: "Search TV programmes")
            .task(id: query) {
                results = []; message = nil; searching = false
                guard query.trimmingCharacters(in: .whitespaces).count >= 2 && !store.settings.demoMode && store.connected else { return }
                do {
                    try await Task.sleep(for: .milliseconds(400)); searching = true
                    let found = try await TraktService(auth: store.auth).search(query)
                    try Task.checkCancellation(); results = found; searching = false
                } catch is CancellationError { }
                catch { if !Task.isCancelled { message = error.localizedDescription; searching = false } }
            }
    }
}
