import SwiftUI

/// Episode still, then season poster, then programme poster.
struct EpisodeArtworkView: View {
    @Environment(AppStore.self) private var store
    let show: Show
    let episode: Episode
    var width: CGFloat = 96
    var squareCrop = false
    var adaptsToImage = false
    @State private var paths: [String] = []

    private var artworkID: String {
        "\(show.tmdbID ?? 0):\(episode.season):\(episode.number)"
    }

    var body: some View {
        FallbackArtworkView(
            paths: paths + [show.posterPath].compactMap { $0 },
            width: width,
            height: squareCrop ? width : width * 9 / 16,
            contentMode: squareCrop ? .fill : .fit,
            adaptsToImage: adaptsToImage
        )
        .task(id: artworkID) {
            paths = []
            guard let tmdbID = show.tmdbID, store.catalogue.configured else { return }
            do {
                let artwork = try await store.catalogue.episodeArtwork(
                    tmdbID: tmdbID, season: episode.season, episode: episode.number
                )
                try Task.checkCancellation()
                paths = artwork
            } catch {
                // The season catalogue can still supply a poster if episode metadata is unavailable.
                guard !Task.isCancelled else { return }
                if let posters = try? await store.catalogue.seasonPosters(tmdbID: tmdbID),
                   !Task.isCancelled, let poster = posters[episode.season] {
                    paths = [poster]
                }
            }
        }
    }
}

/// Also advances to the next image if an artwork URL fails to load.
struct FallbackArtworkView: View {
    let paths: [String]
    let width: CGFloat
    let height: CGFloat
    var contentMode: ContentMode = .fit
    var adaptsToImage = false
    @State private var failedPaths: Set<String> = []

    var body: some View {
        let path = paths.first { !$0.isEmpty && !failedPaths.contains($0) }
        ZStack {
            if !adaptsToImage {
                LinearGradient(colors: [.teal.opacity(0.75), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            if let path, let url = URL(string: "https://image.tmdb.org/t/p/w342\(path)") {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: contentMode)
                            .frame(width: width, height: adaptsToImage ? nil : height)
                    case .failure:
                        placeholder
                            .task(id: path) { failedPaths.insert(path) }
                    default:
                        placeholder
                    }
                }
                .id(path)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: adaptsToImage ? nil : height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .onChange(of: paths) { _, _ in failedPaths = [] }
    }

    private var placeholder: some View {
        Image(systemName: "tv.fill")
            .foregroundStyle(.white)
            .frame(width: width, height: height)
            .background {
                LinearGradient(colors: [.teal.opacity(0.75), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
    }
}
