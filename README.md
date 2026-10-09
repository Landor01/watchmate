# WatchMate

A native iPhone app for seeing what to watch next across your followed TV programmes. Built with SwiftUI, SwiftData, Trakt and TMDB. No third-party Swift packages and no project generator are required.

## Open it when you get home

1. Clone this repository, or unzip the supplied project.
2. Open **WatchMate.xcodeproj** in **Xcode 16 or later**.
3. Select the **WatchMate** scheme and an **iPhone simulator running iOS 18 or later**.
4. Press **Run (⌘R)**. WatchMate opens in demo mode without API keys, a server or an Apple developer team.

The three demo programmes are fictional. Their viewing history and dates are sample data. Try marking episodes watched, skipping episodes and browsing Coming Soon. Settings → Load fresh demo data resets the demo.

For a physical iPhone, choose your Apple signing team and a unique bundle identifier in Signing & Capabilities. The app targets iPhone; iPad layout is not part of this starter.

## Included

- **Up Next**: earliest aired, unwatched episode per show and the total waiting; optional filter to your streaming services.
- **Coming Soon**: scheduled episodes over the next 30 days.
- **My Shows**: programmes, per-episode history and progress.
- **Search**: search Trakt and add a programme to your Trakt watchlist.
- **Show detail**: mark watched/unwatched, skip locally, hide locally, provider links and opt-in local reminders.
- **Settings**: OAuth connection, Keychain credentials, region, providers, specials, demo reset and credits.
- Trakt Authorization Code + **S256 PKCE**, HTTPS callback matching, OAuth state validation and single-flight refresh token rotation.
- Paginated history/watchlist import. Watched imports explicitly use `extended=progress` for Trakt's current response format.
- Local SwiftData cache. Existing data renders before a foreground refresh.
- Metadata/provider cache, GET rate-limit retries, write throttling, error messages and cancellation-aware search.
- App icon, privacy manifest, shared Xcode scheme, XCTest cases and a GitHub Actions macOS build/test workflow.

## Connect your actual shows

### 1. Register a Trakt API application

