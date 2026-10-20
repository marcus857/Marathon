# CloudKit schema

This document describes the schema expected by the current client. Create and index fields in the CloudKit Dashboard before relying on cloud-backed features.

## Storage model

The app currently uses `CKContainer(identifier: "iCloud.com.Marcus.Marathon").publicCloudDatabase`. It does not use private or shared CloudKit databases. Treat all data written there as team-oriented prototype data until a private-data architecture and server-side permissions have been designed and validated.

Record names and identifiers are also public legacy metadata. `UserProfile` and `NotificationPrefs` records are written as part of profile/preference setup even when automatic workout posting is off.

A separately documented V2 design introduces private personal records and a minimized public summary model, but it is disabled and not represented by this legacy schema yet. See [CloudKit V2 migration design](cloudkit-v2-migration.md).

## Legacy V1 record types

| Record type | Fields used by the app |
|---|---|
| `UserProfile` | `displayName`, `initials`, `colorHex`, `ownerUserRecordName` |
| `WorkoutEntry` | `userId`, `start`, `end`, `distanceMeters`, `durationSec`, `avgHR`, `source`, `runType`, `isManual`, `notes`, `zoneDurations`, `zoneTotal`, `restingHR`, `isShared`, `teamId`, legacy `sharedRoutePoints` |
| `PlanOverride` | `weekStart`, `recovery`, `tempo`, `long`, `note` |
| `WorkoutLike` | `workoutId`, `fromUserId`, `toUserId`, `createdAt` |
| `WorkoutComment` | `workoutId`, `fromUserId`, `toUserId`, `text`, `mentionedUserIds`, `createdAt` |
| `NotificationPrefs` | `userId`, notification flags, `shareByDefault`, `teamId` |

## Query and index considerations

The current client queries or sorts on these fields:

- `UserProfile.ownerUserRecordName` and `UserProfile.displayName`
- `WorkoutEntry.start`, `WorkoutEntry.teamId`, and `WorkoutEntry.userId`
- `WorkoutLike.workoutId`, `WorkoutLike.fromUserId`, and `WorkoutLike.createdAt`
- `WorkoutComment.workoutId`, `WorkoutComment.toUserId`, `WorkoutComment.mentionedUserIds`, and `WorkoutComment.createdAt`
- `PlanOverride.weekStart`

Make the exact fields required by your active predicates queryable/sortable in the Dashboard. Validate schema changes in development first; a missing field should fail safely rather than cause the client to silently post a less-protected record.

## Deployment checklist

1. Create fields with types matching client writes.
2. Test create, read, update, delete, likes, comments, and team-feed queries in development.
3. Confirm that account ownership behavior and role permissions match the intended product model.
4. Review query indexes and record-size constraints. Do not add new route-point arrays; that is a legacy V1 field only.
5. Capture a schema change record before deploying to production.
