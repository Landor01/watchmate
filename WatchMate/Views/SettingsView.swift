import SwiftUI
#if DEBUG
import UIKit
#endif

struct SettingsView: View {
    #if DEBUG
    @Environment(TipStore.self) private var tips
    #endif
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDisconnect = false
    @State private var confirmDemo = false
    @State private var whatsNewOpen = false
    var body: some View {
        @Bindable var settings = store.settings
        ThemedForm {
            ProfilePhotoSection()
            Section("About") {
                Button {
                    whatsNewOpen = true
                } label: {
                    HStack {
                        Text("What’s New")
                        Spacer()
                        Text(WhatsNewView.currentVersionDisplay)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                NavigationLink("Help") {
                    HelpView()
                }
            }
            AppearanceSettingsSection()
            Section("Trakt account") {
                Label(store.settings.demoMode ? "Exploring demo data" : store.connected ? "Trakt connected" : "Trakt disconnected",
                      systemImage: store.connected ? "checkmark.circle.fill" : "person.crop.circle")
                if store.connected {
                    Button("Disconnect & clear local viewing data", role: .destructive) { confirmDisconnect = true }.disabled(store.busy)
                } else {
                    Button("Connect Trakt") { Task { await store.connect() } }
                        .disabled(store.busy || store.auth.clientID.isEmpty || !Configuration.callbackConfigured)
                    if store.auth.clientID.isEmpty || !Configuration.callbackConfigured {
                        Text("Trakt sign-in is unavailable in this version of WatchMate. Please contact support.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Switch to demo data") { confirmDemo = true }.disabled(store.busy)
            }
            Section("Viewing preferences") {
                StreamingRegionPicker()
                Toggle("Include specials", isOn: $settings.includeSpecials)
                DeviceRemindersControl()
                if let date = settings.lastSync { LabeledContent("Last viewing sync") { Text(date, style: .relative) } }
            }
            Section("My streaming services") {
                NavigationLink {
                    StreamingServicesView()
                } label: {
                    LabeledContent("Choose streaming services") {
                        Text("\(settings.selectedProviders.count) selected")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Highlight available services", isOn: $settings.highlightAvailableServices)
                    .disabled(settings.selectedProviders.isEmpty && !settings.highlightAvailableServices)
                Text("Shows all streaming services in your region, with your selected services in the highlight colour. Applies to programme lists, Search and detail views.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if TipStore.isEnabled {
                CoffeeTipSection()
            }
            Section("iCloud sync") {
                if store.cloud.syncing {
                    ProgressView("Syncing with iCloud…")
                } else {
                    Text(store.cloud.status)
                }
                if let date = store.cloud.lastSync {
                    LabeledContent("Last iCloud sync") { Text(date, style: .relative) }
                }
                if store.cloud.pendingCount > 0 {
                    Text("\(store.cloud.pendingCount) changes waiting to sync")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Sync now") { Task { await store.refresh() } }
                    .disabled(store.busy || !store.connected || store.settings.demoMode)
                Text("Use the same Apple Account and Trakt account on each device. Your profile photo, skips, followed and hidden shows, reminder choices and viewing preferences sync through your private iCloud storage. Watched history syncs through Trakt. Demo data and sign-in credentials stay on this device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Credits & privacy") {
                Image("TMDBLogo").resizable().scaledToFit().frame(width: 100, height: 24).accessibilityLabel("TMDB")
                Text("This product uses the TMDB API but is not endorsed or certified by TMDB.").font(.caption)
                Link("The Movie Database (TMDB)", destination: URL(string: "https://www.themoviedb.org")!)
                Text("Streaming availability powered by JustWatch.").font(.caption)
                Link("JustWatch", destination: URL(string: "https://www.justwatch.com")!)
                Link("Trakt", destination: URL(string: "https://trakt.tv")!)
                Text("Viewing data is cached on your device and syncs with Trakt. WatchMate preferences also sync through your private iCloud storage. WatchMate has no analytics, advertising or app backend. Requests to Apple, Trakt and TMDB are subject to their privacy policies.").font(.caption).foregroundStyle(.secondary)
            }
            #if DEBUG
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Trakt client ID").font(.headline)
                    if Configuration.traktClientID.isEmpty {
                        Text("Not configured").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: Configuration.traktClientID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Copy Trakt client ID", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = Configuration.traktClientID
                    }
                    .disabled(Configuration.traktClientID.isEmpty)
                    DebugConnectionTestButton(title: "Test Trakt connection") {
                        try await TraktService(auth: store.auth).testConnection()
                    }
                    .disabled(Configuration.traktClientID.isEmpty || store.busy)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("TMDB Read Access Token").font(.headline)
                    if Configuration.tmdbReadAccessToken.isEmpty {
                        Text("Not configured").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: Configuration.tmdbReadAccessToken)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("Copy TMDB token", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = Configuration.tmdbReadAccessToken
                    }
                    .disabled(Configuration.tmdbReadAccessToken.isEmpty)
                    DebugConnectionTestButton(title: "Test TMDB connection") {
                        try await store.catalogue.testConnection()
                    }
                    .disabled(Configuration.tmdbReadAccessToken.isEmpty)
                }
                if !tips.productDiagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tip purchase diagnostics").font(.headline)
                        Text(verbatim: tips.productDiagnostics)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Debug")
            } footer: {
                Text("App credentials are read-only values bundled from the build configuration.")
            }
            #endif
        }.navigationTitle("Settings").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("WatchMate", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .sheet(isPresented: $whatsNewOpen) {
                WhatsNewView(
                    version: WhatsNewView.currentVersionDisplay,
                    dismissButtonTitle: "Done",
                    onDismiss: { whatsNewOpen = false }
                )
                .modifier(AppAppearanceModifier())
            }
            .onChange(of: settings.region) { _, _ in
                guard !store.busy else { return }
                Task { await store.refresh(); if store.catalogue.configured { await store.loadProviders() } }
            }
            .onChange(of: settings.includeSpecials) { _, _ in Task { await store.reschedule() } }
            .confirmationDialog("Clear viewing data on this device? Your Trakt history and iCloud data are retained.", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await store.disconnect() } }
            }
            .confirmationDialog("Replace local data with fictional demo shows? Your Trakt history and iCloud data are retained.", isPresented: $confirmDemo, titleVisibility: .visible) {
                Button("Switch to demo data", role: .destructive) { Task { await store.useDemo() } }
            }
    }
}

private struct DeviceRemindersControl: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("deviceRemindersEnabled") private var deviceRemindersEnabled = true
    @State private var permissionGranted = false
    @State private var checkingPermission = true
    @State private var updating = false

    private var remindersEnabled: Bool {
        deviceRemindersEnabled && permissionGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                updating = true
            } label: {
                if remindersEnabled {
                    Text("Disable reminders on this device")
                } else {
                    Text("Enable reminders on this device")
                }
            }
            .disabled(checkingPermission || updating || store.busy || store.settings.demoMode)
            if updating {
                ProgressView("Updating reminders…")
            }
            Text("Controls reminders on this device for shows you have enabled. Your per-show reminder choices are kept when reminders are disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            checkingPermission = true
            permissionGranted = await Notifications.hasPermission()
            checkingPermission = false
        }
        .task(id: updating) {
            guard updating else { return }
            defer { updating = false }
            do {
                if remindersEnabled {
                    deviceRemindersEnabled = false
                } else {
                    guard try await Notifications.requestPermission() else {
                        permissionGranted = false
                        throw APIError.message("Enable notifications for WatchMate in device Settings.")
                    }
                    permissionGranted = true
                    deviceRemindersEnabled = true
                }
                await store.reschedule()
            } catch {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}

#if DEBUG
private struct DebugConnectionTestButton: View {
    let title: LocalizedStringKey
    let test: @MainActor () async throws -> String
    @State private var testing = false
    @State private var result: String?
    @State private var succeeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(title, systemImage: "network") {
                result = nil
                testing = true
            }
            .disabled(testing)
            if testing {
                ProgressView("Testing connection…")
                    .font(.caption)
            }
            if let result {
                Label(result, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(succeeded ? Color.green : Color.red)
                    .textSelection(.enabled)
            }
        }
        .task(id: testing) {
            guard testing else { return }
            defer { testing = false }
            do {
                let message = try await test()
                try Task.checkCancellation()
                succeeded = true
                result = message
            } catch {
                guard !Task.isCancelled else { return }
                succeeded = false
                result = "Connection failed: \(error.localizedDescription)"
            }
        }
    }
}
#endif
