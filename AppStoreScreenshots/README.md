# WatchMate App Store screenshots

Five native-resolution screenshots per device: Up Next, Coming Soon, My Shows,
programme details, and episode details. Upload the numbered PNGs in each folder
to the matching device section in App Store Connect.

| Folder | Simulator | PNG size |
| --- | --- | --- |
| `iPhone` | iPhone 18 Pro Max | 1320 × 2868 |
| `iPhone-Medium` | iPhone 18 Pro | 1206 × 2622 |
| `iPad-13-inch` | iPad Pro 13-inch (M5) | 2064 × 2752 |
| `iPhone-Duo` | iPhone Duo, outer display | 1398 × 2034 |

These are real app captures with a curated TMDB library: Severance, Silo, Slow
Horses, Stranger Things, The Bear, and Wednesday. Posters, episode stills, titles,
synopses, air dates, and UK streaming listings come from TMDB. Only viewing
progress is invented. They use the Ocean theme, light
appearance, English (UK), and a 09:41 status bar. PNGs are RGB without an alpha
channel. Air dates are preserved from the downloaded snapshot. Coming Soon
selects an actual scheduled episode date in that snapshot.

The medium iPhone set is included for the current required display category.
See Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

## Regenerate

1. Build the WatchMate scheme in **Debug** for an iOS Simulator in Xcode.
2. Ensure the four simulators above are available. Unlock them and dismiss any
   system setup/account alerts first. Keep iPhone Duo folded so its outer display
   is active. No account sign-in is needed for the sample library.
3. Use Python 3 with Pillow installed (`python3 -m pip install Pillow`). From the
   repository root, run:

   ```sh
   python3 scripts/capture-app-store-screenshots.py \
     --app "/path/to/DerivedData/WatchMate-…/Build/Products/Debug-iphonesimulator/WatchMate.app"
   ```

   In Xcode, reveal Products → WatchMate.app in Finder to locate the built app.
   The app includes the offline library and artwork; captures need no downloads.
   To export one device, append `--device iPad-13-inch` (or another folder name
   from the table). Use `--output /path/to/folder` to choose a different output
   directory, or `--settle-seconds 15` for a slower simulator.

4. Review every PNG before uploading. A system alert or a backgrounded app can
   obstruct an otherwise successful capture. The exporter rejects blank images
   and unexpected dimensions; it records capture metadata in `manifest-*.json`.

The exporter temporarily overrides the simulator status bar and clears that
override when finished. It installs the Debug app and leaves simulators booted.
It captures to a temporary directory before copying to the output location,
which supports projects stored on external/cloud drives.

## Screenshot mode

Launch arguments:

```text
--app-store-screenshots
--screenshot-screen=up-next
```

Supported screen values: `up-next`, `coming-soon`, `my-shows`, `show`, `episode`.
Screenshot mode is available only in Debug simulator builds. It uses an
in-memory SwiftData store and volatile preference overrides, bypasses onboarding,
and suppresses startup sync, widget publication, notification scheduling, and
StoreKit transaction observation during captures. Normal launches use the normal
database and preferences. Release/device builds ignore these arguments.

The same bundled library powers normal demo mode. Artwork works offline in
Release builds too. Existing fictional demo libraries are replaced on their next
demo-mode launch; connected accounts are unaffected. Programme information is a
snapshot, while demo watch/skip actions remain local sample progress.

## Refresh the bundled programme snapshot

With a Debug simulator build containing the configured TMDB credential, run:

```sh
python3 scripts/prepare-screenshot-fixtures.py \
  --app "/path/to/DerivedData/WatchMate-…/Build/Products/Debug-iphonesimulator/WatchMate.app"
```

This downloads metadata and images into `ScreenshotFixtures`, then updates
`WatchMate/Support/DemoLibrary.json` and the `DemoArtwork` asset-catalog group.
The credential is neither printed nor saved. Rebuild the app afterward, then run
the screenshot exporter. The downloaded folder is a preparation cache; running
the app needs only the bundled resources.

Metadata and images: [The Movie Database](https://www.themoviedb.org).
Streaming availability: JustWatch via TMDB. This product uses the TMDB API but
is not endorsed or certified by TMDB. Original artwork rights remain with their
respective owners.
