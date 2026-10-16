import SwiftUI

struct StreamingServicesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.locale) private var locale
    @State private var providers: [Provider] = []
    @State private var loading = true
    @State private var loadedRegion: String?
    @State private var loadError: String?
    @State private var retryCount = 0

    var body: some View {
        ThemedForm {
            Section {
                if loading || loadedRegion != store.settings.region {
                    ProgressView("Loading streaming services…")
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(.secondary)
                    Button("Retry loading services") { retryCount += 1 }
                } else if providers.isEmpty {
                    Text("No streaming services are listed for this region.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(providers) { provider in
                        Toggle(provider.name, isOn: Binding(
                            get: { store.settings.selectedProviders.contains(provider.id) },
                            set: { selected in
                                if selected {
                                    store.settings.selectedProviders.insert(provider.id)
                                } else {
                                    store.settings.selectedProviders.remove(provider.id)
                                    if store.settings.selectedProviders.isEmpty {
                                        store.settings.onlyMyServices = false
                                    }
                                }
                            }
                        ))
                    }
                }
            } header: {
                Text(locale.localizedString(forRegionCode: store.settings.region) ?? store.settings.region)
            } footer: {
                Text("Select the services you use. Your choices are saved automatically.")
            }
            Section {
                Button("Clear selections") {
                    store.settings.selectedProviders = []
                    store.settings.onlyMyServices = false
                }
                .disabled(store.settings.selectedProviders.isEmpty)
            } footer: {
                Text("Providers come from TMDB for the selected region. Subscription, free and ad-supported offers are included; rental and purchase offers are excluded.")
            }
        }
        .navigationTitle("Streaming services")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.settings.region + "|" + String(retryCount)) {
            let region = store.settings.region
            loading = true
            loadError = nil
            providers = []
            do {
                let available = try await store.catalogue.providers(region: region)
                try Task.checkCancellation()
                guard store.settings.region == region else { return }
                providers = available
            } catch {
                guard !Task.isCancelled, store.settings.region == region else { return }
                loadError = error.localizedDescription
            }
            loadedRegion = region
            loading = false
        }
    }
}
