import SwiftUI

struct StreamingRegionPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.locale) private var locale
    @AppStorage("streamingRegionCodes") private var cachedCodes = ""
    @State private var regions: [String] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var retryCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Region", selection: Binding(
                get: { store.settings.region },
                set: { region in
                    guard region != store.settings.region else { return }
                    store.settings.selectedProviders = []
                    store.settings.highlightAvailableServices = false
                    store.providerOptions = []
                    store.settings.region = region
                }
            )) {
                // Keep the saved selection valid while loading or when offline.
                if !regions.contains(store.settings.region) {
                    Text(locale.localizedString(forRegionCode: store.settings.region) ?? store.settings.region)
                        .tag(store.settings.region)
                }
                ForEach(regions, id: \.self) { code in
                    Text(locale.localizedString(forRegionCode: code) ?? code)
                        .tag(code)
                }
            }
            .disabled(store.busy)
            if loading {
                ProgressView("Loading regions…")
                    .font(.caption)
            }
            if let loadError {
                Text("Could not update regions. You can use your saved selection or retry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Retry loading regions") { retryCount += 1 }
                    .font(.caption)
            }
        }
        .task(id: locale.identifier + "|" + String(retryCount)) {
            loading = true
            loadError = nil
            regions = sortedRegions(cachedCodes.split(separator: ",").map(String.init))
            do {
                let codes = try await store.catalogue.availableRegions()
                try Task.checkCancellation()
                guard !codes.isEmpty else {
                    throw APIError.message("No streaming regions were returned. Please try again.")
                }
                cachedCodes = codes.joined(separator: ",")
                regions = sortedRegions(codes)
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
            loading = false
        }
    }

    private func sortedRegions(_ codes: [String]) -> [String] {
        codes.sorted {
            let first = locale.localizedString(forRegionCode: $0) ?? $0
            let second = locale.localizedString(forRegionCode: $1) ?? $1
            return first.compare(second, locale: locale) == .orderedAscending
        }
    }
}

#if DEBUG

#Preview("Streaming region") {
    PreviewHost { data in
        Form { StreamingRegionPicker() }
    }
}
#endif
