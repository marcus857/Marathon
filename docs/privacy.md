# Privacy and data handling

Marathon is an experimental training prototype. Do not use it for clinical, emergency, or other high-stakes fitness decisions.

## HealthKit categories requested

The app can request read access to:

- Workouts and running/walking distance
- VO₂ max
- Heart rate and resting heart rate
- Date of birth, used for a maximum-heart-rate estimate
- Workout routes

HealthKit authorization is controlled by the device and the user. The app should continue to work gracefully when individual categories are unavailable.

## Data used and uploaded

For qualifying workouts, the app can use timing, distance, pace, source attribution, average heart rate, aggregate time-in-zone data, resting heart rate, and optional notes. It does not upload raw heart-rate samples.

Workout routes are read from HealthKit only to render the owner’s local workout-detail view. This build no longer creates, persists, or uploads new route-coordinate payloads. Existing legacy public records may retain route data until owner-scoped remediation or deletion, although the current client ignores it. Any future route-sharing feature requires its own explicit per-workout consent, redaction design, retention policy, and device testing.

## Current CloudKit limitation

The current team-feed implementation uses CloudKit's public database. It is not a private-database or `CKShare` architecture. The client-side `isShared` flag controls application behavior; it is not a substitute for server-side access control, and `teamId` is only a feed label.

The legacy public database can contain `UserProfile`, `WorkoutEntry`, `PlanOverride`, `WorkoutLike`, `WorkoutComment`, and `NotificationPrefs` records, including their record names and identifiers. A profile write stores display name, initials, color tag, and an account-link field even when automatic workout sharing is off. Legacy workout, social, and preference records can contain the fields described in [the schema](cloudkit-schema.md). Treat all of it as exposed prototype data rather than private personal storage.

Until the storage model is redesigned and independently validated, only use synthetic or non-sensitive test data. Do not represent this app as a private health-data service.

The repository contains a disabled V2 migration foundation: full personal records are intended for `privateCloudDatabase`, while a separately modeled, rounded team summary would be the only data eligible for public sharing. It is not enabled until its Dashboard schema, access policy, and two-account device tests are complete. See [the V2 migration design](cloudkit-v2-migration.md).

## Optional weekly AI reviews

Weekly reviews are disabled until a service URL and matching provider are explicitly configured. Only an explicit Generate action after consent sends the selected week's minimized workout/plan inputs to the Python service. Its Apple authentication token is separate from the review JSON and is never forwarded to the AI provider. Only derived metrics and data-quality context reach the selected Azure OpenAI or direct OpenAI API adapter; no routes, notes, names, or teammate workouts are included.

The app names the provider before consent. The backend rejects mismatched provider selection and never automatically switches providers. Review results and tokens are not persisted by this review feature; cancellation cannot retract data already transmitted. Provider `store=false` does not guarantee zero retention or eliminate abuse-monitoring or infrastructure logs. Review the selected provider/deployment policy and server logging before any live health-data use. No live provider or device integration has been verified in this work. See [the complete review data boundary](weekly-review.md#data-boundary).

## Deletion and retention

The app includes a workflow to delete an uploaded workout that the signed-in profile owns. It does not yet provide a complete account-deletion, data-export, or retention-management workflow. Those features are required before a broader release.

## Safe testing practices

- Use a development CloudKit environment and test accounts.
- Do not commit Health exports, route traces, screenshots with identifiable data, or device logs.
- Use redacted or synthetic data in GitHub issues, pull requests, and documentation.
- Review CloudKit Dashboard roles, query access, and schema changes before inviting testers.
