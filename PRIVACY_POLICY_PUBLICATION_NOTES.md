# WatchMate privacy policy — publication checks

Drafted 6 November 2026 against the current app source. The policy is not yet publication-ready because the publisher’s identity and off-app practices are unknown. This is a technical drafting aid, not a certification of legal compliance.

## Complete before publication

1. Supply the publisher’s legal identity, country, privacy email, applicable business address and effective date. Confirm any required representative or data-protection officer details with your adviser; none have been invented.
2. Confirm the proposed legal bases in “Why information is processed” against your actual terms and practices. In particular, document the legitimate-interest assessment for support, security and diagnostics. Permission to access a device feature is not automatically the legal basis for every use of the resulting information.
3. Set support/diagnostic retention periods or concrete deletion criteria that you will actually follow. Confirm whether you download or retain Apple diagnostics/TestFlight feedback and adjust the text accordingly.
4. Identify the hosting providers and logging/cookie configuration for the public policy/support site and `auth.andrewroland.net`, plus the support-email provider. Establish whether authentication callback query parameters ever reach or enter logs on a server. Do not publish a claim that no information reaches publisher infrastructure until verified. Add actual international-transfer safeguards where needed, rather than claiming unspecified standard contractual clauses are in place.
5. Confirm intended age audience, distribution territories and any additional regional notice requirements. The draft intentionally does not invent an age limit or claim a children’s-data programme exists.
6. Confirm practical cloud-data deletion assistance. Current code clears the local programme library on disconnect but retains preferences/journals and remote data. Shared programme removal is a tombstone, not physical erasure of its payload/history. There is no app-wide permanent-erasure function. A policy cannot substitute for a usable deletion process or any applicable deletion obligations.
7. Check the Apple, Trakt and TMDB privacy links in a browser before publication. The Apple page and official Trakt API policy were accessible during research; the web tool could not retrieve the Trakt/TMDB privacy pages. Do not substitute `trakt.pro`, which is not the `trakt.tv` service used by this app.
8. Tips are disabled in the current Release build unless explicitly enabled. The policy describes them conditionally; remove that paragraph if preferred for this release. Do not infer current commercial licensing from this policy.
9. Reconcile App Store Connect privacy disclosures and the privacy manifest with the final data flows and provider practices. The draft does not certify the existing “no collected data” declaration.
10. Remove the draft banner and every bracketed placeholder, publish at a stable public HTTPS URL, then add that URL to Settings and App Store Connect. Publishing the Markdown file in the repository alone does not add the required in-app link.

## Sources and implementation evidence

- [Apple App Review Guidelines, section 5.1](https://developer.apple.com/app-store/review/guidelines/#privacy): policy availability, data use, sharing, retention/deletion and user controls.
- [Apple App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/): disclosure definitions and provider considerations.
- [ICO: What privacy information should we provide?](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/individual-rights/the-right-to-be-informed/what-privacy-information-should-we-provide/): identity, purposes, legal bases, recipients, retention, transfers and rights.
- [Trakt API Use Policy](https://developer.trakt.tv/docs/api-use-policy): authorisation, credential handling and user-data access.
- `WatchMate/Services/TraktAuth.swift` and `WatchMate/Support/Keychain.swift`: PKCE authentication and device-only credential storage.
- `WatchMate/Services/AppStore.swift`: disconnect, private-cloud snapshot fields, personal notes, shared-progress writes and local clearing.
- `WatchMate/Services/CloudSync.swift` and `SharedShowsCache.swift`: retained account-specific journals and caches.
- `WatchMate/Services/SharedShows.swift`: participant sharing, notes/photos and tombstone-based removal.
- `WatchMate/Services/TMDBService.swift`, `Notifications.swift` and `TipStore.swift`: catalogue requests, local reminders and optional purchases.

No app code or service configuration was changed as part of writing this policy.
