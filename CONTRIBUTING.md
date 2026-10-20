# Contributing to Marathon

Marathon is an in-development fitness prototype. Contributions should improve
the app without widening its health-data or location-data exposure.

## Before opening a pull request

1. Keep secrets, HealthKit exports, route traces, personal screenshots, device
   logs, provisioning profiles, and account-specific configuration out of Git.
2. Preserve the privacy boundary: a personal `WorkoutEntry` must never become a
   public team-feed payload. See [the V2 CloudKit migration design](docs/cloudkit-v2-migration.md).
3. If a change affects CloudKit fields, queries, indexes, subscriptions, or
   permissions, update the relevant schema and migration documentation in the
   same pull request. Do not enable V2 without Dashboard and device validation.
4. If a change affects the weekly-review service, keep the model input
   allowlisted and add a synthetic test for any new claim, metric, or rejection
   path. Never add any provider credential to the app or repository. Preserve
   explicit provider selection and matching consent; never silently switch providers.

## Verification

Run the checks appropriate to your change before requesting review:

```sh
xcodebuild build-for-testing \
  -project Marathon.xcodeproj \
  -scheme Marathon \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

```sh
cd services/weekly_review
python -m pip install -e '.[dev]'
pytest -q -W error -p no:cacheprovider
```

Physical-device checks are required for HealthKit, iCloud/CloudKit, Sign in
with Apple, push notifications, and every privacy or consent flow. Record
manual coverage in [docs/testing.md](docs/testing.md), using only synthetic
test data.

## Pull-request expectations

- Make one focused change per pull request where practical.
- Explain any user-visible privacy, consent, or data-retention effect.
- Include the commands run and their results.
- Do not claim a feature is production-ready unless the required device and
  service validation in [docs/roadmap.md](docs/roadmap.md) is complete.

For security or privacy vulnerabilities, follow [SECURITY.md](SECURITY.md)
rather than opening a public issue.
