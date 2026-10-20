# Testing and device validation

`MarathonTests` is an XCTest unit-test target for deterministic domain behavior. The manual checks below are still required before claiming reliable HealthKit or cross-device behavior.

## Current unit coverage

- `RunMathTests`: unit conversions, invalid pace inputs, and ISO-week boundaries.
- `PlanEngineTests`: configured opening mileage and the one-mile safety floor.
- `WorkoutEntryTests`: Codable round-trips and fail-closed legacy sharing defaults.
- `ComplianceEngineTests`: week-window boundaries and qualifying-run thresholds.
- `HRZoneConfigTests`: cutoff normalization and zone boundaries.
- `CloudSyncV2Tests`: the future public team-summary projection allowlist, rounding, and disabled-by-default migration gate.
- `WeeklyReviewRequestBuilderTests`: one-week request shaping, privacy allowlisting, incomplete-import representation, and invalid-input rejection without a live backend.
- `WeeklyReviewPreparationTests`: matching-user/week freshness, explicit completeness confirmation, stale/failed imports, excluded teammate and unowned break data, and workout-count/future-date limits.
- `WeeklyReviewClientTests`: mocked authenticated requests, explicit provider configuration/header matching, cancellation/revoked consent before transmission, URL/redirect/privacy limits, response/schema/evidence validation, and safe HTTP failures.
- `TeamWorkoutSnapshotTests`: full-history replacement across members, deletions/unsharing/team changes, personal and pending-edit preservation, deletion tombstones, removed optional fields, stable ordering, local source identifiers, and current-profile resolution.

## Latest verified run

On October 19, 2026, with a fresh Python 3.13 environment and the synthetic reviewer demo:

- **207 Python tests passed**, with warnings treated as errors (`pytest -q -W error -p no:cacheprovider`).
- **63 XCTest cases passed**, with zero failures/skips, on the iPhone 17 Pro simulator (iOS 26.1).
- The unsigned **Release iPhone build succeeded** (`xcodebuild build -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`).

Xcode still reports the existing `ASPresentationAnchor()` deprecation warning in `WeeklyReviewAuthorization.swift`; this is not a test failure. No signing credentials, provider credentials, or hosted deployments were changed.

On October 20, 2026, the unsigned Release iPhone build was repeated successfully after replacing the image assets. The replacement images' dimensions, hashes, and asset-catalog references were also verified. No Swift or Python application logic changed in that artwork update.

Seven demo tests verify fixed synthetic calculations, resolvable citations, repeatable JSON, independence from service environment settings, installed-package execution outside the checkout, and prevention of provider imports or network connections. Run it yourself with `python -m app.demo` after the [credential-free setup](setup.md#backend-tests-no-accounts-or-keys-required).

The provider-selection suite exercises explicit Azure/direct OpenAI configuration, disabled/missing configuration, fixed/allowlisted destinations, missing/duplicated/mismatched provider headers, absence of cross-provider fallback, and SDK-to-mocked-HTTP success/error paths. Backend tests clear provider/service environment values, run away from real `.env` files, and block real HTTP transports. The app test host disables live CloudKit and screen-driven HealthKit tasks. All fixtures are synthetic; these checks validate the implementation and deterministic evaluators, **not live model quality**, actual account access, Apple sign-in presentation, provider deployment, APNs delivery, or two-device behavior. ChatGPT plan/Pro has no implementation or test claim.

## Unit-test backlog

Prioritize additional pure, deterministic code before testing live CloudKit calls:

- `RunMath`: unit conversions, pace edge cases, and time formatting.
- `PlanEngine`: initial settings, weekly growth caps, consolidation cadence, calendar boundaries, and minimum distances.
- `ComplianceEngine`: weekly date boundaries, qualifying-run threshold, mileage/run threshold combinations, and VO₂ max pass-through.
- `WorkoutEntry`: pace calculations and Codable round-trips for legacy and current records.
- Health import reducers: overlap deduplication, source identity, and duplicate suppression.
- Cloud record codecs and sync reducers after they are extracted from manager/store singletons.

## Physical-device matrix

| Scenario | Expected result |
|---|---|
| Fresh install | Onboarding appears; no other user's profile is selected. |
| HealthKit allow, deny, and revoke | Clear user feedback; no crash; available data imports correctly. |
| Weekly review without service URL/provider configuration | Setup-needed state; no request or credential prompt; `disabled`, unknown, or placeholder providers cannot submit. |
| Weekly review provider disclosure | The displayed Azure/OpenAI destination matches the chosen configuration and transmitted header. Switching configuration requires fresh consent. |
| Weekly review provider mismatch or old client | Missing, duplicated, or mismatched `X-Weekly-Review-Provider` returns 409 before generation, even for incomplete data; no request is sent to a different provider. |
| Weekly review consent and account changes | No automatic submission; decline/cancel/revoke or switch account during Apple sign-in and verify no data is sent. |
| Weekly review fresh versus incomplete data | Check the exact selected list; fresh confirmed data can reach only the consented provider after authorized deployment, unknown/failed/stale data returns clearly labeled metrics only. |
| Each configured provider/model | Separately authorized synthetic live tests establish access, structured-output support, timing, fallback behavior, and output quality for that exact Azure deployment or OpenAI model; mocked tests alone do not. |
| Weekly review unavailable/invalid service | Readable failure or labeled fallback; no fabricated review, token logging, persistence, or redirect following. |
| Duplicate Apple Health and Strava workouts | One canonical workout after deduplication. |
| Manual run | Local record appears with correct distance, duration, and pace. |
| Two devices, same iCloud account | Intended profile and opted-in records reconcile predictably. |
| Two separate iCloud accounts | Ownership boundaries and team-feed visibility match the documented model. |
| Offline then reconnect | No unintended duplicate records; errors recover on refresh. |
| Team-feed post/delete/like | CloudKit record, list UI, and push refresh agree. |
| Cross-tab team freshness | Share/edit/delete/unshare a workout on device A; refresh on B and compare Home feed, Team feed (all and selected member), calendar dots, leaderboard, weekly totals, open details, and HR summaries. They must agree for shared records. |
| More than 200 shared workouts | Older workouts remain represented in calendar and all-time totals; member filtering does not use a separate stale cache. |
| Refresh failure | Disable networking or inject a failed page; keep the last successful snapshot and show the stale-data/error banner. Reconnect and pull to retry. |
| Concurrent refresh and local changes | Change run type or delete during a fetch; the old snapshot must not overwrite a pending edit or resurrect the deleted row. |
| Profile and roster refresh | A correctly linked current profile stays selected. New profiles appear in the all-members filter; a saved subset remains a subset. |
| Route handling | This build creates no new persisted/uploaded route coordinates; legacy public records are audited/remediated owner-by-owner, and the client ignores legacy route payloads. |
| V2 private/published split | Private records remain inaccessible to another iCloud account; public summaries contain only the documented allowlisted fields. |
| Development and production CloudKit | Schema and permissions are deployed intentionally in each environment. |

## CI status

The Python workflow runs the synthetic test suite and offline demo without provider credentials. The iOS `build-for-testing` workflow compiles the app and XCTest bundle without signing; it does not execute XCTest cases. The results above are local verification, not a claim that a remote GitHub Actions run has passed. CI is not a substitute for physical-device checks, CloudKit integration tests, or release-signing validation.
