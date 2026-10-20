# CloudKit V2 migration design

The legacy CloudKit prototype stores full `WorkoutEntry` records in the public database. It must not be described as private health-data storage: a client-side `isShared` flag is not an access-control boundary, and legacy public records may include sensitive workout fields.

V2 is intentionally **disabled** in `CloudSyncV2.swift` until the CloudKit Dashboard schema and device validation are complete.

## Target split

```text
Personal profile, full workout, preferences
    → privateCloudDatabase

Explicitly consented, rounded team summary
    → publicCloudDatabase
       (or a CKShare/shared database for an actually private team)
```

The two sides use different record types and models. A public summary must never reuse a personal workout record ID or encode HealthKit/Strava IDs, notes, source, routes, heart-rate data, zones, resting heart rate, exact start/end timestamps, or Sign in with Apple/iCloud identifiers.

## Proposed record types

| Scope | Record type | Purpose |
|---|---|---|
| Private | `PersonalProfile` | Profile plus a random public member alias |
| Private | `PersonalWorkout` | Complete personal workout and projection-outbox state |
| Private | `PersonalPreferences` | Notification and sharing preferences |
| Public/shared | `TeamMember` | Opted-in alias, initials, color, opaque team/member IDs |
| Public/shared | `TeamWorkout` | Rounded day, distance, optional rounded duration, run type, opaque IDs |

`TeamWorkoutProjection` is the tested allowlist model. It is not a live CloudKit codec yet.

## Migration rules

1. Add V2 record types, indexes, and roles in the **development** CloudKit environment first.
2. Test private personal sync on two devices signed into the same iCloud account.
3. Keep V1 records untouched. Never broad-scan public `WorkoutEntry` records to migrate another person’s data.
4. Require fresh consent before publishing a new V2 team summary; historical consent to a full V1 record is not equivalent.
5. Use a private outbox state (`pendingUpsert`, `published`, or `pendingDeletion`) so private and public operations can retry safely.
6. Clear or version the old team-feed cache before activating V2.
7. Inventory legacy route-bearing records only through an owner-scoped remediation flow; offer explicit deletion or rewrite that clears route fields before broader testing. Do not broad-scan or mutate another person’s V1 records.
8. Only after validation, retire the V1 public record types and offer an explicit deletion path for legacy data.

## Required validation before enabling V2

- Confirm record fields and indexes in the CloudKit Dashboard.
- Verify a separate iCloud account cannot read personal-profile or personal-workout records.
- Test offline create/update/delete, retry, conflict, and same-account cross-device behavior.
- Test public-summary opt-in, opt-out, explicit deletion, and two-person feed behavior.
- If team privacy is a requirement, use `CKShare` with a custom private zone or a server-enforced membership layer; an opaque public `teamId` is not access control.
