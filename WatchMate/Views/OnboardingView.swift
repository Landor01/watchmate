import SwiftUI

struct AppEntryView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("lastSeenAppVersion") private var lastSeenAppVersion = ""

    var body: some View {
        if !hasCompletedOnboarding {
            OnboardingView {
                // New installs get onboarding instead of a second welcome screen.
                lastSeenAppVersion = WhatsNewView.currentVersion
                hasCompletedOnboarding = true
            }
        } else if !WhatsNewView.currentVersion.isEmpty,
                  lastSeenAppVersion != WhatsNewView.currentVersion {
            WhatsNewView(version: WhatsNewView.currentVersionDisplay) {
                // Record acknowledgement, so an interrupted launch shows it again.
                lastSeenAppVersion = WhatsNewView.currentVersion
            }
        } else {
            RootView()
        }
    }
}

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @State private var showDemoMessage = false
    @State private var signingIn = false
    @AppStorage("onboardingStarted") private var onboardingStarted = false
    @AppStorage("onboardingAccountChosen") private var accountChosen = false
    let onComplete: () -> Void

    private var signInUnavailable: Bool {
        store.auth.clientID.isEmpty || !Configuration.callbackConfigured
    }

    var body: some View {
        NavigationStack {
            if accountChosen {
                OnboardingPreferencesView(onComplete: onComplete)
            } else {
                ScrollView {
                    VStack(spacing: 28) {
                        OnboardingIntroduction()
                        VStack(spacing: 16) {
                            Button {
                                signingIn = true
                            } label: {
                                Text("Sign in or create a Trakt account")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(signInUnavailable || signingIn || store.busy)
    
                            Button {
                                showDemoMessage = true
                            } label: {
                                Text("Explore demo mode")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(signingIn || store.busy)
    
                            if signingIn {
                                ProgressView("Connecting to Trakt and loading your shows…")
                            }
                            if signInUnavailable {
                                Text("Trakt sign-in is unavailable in this version of WatchMate. You can still explore demo mode.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .controlSize(.large)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle("Welcome")
                .alert("Explore with sample shows", isPresented: $showDemoMessage) {
                    Button("Continue in demo mode") {
                        store.settings.demoMode = true
                        accountChosen = true
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Demo mode shows fictional sample data. To see your own shows and viewing history, sign in to Trakt in Settings.")
                }
                .alert("Trakt sign-in", isPresented: Binding(
                    get: { !signingIn && store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )) {
                    Button("OK") { store.errorMessage = nil }
                } message: {
                    Text(store.errorMessage ?? "")
                }
                .task(id: signingIn) {
                    guard signingIn else { return }
                    store.errorMessage = nil
                    await store.connect()
                    signingIn = false
                    // Continue setup only after authentication succeeds.
                    if store.connected && !store.settings.demoMode {
                        accountChosen = true
                    }
                }
            }
        }
        .onAppear {
            onboardingStarted = true
            if store.connected && !store.settings.demoMode {
                accountChosen = true
            }
        }
    }
}

private struct OnboardingIntroduction: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Welcome to WatchMate")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Keep track of your shows and discover what to watch next.")
                .foregroundStyle(.secondary)
            Text("Connect your Trakt account, or create one on the Trakt sign-in page. Then choose your viewing preferences and streaming services. You can also explore with sample shows in demo mode.")
        }
    }
}


private struct OnboardingPreferencesView: View {
    @Environment(AppStore.self) private var store
    @State private var finishing = false
    let onComplete: () -> Void

    var body: some View {
        @Bindable var settings = store.settings
        ThemedForm {
            Section {
                Text("Choose how you watch")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Set your region and choose your streaming services. You can change these choices later in Settings.")
                    .foregroundStyle(.secondary)
            }
            Section("Viewing preferences") {
                StreamingRegionPicker()
                Toggle("Include specials", isOn: $settings.includeSpecials)
            }
            OnboardingServicesSection()
            Section {
                Button {
                    finishing = true
                } label: {
                    Text("Start watching")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if finishing {
                    ProgressView("Applying your preferences…")
                }
            } footer: {
                Text("No streaming services? You can continue without selecting any and see all your shows.")
            }
        }
        .disabled(finishing || store.busy)
        .navigationTitle("Set up WatchMate")
        .task(id: finishing) {
            guard finishing else { return }
            if settings.selectedProviders.isEmpty {
                settings.onlyMyServices = false
            }
            // Refresh regional availability even if sign-in just imported the library.
            if store.connected && !settings.demoMode {
                settings.lastSync = nil
                await store.refresh(syncCloudFirst: false)
            } else {
                await store.reschedule()
            }
            guard !Task.isCancelled else { return }
            onComplete()
        }
    }
}

private struct OnboardingServicesSection: View {
    @Environment(AppStore.self) private var store
    @State private var providers: [Provider] = []
    @State private var loadedRegion: String?
    @State private var loading = true
    @State private var loadError: String?
    @State private var retryCount = 0

    var body: some View {
        @Bindable var settings = store.settings
        Section {
            if loading || loadedRegion != settings.region {
                ProgressView("Loading streaming services…")
            } else if let loadError {
                Text(loadError)
                    .foregroundStyle(.secondary)
                Button("Retry loading services") { retryCount += 1 }
                Text("You can continue and choose your services later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if providers.isEmpty {
                Text("No streaming services are listed for this region.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providers) { provider in
                    Toggle(provider.name, isOn: Binding(
                        get: { settings.selectedProviders.contains(provider.id) },
                        set: { selected in
                            if selected {
                                settings.selectedProviders.insert(provider.id)
                            } else {
                                settings.selectedProviders.remove(provider.id)
                                if settings.selectedProviders.isEmpty {
                                    settings.onlyMyServices = false
                                }
                            }
                        }
                    ))
                }
            }
            Toggle("Filter to my services", isOn: $settings.onlyMyServices)
                .disabled(settings.selectedProviders.isEmpty)
        } header: {
            Text("My streaming services")
        } footer: {
            Text("Select the services you use. Filtering applies to Up Next, Coming Soon, My Shows and Search. Availability is supplied by TMDB for your region.")
        }
        .task(id: settings.region + "|" + String(retryCount)) {
            let region = settings.region
            loading = true
            loadError = nil
            providers = []
            do {
                let available = try await store.catalogue.providers(region: region)
                try Task.checkCancellation()
                guard settings.region == region else { return }
                providers = available
            } catch {
                guard !Task.isCancelled, settings.region == region else { return }
                loadError = error.localizedDescription
            }
            loadedRegion = region
            loading = false
        }
    }
}
