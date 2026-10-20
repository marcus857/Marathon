# Architecture

Marathon has two boundaries: a SwiftUI application that imports and presents workout data, and a stateless Python API that optionally generates a weekly recap. `WorkoutStore` coordinates the app's HealthKit imports, CloudKit records, local state, and shared screen data. The review service does not read CloudKit or HealthKit directly.

## Runtime components

```text
SwiftUI screens
    │
    ├── Home, calendar, plan, weekly summary, team feed, and workout detail
    │
WorkoutStore
    ├── HealthKitManager
    │     └── workout, heart-rate, VO₂ max, resting-heart-rate, and route queries
    ├── CloudKitManager
    │     └── public-database profile, workout, like, comment, preference, and feed records
    ├── PushSubscriptionManager
    │     └── APNs registration and CloudKit query-subscription handling
    └── UserDefaults
          └── local settings, caches, overrides, dates, breaks, and demo state

WeeklyReviewView → consent + Apple authentication → HTTPS Python API
    ← review/fallback ← evidence validation ← provider ← calculated metrics
```

## Code map

| Responsibility | Starting points |
|---|---|
| App state and shared-tab refresh | [`WorkoutStore.swift`](../Marathon/WorkoutStore.swift), [`TeamWorkoutSnapshot.swift`](../Marathon/TeamWorkoutSnapshot.swift) |
| Health import and source deduplication | [`HealthKitManager.swift`](../Marathon/HealthKitManager.swift) |
| Legacy CloudKit persistence | [`CloudKitManager.swift`](../Marathon/CloudKitManager.swift) |
| Review consent, authentication, and transport | [`WeeklyReviewView.swift`](../Marathon/WeeklyReviewView.swift), [`WeeklyReviewAuthorization.swift`](../Marathon/WeeklyReviewAuthorization.swift), [`WeeklyReviewClient.swift`](../Marathon/WeeklyReviewClient.swift) |
| Privacy-minimized mobile request | [`WeeklyReviewContracts.swift`](../Marathon/WeeklyReviewContracts.swift) |
| Python endpoint and typed contracts | [`main.py`](../services/weekly_review/app/main.py), [`contracts.py`](../services/weekly_review/app/contracts.py) |
| Deterministic metrics and evidence checks | [`metrics.py`](../services/weekly_review/app/metrics.py), [`validation.py`](../services/weekly_review/app/validation.py) |
| Selected model provider and bounded transport | [`providers.py`](../services/weekly_review/app/providers.py) |

## Health import flow

1. A user authorizes HealthKit and signs in with Apple.
2. `HealthKitManager` queries running and walking workouts within a requested time window.
3. The app filters short, missing-distance, and implausibly slow workouts; it attributes their source and deduplicates overlap.
4. `WorkoutStore` derives a canonical workout identity, optional average heart rate, and aggregate zones. Route coordinates remain in HealthKit for the owner’s detail view; this build does not create, persist, or upload new route payloads, though legacy public records may retain earlier payloads until remediated.
5. The app merges the result into its local store. An explicit team-sync choice controls whether qualifying records are posted to CloudKit.

This is a foreground/import-on-login flow, not a HealthKit background-delivery pipeline. The importer is additive: it does not fully reconcile edits or deletions in Apple Health. Weekly review preparation therefore asks the user to check the selected workout list; a successful HealthKit query alone does not prove complete read permission or complete data.

## Cloud refresh flow

1. Launch, foreground activity, tab selection, pull-to-refresh, and CloudKit push events use one coalesced refresh in `WorkoutStore`. Tab changes are throttled for 15 seconds after success; explicit refreshes and pushes request a follow-up pass if a fetch is already running.
2. `CloudKitManager` reads all pages of profiles and workouts across the supported history window, without a latest-200 cap. Unavailable, failed, malformed, or partial snapshot reads fail rather than publishing an empty result.
3. `TeamWorkoutSnapshot` replaces the teammate portion with explicitly shared records in the selected team. Remote edits, deletions, unsharing, and team changes update the same observable data used by the feed, calendar, leaderboard, and summaries. Personal local workouts and pending edits are preserved; public-feed absence is not authority to delete private personal history.
4. Details and HR summaries observe changing workout inputs. Derived caches are rebuilt, and failed refreshes keep previously loaded data with an error banner. Cached data is not a freshness guarantee.
5. Silent workout and like/unlike subscriptions are independent of alert preferences. Push delivery is best effort, not a server-side conflict-resolution or guaranteed background-sync system.

