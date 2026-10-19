# Shared Shows

WatchMate supports multiple independently invited lists. Each list is a separate custom CloudKit zone and private `CKShare`. A programme can belong to several lists, with independent episode progress in each. Sharing uses the device's iCloud account; personal viewing history uses the connected Trakt account.

## Using the feature

1. Open **Shared Shows**, create a named list, and use **Invite / Manage sharing** to invite participants with read/write access. The same screen manages participants and allows invitees to leave.
2. Use **Add programmes** to search or select an existing programme. Alternatively, long-press a programme in **My Shows** and choose **Move to Shared Shows**.
3. Sharing captures the contributor's current Trakt watched episodes across every season, including specials. The show moves out of My Shows while it belongs to a shared list. Its personal Trakt history is retained; personal Up Next and widgets continue to use personal progress.
4. Invitees receive a history-review prompt when new shared programmes arrive. They may keep their existing history or review an exact progress replacement. Existing and new watches are compared by season/episode identity, not counts.
5. Confirmation explicitly warns about overwriting progress, shows watched/unwatched change counts and estimated time, and warns that unwatches remove repeat-watch history. Only the user's explicitly confirmed Trakt account is changed.
6. Episode buttons inside a shared programme update group progress only. Each participant can explicitly sync that progress to Trakt later. There is no automatic background overwrite of personal history.

The import shows per-episode progress and can be stopped. Completed changes remain. Retrying fetches current Trakt history and only processes outstanding differences. Trakt rate limits and ambiguous network failures stop the operation rather than blindly retrying writes. Keep the app open during an import; after interruption, review and sync again.

Lists refresh on foreground activation, approximately every minute while active, and on pull-to-refresh. Saved lists remain visible during refreshes. Records and CloudKit change tokens are cached on disk, so subsequent refreshes download only changes. Automatic refreshes within 60 seconds of a successful refresh are skipped; pull-to-refresh and local changes force a check. On launch, the current iCloud identity is verified before restoring saved lists. Temporary network failures retain saved data with a status message; revoked or deleted lists are removed when confirmed by iCloud. Shared writes require a network connection. There is no background push or offline write queue for shared lists in this implementation. List membership follows iCloud, so switching Trakt accounts on the same Apple account does not change the iCloud lists available to that device; history prompts are scoped to the Trakt account.

## CloudKit deployment

Container: `iCloud.net.andrewroland.WatchMate`. The app already has the iCloud entitlement; `CKSharingSupported` is enabled and application/scene delegates handle both cold-launch and running-app invitations.

New record types and fields:

| Record type | Fields |
| --- | --- |
| `HouseholdList` | `name`: String; `photoData`: Bytes (optional) |
| `HouseholdShow` | `payload`: Bytes, `removed`: Int64 |
| `HouseholdEpisode` | `showID`, `episodeID`, `season`, `number`, `skipped`: Int64; `revision`: String; `watchedAt`: Date (nullable) |

Each list uses a `Household-<UUID>` zone. Reads enumerate zone changes, so no custom query indexes are required. Removed shows use tombstones. Re-added shows have a fresh revision so old episode events cannot revive previous shared progress. Concurrent writes to different episode records remain independent; same-record conflicts return an error for refresh/retry.

Before TestFlight/App Store release, exercise create/add/watch/unwatch in the development container so all record types and fields exist, then deploy the schema to production using CloudKit Console. Do not replace the existing container schema or change public database permissions. The code does not deploy CloudKit schema. See [Apple's schema deployment guidance](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow).

## Live acceptance checks

Use test accounts, including distinct Apple and Trakt accounts. These checks require signed-in devices and were not performed by the automated tests:

- Invite B and C to list One, and D to list Two. Confirm each person sees only their invited lists. Test invitation acceptance with the app closed and already open.
- Add the same programme to both lists. Update one list's episodes and confirm the other's progress does not change.
- Move an existing programme, verify its shared progress, then remove/re-add it and verify stale episode events do not return.
- As an invitee, keep existing history; then separately test replacement when ahead, behind, and with gaps. Check the destructive confirmation and the resulting Trakt watched states.
- Stop an import partway through and retry. Test loss of connectivity/rate limiting, and verify completed watches are not submitted again.
- Remove a participant or leave a list, refresh, and verify access disappears. Test with iCloud unavailable and with Trakt disconnected.

Automated `SharedHistoryTests` cover ahead/behind differences, gaps with equal totals, specials and multiple seasons, matching histories, partial-import retry, empty shared progress, duplicate entries, and missing catalogue episodes.

Trakt unwatch semantics are documented in [Trakt's API reference](https://trakt.docs.apiary.io/): removing by episode removes its watches, scrobbles, and check-ins, which is why the app explicitly warns about irreversible history loss.

## Shared season layout

Shared programmes use collapsible season headings, episode artwork, individual watch/skip actions, and season-wide Mark watched and Skip actions. Watched or skipped seasons move to the completed section at the end. Shared skips do not mark episodes watched in Trakt. Bulk writes show progress and retain acknowledged changes if a later write fails.

The header shows watched episode count and known runtime totals. Time left includes aired, unwatched, unskipped episodes. Totals and seasons respect the Specials setting, and missing runtimes are disclosed. History sync and its explanatory message are accessible from the programme’s three-dot menu.

Before releasing this version, include the optional `HouseholdEpisode.skipped` integer field in the deployed CloudKit schema, as well as `HouseholdList.photoData` for list photos. Existing episode records without `skipped` are treated as not skipped.
