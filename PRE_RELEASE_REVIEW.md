# WatchMate pre-release review

Reviewed 23 October 2026. This is an engineering review, not an App Review approval or a complete accessibility certification.

## Changes made

- Replaced the database-startup `fatalError` with an opening state and a retry screen. The existing database is preserved; a failed open does not reset or replace it. Widget deep links received before initialization finishes are retained.
- Removed the main app’s forced `.large` Dynamic Type size. Up Next’s summary/actions, programme rows, and Settings photo controls now stack vertically at accessibility sizes. Episode titles can wrap without a two-line cap at those sizes.
- Corrected Help, What’s New, and the Shared Shows information alert: shared watched/unwatched actions update the acting user’s Trakt history when the setting is enabled (the default). Full history replacement still requires review and confirmation.
- Corrected README claims about the required Xcode version, fictional demos, iPhone-only support, air-date semantics, test execution, and the StoreKit scheme configuration.
- Preserved pre-existing edits to EpisodeDetailView, SharedProgrammeView, and ShowDetailView.

## Validation

- Xcode active-scheme build passed; build log reported no warnings.
- All 65 existing tests passed after the startup/copy changes: cloud merges, shared-history plans, shared progress, shared-list cache, episode rules, reminders, widget snapshots/deep links, and demo fixtures.
- iPhone 17 / iOS 27 simulator: startup, all four tabs, and Settings passed with isolated demo fixtures. Accessibility XXXL scaling was confirmed. Follow-up checks confirmed the Up Next summary, vertically stacked episode actions, full programme/episode titles, and both photo controls without clipping. The photo picker uses a text-only label at accessibility sizes after the icon-and-text label clipped on this OS. Verification sessions were closed.
- The Release build passed inside Xcode with no warnings, using a temporary Release scheme. Confirmed `-O`, `dwarf-with-dsym`, and no Debug compilation condition. The original scheme was restored and the temporary scheme removed. An earlier command-line attempt failed on macro plug-in/simulator-service access in the tool environment; the successful Xcode build supersedes that compile result. This was a build, not an Organizer archive/export validation.
- App/widget Info.plists, entitlements, and the app privacy manifest parse successfully. `git diff --check` passed.
- The database failure/retry branch has compiler validation but has not been exercised against a deliberately damaged database. Test that in a disposable installation before shipping.

## Release gates still open

Season-history follow-up: build and all 73 tests passed. Season marking now uses one history snapshot and at most one Trakt history write, excluding existing watches and future episodes. Tests cover partial rejection, failed writes, repeated marking, and progress state for programmes without providers. The Search sheet now hosts its own progress overlay; shared programme updates use the same modal presentation. Shared programme headers preserve or resolve IMDb links. Live Trakt writes and production CloudKit propagation still require account-based verification.

