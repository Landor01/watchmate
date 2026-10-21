import SwiftUI

struct ProviderNamesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.themeAccent) private var themeAccent
    let providers: [Provider]

    var body: some View {
        if store.settings.highlightAvailableServices && !store.settings.selectedProviders.isEmpty {
            let yourServices = providers.filter { store.settings.selectedProviders.contains($0.id) }
            let otherServices = providers.filter { !store.settings.selectedProviders.contains($0.id) }

            VStack(alignment: .leading, spacing: 6) {
                if !yourServices.isEmpty {
                    providerGroup("Your Services", providers: yourServices, color: themeAccent)
                }
                if !otherServices.isEmpty {
                    providerGroup(
                        yourServices.isEmpty ? "Available On" : "Also Available On",
                        providers: otherServices,
                        color: .primary
                    )
                }
            }
        } else {
            providerNames(providers)
        }
    }

    private func providerGroup(_ title: LocalizedStringKey, providers: [Provider], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            providerNames(providers)
                .foregroundStyle(color)
        }
    }

    private func providerNames(_ providers: [Provider]) -> some View {
        Text(providers.map(\.name).joined(separator: " · "))
            .accessibilityLabel(providers.map(\.name).formatted(.list(type: .and)))
    }
}

#if DEBUG

#Preview("Providers") {
    PreviewHost { data in
        ProviderNamesView(providers: PreviewEnvironment.providers).padding()
    }
}
#endif
