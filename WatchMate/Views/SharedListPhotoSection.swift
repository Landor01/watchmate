import SwiftUI
import SwiftData
import PhotosUI
import UIKit
import AVFoundation

/// A single rendition keeps the in-app avatar and Apple's sharing thumbnail consistent.
enum SharedListAvatar {
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first?.first else { return "SS" }
        let last = words.count > 1 ? words.last?.first : nil
        return (String(first) + (last.map(String.init) ?? "")).uppercased()
    }

    @MainActor static func image(name: String, photoData: Data?) -> UIImage {
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: size)
            UIBezierPath(ovalIn: bounds).addClip()
            if let photoData, let photo = UIImage(data: photoData), photo.size.width > 0, photo.size.height > 0 {
                let scale = max(size.width / photo.size.width, size.height / photo.size.height)
                let drawn = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
            } else {
                UIColor(red: 0.40, green: 0.44, blue: 0.50, alpha: 1).setFill()
                UIBezierPath(ovalIn: bounds).fill()
                let text = initials(for: name) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 96, weight: .medium),
                    .foregroundColor: UIColor.white
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                     y: (size.height - textSize.height) / 2), withAttributes: attributes)
            }
        }
    }
}

struct SharedListAvatarView: View {
    let name: String
    let photoData: Data?
    let size: CGFloat

    var body: some View {
        Image(uiImage: SharedListAvatar.image(name: name, photoData: photoData))
            .resizable()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityLabel("Image for \(name)")
    }
}