1. **Public privacy policy and support URL.** No WatchMate privacy-policy link was found in Settings. Supply the actual hosted policy, link it in-app, and enter it in App Store Connect. Cover Trakt, TMDB requests, CloudKit private/shared data, photos, retention, disconnect versus deletion, and contact details. The current manifest declares no collected data; reconcile that declaration and App Store privacy answers with the actual third-party practices rather than assuming “no analytics” means “no collection.” See [Apple’s review guidelines](https://developer.apple.com/app-store/review/guidelines/#privacy) and [privacy disclosures](https://developer.apple.com/app-store/app-privacy-details/).
2. **Signed Release archive and Organizer validation.** Verify production credentials, callback domain/AASA, app and widget signing, matching versions, privacy-manifest inclusion, and export compliance in the actual archive. Release configuration already has a guard against missing API configuration. Do not infer archive validity from the Debug build.
3. **CloudKit production and real accounts.** Deploy the private/shared schema to Production and test invitation acceptance on cold launch, owner/participant permissions, revoked sharing, offline edits, reconnecting a different Trakt account, and switching Apple Accounts on two devices. The unit tests do not verify provisioning or production schema.
4. **Authentication and account management.** Exercise real PKCE sign-in, cancellation, expired/revoked tokens, reconnect, and disconnect. Onboarding offers creation of a Trakt account on Trakt’s page; confirm the applicable account-deletion flow and explain the third-party account relationship in review notes. Local disconnect intentionally retains remote data and is not account deletion.
5. **Accessibility remains open.** Both app and widget fixed-text-size overrides are now removed. Widgets use a simpler layout from XX Large upward, retaining 44-point actions and exposing full episode titles/air dates to VoiceOver. Small widgets still truncate long titles because their bounds cannot grow; this is not a full Dynamic Type certification. Run VoiceOver navigation, contrast checks for every theme in light/dark mode, Reduce Motion, and accessibility-size layouts across all detail/calendar/sharing screens.
6. **Device/platform coverage.** Test iOS 18 (minimum deployment target), the current OS, small iPhones, iPad portrait/landscape and multitasking, cold launch, upgrade with an existing library, no network, low storage, camera denial, photo selection, and notification permission changes. Verify small/medium/large widgets and their action routing on both minimum and current OS versions.
7. **StoreKit and licensing.** Tips are disabled in Release unless `ENABLE_TIPS` is supplied. If enabling them, confirm licensing and App Store Connect consumable products/agreements, and test sandbox purchases, cancellation, pending approval, interrupted transactions, and relaunch. The local StoreKit file is not selected in the checked-in scheme and does not create production products.
8. **Submission metadata.** Set the intended release version/build (currently 0.1.0 / 5), age-rating answers, screenshots for supported device families, support/privacy links, review instructions and account access as needed. Verify the distribution Xcode/SDK against [Apple’s current submission requirements](https://developer.apple.com/app-store/submitting/).

## Refactoring priorities

Widget follow-up: build and all 65 tests passed. WidgetKit previews were inspected at normal and AX5 text sizes, in light/dark appearances, across small/medium/large families. Added preview timeline cases for long titles, caught-up, unconfigured, and failed-update states. Larger text prioritizes programme/episode identification and actions over artwork/synopsis; compact pending actions use an hourglass with a spoken saving label to avoid reflow. The large unconfigured widget and its editor also rendered correctly on the simulator Home Screen. Isolated screenshot fixtures supplied no selectable shows to the editor, so live intent execution and older-OS widget behavior still need real-library device coverage.

These are useful follow-ups, not reasons to perform a broad rewrite immediately before release.

- `Services/AppStore.swift` combines library refresh, shared progress, CloudKit coordination, reminders, and widget publication. Extract widget publication and shared-progress retry coordination into collaborators with explicit inputs, preserving the existing account checks and persistence order. Add failure-path tests before moving those responsibilities.
- `AppStore.waiting` and `upcoming` map states back to episodes with a linear search for every result. Up Next computes waiting episodes more than once per render. For large libraries, build a keyed episode lookup and reuse computed entries; measure the benefit with Instruments.
- `CatalogueService` exists, but AppStore constructs a concrete TMDBService. Inject catalogue/auth/network dependencies to test HTTP failures, cancellation, token refresh, and partial refreshes without live accounts. Existing tests do not cover transport behavior.
- Standardize cancellation handling: several service/view catch blocks present all errors, while others suppress cancellation. Keep cancelled work from publishing stale errors or partial UI state.
- Prefer small dedicated view types for substantial screen sections. Avoid splitting every short computed property solely for formatting. Keep the existing shared widget-source link rather than creating duplicate app/widget models.
- Add a deliberate, versioned SwiftData migration strategy before future model changes, with upgrade fixtures. Do not reset the store to recover from migration failures.
- CI currently uses a runner’s default Xcode. Pin/verify a toolchain that supports all referenced APIs (including guarded iOS 27 APIs), and add a Release archive check with securely supplied production configuration. The current workflow only tests Debug.

## Existing safeguards retained

OAuth uses PKCE and callback state/host/path checks; personal credentials are stored in device-only Keychain items. HTTP does not automatically retry writes. Shared history replacement previews changes and checks the account before writing. Cloud journals and widget snapshots use atomic persistence; relevant snapshot/account-isolation behavior has tests. Camera access has a purpose string, and library selection uses PhotosPicker. The inspected source has no ATS arbitrary-load exception.
