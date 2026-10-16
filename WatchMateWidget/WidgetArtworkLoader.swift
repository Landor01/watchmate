import Foundation
import UIKit

/// Widget views cannot rely on AsyncImage; resolve artwork while building the timeline.
actor WidgetArtworkLoader {
    static let shared = WidgetArtworkLoader()

    func image(for show: WidgetShow?, at date: Date) async -> UIImage? {
        guard let show, let episode = show.nextEpisode(at: date) else { return nil }
        let paths = (WidgetArtworkStore.read(for: episode.id)?.paths ?? []) + [show.posterPath].compactMap { $0 }
        for path in paths where path.hasPrefix("/") && !path.contains("..") {
            guard let url = URL(string: "https://image.tmdb.org/t/p/w500\(path)") else { continue }
            do {
                var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      data.count < 5_000_000, let image = UIImage(data: data) else { continue }
                return image
            } catch {
                continue
            }
        }
        return nil
    }
}
