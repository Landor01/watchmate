import SwiftUI

struct ProviderNamesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.themeAccent) private var themeAccent
    let providers: [Provider]

    private var providerNames: AttributedString {
        var names = AttributedString()
        for provider in providers {
            if !names.characters.isEmpty {
                names.append(AttributedString(" · "))
            }
            var name = AttributedString(provider.name)
            if store.settings.highlightAvailableServices {
                name.foregroundColor = store.settings.selectedProviders.contains(provider.id)
                    ? themeAccent : Color.secondary
            }
            names.append(name)
        }
        return names
    }

    var body: some View {
        Text(providerNames)
    }
}