Use [Trakt's application registration guide](https://developer.trakt.tv/docs/create-an-app). Obtain the **client ID**. WatchMate never uses or embeds a client secret.

### 2. Set up an HTTPS callback you own

Trakt's current [PKCE guidance](https://developer.trakt.tv/docs/pkce) requires HTTPS callbacks backed by Universal Links on iOS. The earlier custom-scheme design is intentionally not used here.

Use a domain such as `auth.yourdomain.com`. Register this exact redirect URI in your Trakt app:

```
https://auth.yourdomain.com/oauth/trakt
```

Copy `Configuration/Local.xcconfig.example` to `Configuration/Local.xcconfig`. Set `OAUTH_HOST` to the host only, your `DEVELOPMENT_TEAM`, and enable the supplied `CODE_SIGN_ENTITLEMENTS` entry. This private configuration is ignored by Git.

In Xcode, set the WatchMate app target's unique bundle ID. Verify that Signing & Capabilities includes Associated Domains with `applinks:auth.yourdomain.com`. A provisioning profile with Associated Domains support is needed for this live configuration.

Serve the contents of `Web/apple-app-site-association.example.json` at:

```
https://auth.yourdomain.com/.well-known/apple-app-site-association
```

Replace the example app ID with your Apple application identifier prefix (usually your team ID) and your exact bundle identifier. Serve the file without a `.json` extension, with `Content-Type: application/json`, and without redirects. Serve `Web/oauth-callback.html` at `/oauth/trakt` as a fallback page; it must not log or display OAuth query parameters. No token exchange server is required.

Apple's [Associated Domains documentation](https://developer.apple.com/documentation/xcode/supporting-associated-domains) explains hosting and signing. Apple caches domain associations; allow propagation and verify on a physical device before TestFlight. Merely changing the host in Settings cannot establish ownership of that domain.

### 3. Obtain a TMDB token

Create a [TMDB developer API application](https://developer.themoviedb.org/docs/getting-started). Copy the **API Read Access Token** (the long bearer token, not the shorter v3 API key).

### 4. Enter credentials in WatchMate

Run the app, open Settings, enter the Trakt client ID and TMDB Read Access Token, and tap **Save credentials**. Tap **Connect Trakt** and authorise WatchMate. A successful connection clears fictional demo viewing data and imports your watched programmes plus watchlist.

Trakt can work without TMDB; posters, descriptions and provider listings will be absent until you add a TMDB token and refresh. Choose your region and load/select streaming providers in Settings.

User tokens and API credentials are stored in the device Keychain. Do not commit real credentials. Disconnect clears the local viewing cache and tokens, while retaining the developer credentials and your remote Trakt data. You can revoke the application separately through your Trakt account.

## What “Up Next” means

The algorithm selects the **set** of episodes that:

1. Have not been watched.
2. Have not been skipped locally.
3. Have a known first-air timestamp at or before the current time.
4. Are not specials unless the user includes specials.

It sorts that set by season and episode number. Gaps in viewing history are retained, and a complete-season release counts all qualifying unwatched episodes. Rewatches count as watched rather than starting an automatic new viewing cycle. Trakt progress resets are not yet supported.

**An air date is not proof of UK streaming availability.** TMDB provider listings are at series level, may be stale and do not identify which seasons/episodes are available. WatchMate labels these as aired episodes, displays providers separately and links to the supplied TMDB “where to watch” page. It does not promise that a particular episode is available or link straight into playback.

## Refresh and persistence

- Opening/foregrounding the app displays cached data and refreshes viewing data if the last complete sync is more than 15 minutes old.
- Pull-to-refresh retrieves a full paginated watched snapshot and watchlist. This first version prioritises straightforward correctness over delta sync; `/sync/last_activities` optimisation is a future improvement.
- Trakt episode catalogues refresh after 6 hours; TMDB metadata/providers after 24 hours or a region change.
- Cached viewing state remains if requests fail; partial failures are reported. A complete viewing sync timestamp is recorded only when all show episode updates succeed.
- Watch/unwatch writes are confirmed by Trakt before changing local state. There is no offline mutation queue; failed writes show an error and should be retried after reconnecting.
- An unfollow/hide action affects WatchMate only and preserves Trakt's history/watchlist. A later Follow action restores the show. Removed API catalogue entries are deleted on catalogue refresh.
- One account per device. Reconnecting clears the old account cache so viewing histories are not mixed.

## Reminders

Enable reminders per show. They are local notifications based on known future first-air timestamps, **not verified streaming-release notifications**. The app rebuilds the nearest 60 notifications after refresh/preferences changes. Dates can change, and new episodes won't generate notifications until WatchMate next refreshes. Demo mode never schedules notifications.

Reliable “available on your streaming service now” pushes would need stronger episode availability data and a backend/APNs integration. Neither is part of this version.

## Architecture

| Folder | Responsibility |
| --- | --- |
| `Models` | SwiftData programme/episode models, provider values, remote DTOs and pure episode rules |
| `Services` | HTTP transport, Trakt OAuth/API, TMDB metadata, synchronization and notifications |
| `Support` | Keychain, device preferences and callback configuration |
| `Views` | Four tabs, programme details, settings and reusable artwork/rows |
| `WatchMateTests` | Episode edge cases, response decoding and token expiry |
| `Web` | Universal Link association and callback-page examples; these need hosting on your domain |

`ViewingService` and `CatalogueService` define the service boundaries. Models store external identifiers and app concepts. Catalogue-provider replacement can be implemented behind the catalogue protocol; the current composition wires the Trakt/TMDB implementations.

## Tests and build

In Xcode choose **Product → Test (⌘U)**. The shared WatchMate scheme includes the tests.

From a Mac terminal:

```bash
xcodebuild test -project WatchMate.xcodeproj -scheme WatchMate \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

Use a simulator name available on your Mac. The GitHub Actions workflow selects an available iPhone automatically and builds/tests without signing.

**Validation during creation:** all Swift files passed a Swift syntax parser; the Xcode project parsed successfully, and property lists, schemes, JSON and workflow YAML were checked. An actual Xcode build and XCTest execution have **not** run in the creation environment, which has no macOS/Xcode. Live OAuth/API integration also needs your registered credentials and callback domain before testing.

## Before an App Store release

This is an implementation starter, not an already approved production app. Complete simulator/device/TestFlight testing and accessibility review, update the bundle ID and domain, verify the current API terms for your actual use, and supply your App Store privacy disclosures/privacy-policy URL. Review the included privacy manifest against the final app and its APIs.

The [approved TMDB logo](https://www.themoviedb.org/about/logos-attribution) and required notice are included in Settings → Credits. The logo is TMDB's trademark and is bundled solely for API attribution. JustWatch attribution is displayed in Settings and programme details. A revenue-generating app needs an appropriate TMDB commercial agreement; a private/TestFlight development build is not itself proof that any planned commercial use is covered. See [TMDB's FAQ](https://developer.themoviedb.org/docs/faq), [TMDB watch-provider requirements](https://developer.themoviedb.org/reference/tv-series-watch-providers), and [Trakt's API use policy](https://developer.trakt.tv/docs/api-use-policy).

No monetisation, direct streaming-service login, analytics, cloud sync, remote push backend or episode-specific streaming availability is implemented.
