import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var tmdbToken = ""
    @State private var saved = false
    @State private var confirmDisconnect = false
    @State private var confirmDemo = false
    var body: some View {
        @Bindable var settings = store.settings
        Form {
            Section("Your account") {
                Label(store.settings.demoMode ? "Exploring demo data" : store.connected ? "Trakt connected" : "Trakt disconnected",
                      systemImage: store.connected ? "checkmark.circle.fill" : "person.crop.circle")
                if store.connected {
                    Button("Disconnect & clear local viewing data", role: .destructive) { confirmDisconnect = true }.disabled(store.busy)
                } else {
                    Button("Connect Trakt") { Task { await store.connect() } }
                        .disabled(store.busy || store.auth.clientID.isEmpty || !Configuration.callbackConfigured)
                    if !Configuration.callbackConfigured {
                        Text("Live sign-in needs your HTTPS callback domain. Follow README.md in the project.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Load fresh demo data") { confirmDemo = true }.disabled(store.busy)
            }
            Section("Developer credentials") {
                TextField("Trakt client ID", text: $clientID).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(store.connected)
                SecureField("TMDB API Read Access Token", text: $tmdbToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(saved ? "Saved to Keychain" : "Save credentials") {
                    do {
                        try Keychain.write(clientID.trimmingCharacters(in: .whitespacesAndNewlines), key: "trakt.clientID")
                        try Keychain.write(tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines), key: "tmdb.token")
                        saved = true
                    } catch { store.errorMessage = error.localizedDescription }
                }.disabled(store.busy)
                Text("Use the TMDB Read Access Token, not the shorter API key. No Trakt client secret is needed. Credentials stay on this device.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Callback") { Text(Configuration.redirectURI).font(.caption).textSelection(.enabled) }
            }
            Section("Viewing preferences") {
                Picker("Region", selection: $settings.region) {
                    Text("United Kingdom").tag("GB"); Text("United States").tag("US")
                    Text("Ireland").tag("IE"); Text("Canada").tag("CA"); Text("Australia").tag("AU")
                    Text("France").tag("FR"); Text("Germany").tag("DE")
                }.disabled(store.busy)
                Toggle("Include specials", isOn: $settings.includeSpecials)
                Button("Refresh shows now") { Task { await store.refresh() } }.disabled(store.busy)
                if let date = settings.lastSync { LabeledContent("Last viewing sync") { Text(date, style: .relative) } }
            }
            Section("My streaming services") {
                Button("Load services for \(settings.region)") { Task { await store.loadProviders() } }.disabled(store.busy || !store.catalogue.configured)
                ForEach(store.providerOptions) { provider in
                    Toggle(provider.name, isOn: Binding(get: { settings.selectedProviders.contains(provider.id) }, set: { selected in
                        if selected { settings.selectedProviders.insert(provider.id) } else { settings.selectedProviders.remove(provider.id) }
                    }))
                }
                Button("Clear service filter") { settings.selectedProviders = [] }
                Text("Providers come from TMDB for the selected region. Subscription, free and ad-supported offers are included; rental and purchase offers are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Credits & privacy") {
                Image("TMDBLogo").resizable().scaledToFit().frame(width: 100, height: 24).accessibilityLabel("TMDB")
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption)
                Link("The Movie Database (TMDB)", destination: URL(string: "https://www.themoviedb.org")!)
                Text("Streaming availability powered by JustWatch.").font(.caption)
                Link("JustWatch", destination: URL(string: "https://www.justwatch.com")!)
                Link("Trakt", destination: URL(string: "https://trakt.tv")!)
                Text("Viewing data is cached on your device and syncs with your Trakt account. WatchMate has no analytics, advertising or app backend. Requests to Trakt and TMDB are subject to their own privacy policies.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { clientID = Keychain.string("trakt.clientID"); tmdbToken = Keychain.string("tmdb.token") }
            .alert("WatchMate", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onChange(of: settings.region) { _, _ in
                settings.selectedProviders = []; store.providerOptions = []
                Task { await store.refresh(); if store.catalogue.configured { await store.loadProviders() } }
            }
            .onChange(of: settings.includeSpecials) { _, _ in Task { await store.reschedule() } }
            .confirmationDialog("Clear viewing data on this device? Your Trakt history is retained.", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await store.disconnect() } }
            }
            .confirmationDialog("Replace local data with fictional demo shows? Your Trakt history is retained.", isPresented: $confirmDemo, titleVisibility: .visible) {
                Button("Load demo", role: .destructive) { Task { await store.useDemo() } }
            }
    }
}
