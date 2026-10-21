import SwiftUI
import SwiftData
import CloudKit

enum PreviewEnvironment {
    static var isRunning: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #else
        false
        #endif
    }

    static func prepareDefaults() {
        guard isRunning else { return }
        var values = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        values.merge([
            "demoMode": true, "region": "GB", "specials": false,
            "providers": [8, 337, 350], "hidden": [Int](),
            "onlyMyServices": false, "comingSoonCalendar": true,
            "hasCompletedOnboarding": false, "onboardingStarted": false,
            "onboardingAccountChosen": false
        ]) { _, preview in preview }
        UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    }

    static let providers = [
        Provider(id: 350, name: "Apple TV+"),
        Provider(id: 337, name: "Disney+"),
        Provider(id: 8, name: "Netflix")
    ]
}

#if DEBUG
/// Each canvas owns a fresh library, so edits never reach the app's database.
@MainActor
final class PreviewData {
    let container: ModelContainer
    let store: AppStore
    let tips: TipStore
    let show: Show
    let episode: Episode
    let list: HouseholdList
    let programme: SharedProgramme

    var sharedRow: SharedEpisodeProgress {
        SharedEpisodeProgress(episode: remoteEpisode, watchedAt: nil, skipped: false)
    }
    var sharedSeason: SharedSeasonProgress {
        SharedSeasonProgress(id: 1, episodes: [sharedRow])
    }
    var sharedProgress: SharedProgrammeProgress {
        SharedProgrammeProgress(episodes: [remoteEpisode], programme: programme, includeSpecials: false)
    }
    var remoteShow: RemoteShow { programme.show }
    var remoteEpisode: RemoteEpisode {
        RemoteEpisode(season: episode.season, number: episode.number, title: episode.title,
                      ids: IDs(trakt: episode.traktID, tmdb: nil), overview: episode.overview,
                      firstAired: episode.firstAired?.ISO8601Format(), runtime: episode.runtime)
    }
    var details: CatalogueDetails {
        CatalogueDetails(overview: show.overview, posterPath: show.posterPath,
                         providers: show.providers, watchURL: nil)
    }

    init() throws {
        PreviewEnvironment.prepareDefaults()
        container = try ModelContainer(for: Show.self, Episode.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        try DemoLibrary.seed(in: container.mainContext)
        let shows = try container.mainContext.fetch(Show.withEpisodes)
        guard let sample = shows.first(where: { $0.title == "Severance" }),
              let next = sample.episodes.sorted(by: { $0.number < $1.number }).first(where: { $0.watchedAt == nil }) else {
            throw APIError.message("The preview library is missing its sample episode.")
        }
        show = sample
        episode = next
        for show in shows { show.catalogueUpdatedAt = DemoLibrary.calendarDate }
        store = AppStore(context: container.mainContext, settings: Settings())
        store.providerOptions = PreviewEnvironment.providers
        tips = TipStore()
        programme = SharedProgramme(
            show: RemoteShow(title: sample.title, year: 2022, ids: IDs(trakt: sample.traktID, tmdb: nil)),
            addedBy: "preview",
            episodes: sample.episodes.compactMap { episode in
                episode.watchedAt.map { SharedEpisode(id: episode.traktID, season: episode.season,
                                                     number: episode.number, watchedAt: $0) }
            })
        list = HouseholdList(zoneID: CKRecordZone.ID(zoneName: "preview", ownerName: CKCurrentUserDefaultName),
                             name: "Friday night TV", shared: false, programmes: [programme])
        store.sharedHistoryImport.preview = SharedHistoryPreview(
            programme: programme, accountID: "preview",
            changes: programme.episodes.map { SharedHistoryChange(episode: $0, watched: true) },
            existingCount: 0)
        store.sharedShows.preparePreview(lists: [
            list,
            HouseholdList(zoneID: CKRecordZone.ID(zoneName: "preview-family", ownerName: CKCurrentUserDefaultName),
                          name: "Family favourites", shared: false, programmes: [])
        ])
    }
}

struct PreviewHost<Content: View>: View {
    @State private var data: Result<PreviewData, Error>
    private let content: (PreviewData) -> Content

    init(@ViewBuilder content: @escaping (PreviewData) -> Content) {
        _data = State(initialValue: Result { try PreviewData() })
        self.content = content
    }

    var body: some View {
        switch data {
        case .success(let data):
            content(data)
                .environment(data.store)
                .environment(data.tips)
                .modelContainer(data.container)
                .modifier(AppAppearanceModifier())
        case .failure(let error):
            ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(error.localizedDescription))
        }
    }
}
#endif
