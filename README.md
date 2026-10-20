# Marathon

A SwiftUI marathon-training prototype that turns Apple Health workouts into weekly progress summaries, a shared team feed, and an optional evidence-linked AI recap. Built for iPhone and iPad, with a separate Python service for review generation.

> Prototype, not a medical device or a production-ready health-data service. The current team feed uses CloudKit's **public database**. Use synthetic or non-sensitive test data; see [privacy boundaries](#privacy-and-reuse).

## What it does

- Imports qualifying running/walking workouts from HealthKit, deduplicates overlapping records, and calculates pace and heart-rate summaries.
- Provides a dashboard, training plan, calendar, manual run entry, and weekly mileage/run-count comparisons.
- Uses Sign in with Apple profiles and an experimental CloudKit team feed; tabs share one reconciled workout snapshot so edits, deletions, and unsharing update together.
- Offers an explicit-consent weekly review: the Python API calculates the numbers, a selected Azure OpenAI or direct OpenAI adapter generates structured commentary, and validation checks citations and allowed claims. Incomplete data and provider failures produce labeled metrics-only fallbacks.

## How it fits together

```text
Apple Health → WorkoutStore → SwiftUI tabs
                    ↕
              CloudKit public feed

SwiftUI review + consent → Python API → deterministic metrics
                                           ↓
                                  Azure / OpenAI adapter
                                           ↓
                                schema + evidence validation
                                           ↓
                                 review or labeled fallback
```

See [architecture and data ownership](docs/architecture.md) and the [weekly-review design](docs/weekly-review.md).

## Engineering choices

- **Calculate facts before generation.** Versioned contracts and request-scoped evidence IDs separate measured metrics from model-written prose. Rule-based checks are not a complete detector of unsupported language.
- **Fail closed at boundaries.** Reviews require fresh Apple authentication, explicit provider selection, and matching consent. Requests have size/time limits; redirects and cross-provider fallback are disabled.
- **Make sync testable.** A pure snapshot reducer preserves personal/pending edits while replacing shared team data. Failed refreshes retain the last snapshot and surface an error; live multi-device behavior still needs validation.

## Try the synthetic demo and tests

Requires Python 3.12+. From the repository root:

```bash
cd services/weekly_review
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[dev]'
python -m app.demo
pytest -q -W error -p no:cacheprovider
```

No API keys, Azure account, Apple account, or `.env` file are needed. The demo prints synthetic metrics and citations with `status=insufficient_data` and `fallback_used=true`: it is a deterministic fallback, **not an AI-generated review**. Tests block external HTTP and mock provider responses. For the app, use [Xcode setup](docs/setup.md); for an authorized live review deployment, use [service setup](services/weekly_review/README.md).

## Verification and remaining work

Last verified locally on **October 19, 2026**: **207 Python tests**, **63 XCTest cases**, and an unsigned **Release iPhone build** passed. The repository includes Python-test and unsigned iOS-build workflows; see [test coverage and device matrix](docs/testing.md).

The review client, API, and both provider adapters are implemented and offline-tested. Live provider access, model-output quality, hosted HTTPS deployment, Apple sign-in presentation, and two-device sync are **not yet verified**. ChatGPT plan/Pro integration is not implemented. See the [roadmap](docs/roadmap.md).

## Privacy and reuse

CloudKit public records can contain profiles, workout timing, notes, and aggregate heart-rate data; client-side sharing flags are not server access control. New route coordinates are not persisted or uploaded, but legacy public records may retain earlier route payloads. Personal settings and workout history are not fully synchronized privately. A [private-record/minimized-summary migration](docs/cloudkit-v2-migration.md) exists only as a disabled foundation. Read the [full privacy notes](docs/privacy.md) before running or sharing the app.

Signing and CloudKit identifiers must be replaced with your own for device use. The undocumented images have been replaced with newly generated project artwork, with recorded prompts and file hashes. The publication snapshot excludes the earlier local commits containing those images. **No open-source license has been selected.** Generated provenance and repository visibility are not a copyright guarantee or a grant of redistribution rights. See [asset provenance](docs/asset-attribution.md), [contributing](CONTRIBUTING.md), and [security reporting](SECURITY.md).
