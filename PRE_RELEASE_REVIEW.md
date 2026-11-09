# WatchMate pre-release review

Latest pass: 6 November 2026. This is an engineering review, not an App Review approval or a complete accessibility certification.

## Final pass — 6 November 2026

**Release verdict: remaining release gates prevent an unconditional sign-off.** The current code builds and the full test suite passes on iOS 18.4. The outstanding privacy-policy, signed distribution, live-account and device checks below remain necessary.

### Fixes in this pass

- Reproduced two-digit calendar dates rendering as ellipses at Accessibility XXXL. The calendar now keeps dates at their natural text size and scrolls horizontally at accessibility sizes, with extra column spacing. Normal-size layout is unchanged. Simulator checks verified scrolling to the final column, selecting a date, and updating the selected-date heading.
- Replaced translucent secondary foreground styling throughout app views with a shared opaque secondary text color. Light uses 32% white and dark uses 75% white; Increase Contrast uses the system label color. Against the custom theme tile colors the light minimum is 5.94:1; against the custom dark chart surfaces the minimum is 6.73:1. This addresses the weak secondary-text contrast observed in the Ocean/light simulator capture.
- Changed small orange “Scheduled” labels to primary text in personal/shared episode rows, and exposed the search welcome title as a VoiceOver heading.

### Validation and limits

- Xcode Debug build passed with no reported warnings. Unsigned device Release build passed; the production-configuration validation script also passed. App and widget versions match at **1.0 (1)**. The built app contains its privacy manifest and populated Trakt/TMDB/callback settings; credential values were not printed.
- **114 tests passed on iPhone 16 / iOS 18.4:** 106 Swift Testing tests and 8 XCTest tests, zero failures. Result bundle: `/tmp/WatchMate-prerelease-ios18-tests.xcresult`.
- The Xcode test tool initially returned 114 tests not run. A direct iOS 27 run subsequently stalled after many passing tests and emitted duplicate XCTest automation-framework warnings; it was interrupted. The iOS 18.4 run completed successfully, but this does not establish a passing iOS 27 test run.
- iPhone 17 Pro / iOS 27 smoke testing passed Up Next, episode details, Coming Soon, My Shows, the disconnected Shared Shows state, and opening Settings using isolated demo fixtures. Calendar Accessibility XXXL interaction was also exercised; normal calendar layout and visibly clearer light-mode secondary text were rechecked. The final additional 8-point accessibility column spacing has build validation but was not recaptured. Numerical contrast values above are source-color calculations, not screenshot measurements. Device sessions were closed. Live accounts were not modified.
- Plist/entitlement/privacy-manifest syntax checks and `git diff --check` passed. Source review confirmed PKCE/state validation, device-only Keychain storage, no automatic HTTP write retries, startup failure recovery, and Reduce Motion handling for custom season animations.
- **VoiceOver source audit: PASS for inspected controls.** Meaningful labels and photo-crop adjustment actions are present. Spoken navigation, focus ordering and all live sharing states still need a device run.
- **Dynamic Type full-product verdict: FAIL for unconditional certification.** The reproduced calendar defect is fixed and inspected app text uses scalable styles, but compact widgets still intentionally truncate long titles at accessibility sizes. Full widget/detail/sharing coverage at all sizes has not been established.
- **Contrast verdict: NEEDS VERIFICATION for the complete product.** The corrected custom secondary-text pairs exceed 4.5:1; system materials, widget accents, all theme/control states and Increase Contrast still need comprehensive rendered verification.
- Follow-up: previously observed 28-point Mark watched/Skip controls now use a shared button style with a 44 × 44 point minimum. Detail/season layouts and shared photo controls adapt at accessibility sizes. Effective hit-area and activation checks remain open; see [ACCESSIBILITY_REVIEW.md](ACCESSIBILITY_REVIEW.md).
- After these accessibility changes, Xcode device build/build-for-testing passed and all **114 regression tests passed again** on iPhone 16 / iOS 18.4 (106 Swift Testing + 8 XCTest, zero failures). Latest bundle: `/tmp/WatchMate-accessibility-final-tests.xcresult`.

The highest-priority remaining gates are a real hosted WatchMate privacy-policy link in Settings/App Store Connect, signed archive/Organizer validation, production CloudKit and real Trakt flows, and the remaining accessibility/device matrix. No hosted policy URL was supplied during this pass, so none was invented.

## Earlier review — 23 October 2026

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
8. **Submission metadata.** Confirm the intended release version/build (currently 1.0 / 1), age-rating answers, screenshots for supported device families, support/privacy links, review instructions and account access as needed. Verify the distribution Xcode/SDK against [Apple’s current submission requirements](https://developer.apple.com/app-store/submitting/).

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
