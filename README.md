# WatchMate

A native iPhone app for seeing what to watch next across your followed TV programmes. Built with SwiftUI, SwiftData, Trakt and TMDB. No third-party Swift packages and no project generator are required.

## Open it when you get home

1. Clone this repository, or unzip the supplied project.
2. Open **WatchMate.xcodeproj** in **Xcode 27 or later** (the source references iOS 27 APIs behind availability checks).
3. Select the **WatchMate** scheme and an **iPhone simulator running iOS 18 or later**.
4. Press **Run (⌘R)**. WatchMate opens in demo mode without API keys, a server or an Apple developer team.

Demo mode uses real programme information with sample viewing progress and bundled artwork. Try marking episodes watched, skipping episodes and browsing Coming Soon. Settings → Switch to demo data resets the demo.

For a physical device, choose your Apple signing team and verify the bundle identifiers and capabilities in Signing & Capabilities. The app targets iPhone and iPad; both need release testing.

## Included

- **Up Next**: earliest aired, unwatched episode per show and the total waiting; optional filter to your streaming services.
- **Coming Soon**: scheduled episodes over the next 30 days.
- **My Shows**: programmes, per-episode history and progress.
- **Search**: search Trakt and add a programme to your Trakt watchlist.
- **Show detail**: mark watched/unwatched, skip and hide across devices through iCloud, provider links and opt-in local reminders.
- **Settings**: OAuth connection, region, providers, specials, demo reset and credits.
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

### 4. Bundle the app credentials

Set `TRAKT_CLIENT_ID` and `TMDB_READ_ACCESS_TOKEN` in the Git-ignored `Configuration/Local.xcconfig` before building. Both Debug and Release embed these values into the app's Info.plist. CI must supply the same build settings or create the private configuration file. Release builds reject missing credentials or an unconfigured callback host.

These are app-wide credentials; customers never enter them. Values previously entered in Settings on a device must be copied into the build configuration manually. The app no longer reads developer credentials from the device Keychain. Bundled values can be extracted from an app; never put a Trakt client secret here.

Run the app, open Settings and tap **Connect Trakt**. A successful connection clears fictional demo viewing data and imports your watched programmes plus watchlist. Choose your region and streaming providers in Settings as desired.

Personal Trakt access and refresh tokens remain in the device Keychain. Disconnect clears local viewing data and those tokens while retaining the bundled app configuration and remote Trakt data. You can revoke the application separately through your Trakt account.

## What “Up Next” means

The algorithm selects the **set** of episodes that:

1. Have not been watched.
2. Have not been skipped in WatchMate.
3. Have a known air date on or before today in the device’s local calendar.
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

## iCloud sync

WatchMate keeps its existing SwiftData cache on each device and synchronizes app choices through the private CloudKit database in `iCloud.net.andrewroland.WatchMate`. Existing local data is imported without changing or deleting the SwiftData schema. The local container explicitly disables automatic SwiftData CloudKit mirroring.

Synced choices include region, specials, streaming-service filters, followed/hidden shows, skipped/unskipped episodes and per-show reminder preferences. A history revision signals other devices to reload watched history from Trakt; Trakt remains authoritative for watched dates and episode catalogues. Sign into the **same Apple Account and Trakt account on every device**. Each Trakt UUID has a separate CloudKit record zone. OAuth tokens, demo data, sync timestamps and notification permission remain device-specific.

The app syncs on launch/foreground, approximately every minute while open, after local changes, and during pull-to-refresh. Settings → iCloud sync shows progress, queued changes, errors and a Sync now button. It does not use background push delivery. Enable notifications separately on each device using the Settings button if desired.

Each preference has a separate revision. Changes to different episodes/shows merge independently; concurrent edits to the same preference use modification time with a deterministic tie-breaker. Initial imports yield to existing cloud values. Offline edits are saved in an atomic, account-specific journal under Application Support/CloudSync and retried automatically. False values explicitly preserve unskip/unhide changes. Clearing the local cache never deletes cloud records. Signing out/demo mode pauses the library; queued edits remain available when that Trakt account reconnects. If the Apple Account changes, synchronization pauses rather than uploading the previous account's data to another account.