Another member's new workout cannot appear until their device imports it and successfully uploads it with sharing enabled. VO₂ max, break notes, settings, and private/unshared workouts are not synchronized team metrics. The legacy profile schema has no team-membership field, so its public roster can include profiles without visible shared workouts. Live multi-device validation remains necessary.

## Weekly AI review boundary

`WeeklyReviewView` explicitly prepares one selected week through `WorkoutStore`, then uses `WeeklyReviewClient` to send a minimized request to the configured HTTPS Python service after consent and fresh Apple authentication. This is separate from CloudKit team sharing; no review data or provider credentials are stored in CloudKit.

The service derives mileage, run count, duration, weighted pace, and coverage metrics before generation. Incomplete or uncertain data suppresses the model request. An eligible request sends only derived metrics and allowed claim/evidence identifiers to a `ReviewProvider`; structured output is then checked locally before display. The model does not calculate the displayed numbers. Claim-code and citation checks are rule-based, not a general semantic guarantee about every sentence.

`WEEKLY_REVIEW_PROVIDER` explicitly selects Azure or direct OpenAI; it defaults to disabled. Both API-key adapters share bounded transport, strict output parsing, and the same grounding validation. The app sends `X-Weekly-Review-Provider` matching the provider named in its consent UI; a mismatch is rejected before generation. Failures produce deterministic metrics or a safe error, never cross-provider failover. Tokens and generated reviews are not persisted by this feature.

Model/deployment names are server configuration, not business logic. ChatGPT plan/Pro is a separate, unimplemented authorization/streaming path. See [weekly-review implementation and remaining live checks](weekly-review.md).

## Data ownership and source of truth

| Data | Current source of truth | Cross-device status |
|---|---|---|
| Profiles, explicitly posted legacy feed records, plan overrides, likes, comments, notification preferences, and their record IDs | CloudKit public database | Experimental prototype only; not private personal sync |
| Team-feed cache | `UserDefaults` plus CloudKit | Cache only |
| Important dates, breaks, HR-zone config, run-type overrides, seeded plan | `UserDefaults` | Local only |
| Raw HealthKit samples and routes | Apple Health on the device | Routes are rendered locally for their owner; not persisted or uploaded |

The current team feed is field-based (`isShared` and `teamId`) rather than a CloudKit sharing-zone or `CKShare` design. Client-side ownership checks are useful guardrails but do not replace CloudKit Dashboard security rules. Neither the public feed nor the local cache supplies complete private persistence for personal workout history. See [privacy and data handling](privacy.md) for the precise exposure and retention limits.

## Verification boundaries

Pure snapshot reconciliation, request shaping, numeric calculations, and response checks have automated tests. Provider tests exercise the actual SDK against mocked HTTP, and app client tests use mocked responses. They do not establish live model quality, HealthKit permission behavior, Apple sign-in presentation, or cross-device CloudKit correctness. The [testing guide](testing.md) separates recorded local results from the remaining physical-device checks.

## Known design limitations

- The project has two large coordination types: `WorkoutStore` and `CloudKitManager`. Future work should extract pure sync reducers, record codecs, and identity logic for testability.
- Local run-type overrides can conflict with cloud updates. A durable design needs timestamped pending writes or an explicit conflict policy.
- The app must not silently fall back to a different CloudKit container, because that can split device data.
- A production-grade privacy model should use a private database for personal health data and publish only explicitly consented, minimized team-feed records.
- `CloudSyncV2.swift` contains the disabled, tested model boundary for that migration. Enabling it requires Dashboard schema work and two-account device testing; see [the migration design](cloudkit-v2-migration.md).