struct SharedListPhotoSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let list: HouseholdList
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var imageToCrop: ListPhotoSelection?
    @State private var capturedImage: UIImage?
    @State private var showCamera = false
    @State private var cameraDenied = false
    @State private var requestingCamera = false
    @State private var cameraPresentationPending = false
    @State private var saving = false
    @State private var confirmingPhotoRemoval = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            VStack(spacing: 12) {
                SharedListAvatarView(name: list.name, photoData: list.photoData, size: 96)
                    .overlay(alignment: .topTrailing) {
                        if list.photoData != nil {
                            Button { confirmingPhotoRemoval = true } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title2)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.75))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove list photo")
                            .accessibilityHint("Asks for confirmation before replacing the photo with initials.")
                            .offset(x: 12, y: -12)
                            .popover(isPresented: $confirmingPhotoRemoval, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("Remove list photo?").font(.headline)
                                    Text("The photo will be replaced with the list’s initials for everyone on this list.")
                                        .font(.subheadline)
                                    HStack {
                                        Button("Cancel", role: .cancel) { confirmingPhotoRemoval = false }
                                        Spacer()
                                        Button("Remove photo", role: .destructive) {
                                            confirmingPhotoRemoval = false
                                            save(nil)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding()
                                .frame(idealWidth: 300, maxWidth: 340)
                                .presentationCompactAdaptation(.popover)
                            }
                        }
                    }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) { photoControls }
                    VStack(spacing: 12) { photoControls }
                }
                .buttonStyle(.borderless)
                if saving { ProgressView("Saving list photo…") }
                Divider()
                SharedListSummaryView(list: list)
            }
            .frame(maxWidth: .infinity)
            .disabled(saving)
        }
        .task(id: requestingCamera) {
            guard requestingCamera else { return }
            defer { requestingCamera = false }
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard !Task.isCancelled else { return }
            if allowed { cameraPresentationPending = true }
            else { cameraDenied = true }
        }
        .task(id: cameraPresentationPending && scenePhase == .active) {
            guard cameraPresentationPending, scenePhase == .active else { return }
            await Task.yield()
            guard !Task.isCancelled, scenePhase == .active else { return }
            cameraPresentationPending = false
            showCamera = true
        }
        .onDisappear { cameraPresentationPending = false }
        .task(id: selectedPhotoItem) {
            guard let selectedPhotoItem else { return }
            do {
                guard let data = try await selectedPhotoItem.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    throw APIError.message("This photo could not be opened. Please choose another photo.")
                }
                try Task.checkCancellation()
                imageToCrop = ListPhotoSelection(image: image)
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
        .sheet(item: $imageToCrop, onDismiss: { selectedPhotoItem = nil }) { selection in
            CropperView(originalImage: selection.image) { image in
                imageToCrop = nil
                save(image)
            } onCancel: { imageToCrop = nil }
        }
        .fullScreenCover(isPresented: $showCamera, onDismiss: {
            if let image = capturedImage {
                imageToCrop = ListPhotoSelection(image: image)
                capturedImage = nil
            }
        }) {
            CameraCaptureView { image in
                capturedImage = image
                showCamera = false
            } onCancel: { showCamera = false }
            .ignoresSafeArea()
        }
        .alert("Camera access needed", isPresented: $cameraDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Allow camera access in Settings to take a list photo.") }
        .alert("List photo", isPresented: Binding(get: { errorMessage != nil },
                                                set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private var photoControls: some View {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
            Label("Choose Photo", systemImage: "photo")
        }
        Button { requestingCamera = true } label: {
            Label("Take Photo", systemImage: "camera")
        }
        .disabled(requestingCamera || cameraPresentationPending || showCamera || !UIImagePickerController.isSourceTypeAvailable(.camera))
    }

    private func save(_ image: UIImage?) {
        saving = true
        Task {
            defer { saving = false }
            do { try await store.sharedShows.setPhoto(image, for: list) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct SharedListSummaryView: View {
    @Environment(AppStore.self) private var store
    @Query(Show.withEpisodes) private var shows: [Show]
    let list: HouseholdList
    var programme: SharedProgramme? = nil
    private var programmes: [SharedProgramme] { programme.map { [$0] } ?? list.programmes }
    @State private var catalogues: [Int: [RemoteEpisode]] = [:]
    @State private var loading = false
    @State private var failed = false

    private func episodes(for programme: SharedProgramme) -> [RemoteEpisode]? {
        if let show = shows.first(where: { $0.traktID == programme.id }), show.catalogueUpdatedAt != nil {
            return show.episodes.map {
                RemoteEpisode(season: $0.season, number: $0.number, title: $0.title,
                              ids: IDs(trakt: $0.traktID, tmdb: nil), overview: $0.overview,
                              firstAired: $0.firstAired.map { $0.ISO8601Format() }, runtime: $0.runtime)
            }
        }
        return catalogues[programme.id]
    }

    var body: some View {
        let progress = programmes.compactMap { programme in
            episodes(for: programme).map {
                SharedProgrammeProgress(episodes: $0, programme: programme,
                                        includeSpecials: store.settings.includeSpecials)
            }
        }
        let complete = progress.count == programmes.count
        let remaining = progress.reduce(0) { $0 + $1.remainingCount }
        let watchedMinutes = progress.reduce(0) { $0 + $1.watchedMinutes }
        let remainingMinutes = progress.reduce(0) { $0 + $1.remainingMinutes }
        let unknownWatched = progress.reduce(0) { $0 + $1.unknownWatchedRuntimes }
        let unknownRemaining = progress.reduce(0) { $0 + $1.unknownRemainingRuntimes }
        VStack(alignment: .leading, spacing: 8) {
            if programme != nil {
                if complete {
                    Group {
                        if remaining == 0 {
                            Text("Up to date")
                        } else {
                            Text("^[\(remaining) episode](inflect: true) left to watch")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(loading ? "Loading remaining episodes…" : "Remaining episodes unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if complete {
                Text("^[\(remaining) episode](inflect: true) left to watch")
                    .font(.headline).foregroundStyle(.secondary)
                Label("Watched: \(duration(watchedMinutes, unknown: unknownWatched))", systemImage: "clock")
                Label("Left to watch: \(duration(remainingMinutes, unknown: unknownRemaining))", systemImage: "hourglass")
                if unknownWatched + unknownRemaining > 0 {
                    Text("Some runtimes are unavailable; times include known runtimes only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if loading {
                ProgressView("Loading summary…")
            } else {
                Text("Summary unavailable until episode details load.")
                    .foregroundStyle(.secondary)
                if failed {
                    Button("Retry summary") { Task { await loadMissingEpisodes() } }
                        .buttonStyle(.borderless)
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: programmes.map(\.id)) { await loadMissingEpisodes() }
    }

    private func duration(_ minutes: Int, unknown: Int) -> String {
        guard minutes > 0 else { return unknown > 0 ? String(localized: "Unknown") : String(localized: "0 min") }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }

    private func loadMissingEpisodes() async {
        loading = true
        failed = false
        defer { loading = false }
        for programme in programmes where episodes(for: programme) == nil {
            do {
                let episodes = try await TraktService(auth: store.auth).episodes(showID: programme.id)
                try Task.checkCancellation()
                catalogues[programme.id] = episodes
            } catch is CancellationError { return }
            catch { failed = true }
        }
    }
}

private struct ListPhotoSelection: Identifiable {
    let id = UUID()
    let image: UIImage
}