### Apple setup and release verification

1. In the app target's Signing & Capabilities, enable **iCloud → CloudKit** and select/create `iCloud.net.andrewroland.WatchMate` under the app's signing team. The entitlement is already included. If changing this identifier, also update `CloudSync.swift`.
2. Run a development build on an iCloud-signed-in device, connect Trakt, and use **Sync now**. This creates a private custom record zone and the `WatchMatePreference` record type. Fields: `key` (String), `data` (Bytes), `modifiedAt` (Date/Time), `revision` (String). No query indexes are needed: fetching uses paginated record-zone changes.
3. In CloudKit Console, deploy the development schema to **Production** before TestFlight/App Store builds. Building successfully does not verify schema deployment or a two-device transfer.
4. With two devices using the same accounts, verify skip/unskip, hide/follow, region/services/specials, reminder choices, and watch/unwatch propagation. Try edits on both devices, offline edits and relaunch, reconnect, and demo mode. Confirm signing out on one device does not remove the other device's data.

The sync journal tests cover initial import precedence, independent merges, offline edits, unskip persistence, no echo uploads, cache clearing and deterministic conflict resolution. Live CloudKit provisioning and two-device tests require signed-in devices and the developer's CloudKit environment.

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

See [the pre-release review](PRE_RELEASE_REVIEW.md) for current build/test evidence and the checks still required for distribution. Live OAuth/API integration needs your registered credentials and callback domain.

## Before an App Store release

This is an implementation starter, not an already approved production app. Complete simulator/device/TestFlight testing and accessibility review, update the bundle ID and domain, verify the current API terms for your actual use, and supply your App Store privacy disclosures/privacy-policy URL. Review the included privacy manifest against the final app and its APIs.

The [approved TMDB logo](https://www.themoviedb.org/about/logos-attribution) and required notice are included in Settings → Credits. The logo is TMDB's trademark and is bundled solely for API attribution. JustWatch attribution is displayed in Settings and programme details. A revenue-generating app needs an appropriate TMDB commercial agreement; a private/TestFlight development build is not itself proof that any planned commercial use is covered. See [TMDB's FAQ](https://developer.themoviedb.org/docs/faq), [TMDB watch-provider requirements](https://developer.themoviedb.org/reference/tv-series-watch-providers), and [Trakt's API use policy](https://developer.trakt.tv/docs/api-use-policy).

No monetisation, direct streaming-service login, analytics, remote push backend or episode-specific streaming availability is implemented.

## Optional coffee tips

Settings includes small, medium and large one-off tips using StoreKit 2. Tips unlock nothing and do not require Trakt sign-in. They are consumable purchases, so users can tip again and there is no restorable entitlement.

Tips are enabled in Debug. Release builds hide them unless `ENABLE_TIPS` is added to the app target's Swift Active Compilation Conditions. Leave that condition absent while awaiting TMDB's licensing clarification.

For local purchases with no real charge, select `Configuration/CoffeeTips.storekit` in Edit Scheme → Run → Options → StoreKit Configuration. The checked-in scheme does not select a StoreKit configuration:

| Product ID | Type | Local UK price |
| --- | --- | --- |
| `watchmate.tip.sml` | Consumable | £1.99 |
| `watchmate.tip.med` | Consumable | £3.99 |
| `watchmate.tip.lrg` | Consumable | £5.99 |

For distribution, create these exact three consumable product IDs in App Store Connect, supply names/descriptions and review screenshots, choose actual prices and complete Apple's paid-app agreements and banking/tax setup. Displayed names and prices come from StoreKit, not hardcoded production amounts. Submit the products for review with the app. The local configuration does not create App Store Connect products.

For sandbox testing of the real products, change Edit Scheme → Run → Options → StoreKit Configuration to None. The local configuration is not used by TestFlight or App Store installations.

Before release, exercise all three purchases, repeated tipping, cancellation, Ask to Buy pending/approval, failed purchases, unavailable products and finishing interrupted transactions after relaunch. Pending transactions are handled by the app-wide transaction listener, even after Settings closes. Verified tips are finished without changing app features. Use Xcode's StoreKit transaction manager to simulate these cases.
