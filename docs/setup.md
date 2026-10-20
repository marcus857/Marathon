# Local setup

Start with the credential-free tests to inspect the project without connecting real health or cloud data. Device use and live AI reviews require separate account configuration and verification. The repository contains Apple-account-specific identifiers; treat them as values from the original development environment, not identifiers to reuse.

## Backend tests: no accounts or keys required

Requires Python 3.12+. From the repository root:

```bash
cd services/weekly_review
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[dev]'
python -m app.demo
pytest -q -W error -p no:cacheprovider
```

The demo prints synthetic metrics and supporting citations as an insufficient-data fallback (`fallback_used=true`), not an AI-generated review. Do not create a `.env` file for the demo or tests. Tests use synthetic data, clear provider settings, isolate themselves from developer environment files, and reject real HTTP transports. Installing dependencies requires package access; the demo and tests do not call a model provider. See the [service README](../services/weekly_review/README.md) for details.

## Build the iOS test bundle without signing

Use macOS with Xcode and an iOS 26-compatible SDK. From the repository root, the following mirrors the checked-in iOS build workflow:

```bash
xcodebuild build-for-testing \
  -project Marathon.xcodeproj \
  -scheme Marathon \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

This compiles the app and test bundle; it does **not** execute tests. To execute them, open the project in Xcode, choose the `Marathon` scheme and an installed iOS 26-compatible simulator, and use **Product → Test**. The test host disables screen-driven HealthKit and CloudKit work. Simulator tests do not verify a real account, push delivery, or health-data import. Recorded results and the physical-device checklist are in [testing.md](testing.md).

## Device prerequisites

- An Apple Developer team with the required capabilities and provisioning.
- A physical iPhone or iPad on the supported iOS version, signed into iCloud.
- A unique bundle identifier and CloudKit container owned by your team.
- Synthetic or non-sensitive test data; the current public-database design is not private health-data storage.

## Configure the app target

1. Open `Marathon.xcodeproj` in Xcode.
2. Select the `Marathon` target and choose your development team.
3. Replace the bundle identifier and display name.
4. Replace the CloudKit container identifier in both the target capability configuration and `CloudKitManager`.
5. Enable these capabilities for the same App ID:
   - HealthKit
   - iCloud with CloudKit
   - Sign in with Apple
   - Push Notifications
6. Confirm that the entitlement file and provisioning profile agree with those capabilities.

## Configure CloudKit

1. Open the CloudKit Dashboard for your container.
2. Create the record types and fields in [cloudkit-schema.md](cloudkit-schema.md).
3. Add indexes that support the app's active queries before using the team feed at scale.
4. Test in the development environment first.
5. Review roles and permissions deliberately, then deploy a reviewed schema to production only when ready.

The current app targets CloudKit's public database. Do not assume that its client-side `isShared` flag supplies access control.

## Run on a device

1. Build and install the app on a physical device.
2. Sign in with Apple and create a profile.
3. Authorize only the Health categories needed for your test; Health permission does not itself enable team sharing or AI submission.
4. Review the explicit team-sync choice before importing workouts.
5. Verify the record schema and the intended CloudKit environment in the Dashboard.

Health imports are filtered and additive, not a complete mirror of HealthKit edits/deletions. Team records cannot appear on another device until the source device imports and uploads them with sharing enabled. Review [architecture](architecture.md) and [privacy notes](privacy.md) before interpreting a successful local run as proof of cross-device correctness.

## Push notifications

The entitlement currently uses the development APNs environment. Validate push delivery separately for development and release signing. A CloudKit query subscription should be treated as a refresh hint; the app must still fetch and reconcile CloudKit records.

## Optional weekly reviews

The review screen stays unconfigured until both its HTTPS service URL and provider are explicit. No AI account is needed for the app's ordinary workout screens or the mocked tests.

For an authorized deployment, follow the [service setup and launch checklist](../services/weekly_review/README.md#before-live-use), then set these non-secret Xcode build settings:

| App build setting | Value |
|---|---|
| `WEEKLY_REVIEW_API_BASE_URL` | Your HTTPS Python service root, without `/v1/weekly-reviews`, query parameters, or credentials |
| `WEEKLY_REVIEW_PROVIDER` | `azure` or `openai`, exactly matching the server selection |

They populate `WeeklyReviewAPIBaseURL` and `WeeklyReviewAIProvider` in `Configuration/Info.plist`. Debug builds also accept the same Run-scheme environment values. Missing configuration prevents submission; mismatched app/server provider selection is rejected before generation. Real keys and model/deployment selection belong only on the server. The `openai` option is an API-key adapter, not a ChatGPT plan/Pro integration.

Do not treat a configured URL or passing mocked tests as a completed live deployment. Provider access, model quality, Apple authentication, consent, cancellation, and failure handling must still be verified using the [weekly-review checklist](weekly-review.md#live-validation-checklist).

## Do not commit

Never commit API keys, provisioning profiles, personal Health exports, device logs, CloudKit dumps, or user-specific Xcode state. The root `.gitignore` covers common local artifacts, but review `git status` before each commit.

The undocumented imagery has been replaced with newly generated artwork; its [manifest](assets/prompts.json) records prompts, file hashes, dimensions, and processing. The publication snapshot excludes the earlier local commits containing those images. No open-source license has been selected. Generation records do not establish exclusive copyright, public-domain status, or a license grant. Review [asset provenance](asset-attribution.md) before redistributing the repository or app.
