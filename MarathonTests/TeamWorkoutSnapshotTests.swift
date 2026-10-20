import XCTest
@testable import Marathon

@MainActor
final class TeamWorkoutSnapshotTests: XCTestCase {
    private let since = Date(timeIntervalSinceReferenceDate: 1_000)

    func testLinkedProfileReturnsAlreadySelectedProfileInsteadOfSigningOut() {
        let selected = profile("selected", owner: "icloud-owner")

        let result = TeamWorkoutSnapshot.linkedProfile(
            in: [selected],
            ownerRecordName: "icloud-owner",
            currentUserID: selected.id
        )

        XCTAssertEqual(result?.id, selected.id)
    }

    func testLinkedProfilePrefersCurrentAliasOverFirstMatchingOwner() {
        let firstAlias = profile("first-alias", owner: "icloud-owner")
        let selected = profile("selected", owner: "icloud-owner")

        let result = TeamWorkoutSnapshot.linkedProfile(
            in: [firstAlias, selected],
            ownerRecordName: "icloud-owner",
            currentUserID: selected.id
        )

        XCTAssertEqual(result?.id, selected.id)
    }

    func testLinkedProfileFallsBackToOwnersFirstAliasNotAnUnownedCurrentID() {
        let wrongOwner = profile("current", owner: "someone-else")
        let firstAlias = profile("first-alias", owner: "icloud-owner")
        let secondAlias = profile("second-alias", owner: "icloud-owner")

        let result = TeamWorkoutSnapshot.linkedProfile(
            in: [wrongOwner, firstAlias, secondAlias],
            ownerRecordName: "icloud-owner",
            currentUserID: wrongOwner.id
        )

        XCTAssertEqual(result?.id, firstAlias.id)
    }

    func testLinkedProfileReturnsNilWhenAccountHasNoMatchingProfile() {
        XCTAssertNil(TeamWorkoutSnapshot.linkedProfile(
            in: [profile("current", owner: "someone-else"), profile("unclaimed", owner: nil)],
            ownerRecordName: "icloud-owner",
            currentUserID: "current"
        ))
        XCTAssertNil(TeamWorkoutSnapshot.linkedProfile(
            in: [profile("empty-owner", owner: "")],
            ownerRecordName: "",
            currentUserID: "empty-owner"
        ))
    }

    func testMissingUnsharedAndOtherTeamWorkoutsAreRemoved() {
        let removed = workout("deleted", user: "alice")
        let unshared = workout("unshared", user: "bob")
        let moved = workout("moved", user: "carol")
        let current = workout("current", user: "dave")
        var remoteUnshared = unshared
        remoteUnshared.isShared = false
        var remoteMoved = moved
        remoteMoved.teamId = "another-team"

        let result = reconcile(
            local: [removed, unshared, moved, current],
            remote: [remoteUnshared, remoteMoved, current]
        )

        XCTAssertEqual(result.map(\.id), ["current"])
    }

    func testEmptyCompleteSnapshotRemovesTeammatesButKeepsAllPersonalHistory() {
        let privateRun = workout("private", user: "me", shared: false)
        let sharedRun = workout("shared", user: "me")
        let oldPersonalRun = workout("old-personal", user: "me", offset: -1)
        let oldTeamRun = workout("old-teammate", user: "alice", offset: -1)

        let result = reconcile(
            local: [privateRun, sharedRun, oldPersonalRun, oldTeamRun, workout("team", user: "bob")],
            remote: []
        )

        XCTAssertEqual(result.map(\.id), ["old-personal", "private", "shared"])
    }

    func testSnapshotReplacesTeammateEditsAndClearsRemovedOptionalValues() {
        var old = workout("edited", user: "alice")
        old.notes = "old note"
        old.avgHR = 150
        old.zones = ZoneBreakdown(durations: [60, 0, 0, 0, 0], total: 60)
        old.restingHR = 50
        var updated = workout("edited", user: "alice")
        updated.distanceMeters = 5_000
        updated.durationSec = 1_800
        updated.runType = .tempo

        let result = reconcile(local: [old], remote: [updated])

        XCTAssertEqual(result, [updated])
        XCTAssertNil(result.first?.notes)
        XCTAssertNil(result.first?.avgHR)
        XCTAssertNil(result.first?.zones)
        XCTAssertNil(result.first?.restingHR)
    }

    func testPersonalRemoteUpdatePreservesLocalDeepLinkIdentifiers() {
        var local = workout("own", user: "me")
        local.healthKitUUID = UUID()
        local.stravaActivityId = "local-strava-activity"
        local.notes = "removed remotely"
        var remote = workout("own", user: "me")
        remote.distanceMeters = 8_000
        remote.teamId = "another-team"

        let result = reconcile(local: [local], remote: [remote])

        remote.healthKitUUID = local.healthKitUUID
        remote.stravaActivityId = local.stravaActivityId
        XCTAssertEqual(result, [remote])
        XCTAssertEqual(result.first?.stravaActivityId, "local-strava-activity")
        XCTAssertNil(result.first?.notes)
    }

    func testUnsyncedPersonalEditsWinOverRemoteSnapshot() {
        var pending = workout("own", user: "me", shared: false)
        pending.distanceMeters = 12_000
        pending.notes = "local edit"
        let staleRemote = workout("own", user: "me")

        XCTAssertEqual(reconcile(local: [pending], remote: [staleRemote]), [pending])
    }

    func testExplicitPendingEditWinsEvenWhenLocalWorkoutIsStillShared() {
        var pending = workout("own", user: "me")
        pending.distanceMeters = 12_000
        let staleRemote = workout("own", user: "me")

        let result = TeamWorkoutSnapshot.reconcile(
            local: [pending],
            remote: [staleRemote],
            currentUserID: "me",
            teamID: "team-a",
            since: since,
            preservingLocalIDs: [pending.id]
        )

        XCTAssertEqual(result, [pending])
    }

    func testPendingDeletionCannotBeResurrectedByAnInFlightSnapshot() {
        let deleted = workout("deleted", user: "me")
        let remaining = workout("remaining", user: "alice")

        let result = TeamWorkoutSnapshot.reconcile(
            local: [deleted],
            remote: [deleted, remaining],
            currentUserID: "me",
            teamID: "team-a",
            since: since,
            deletedIDs: [deleted.id]
        )

        XCTAssertEqual(result, [remaining])
    }

    func testAnotherOwnerCannotReplacePersonalWorkoutWithCollidingID() {
        let personal = workout("same-id", user: "me")
        let collision = workout("same-id", user: "alice")

        XCTAssertEqual(reconcile(local: [personal], remote: [collision]), [personal])
        XCTAssertEqual(reconcile(local: [], remote: [personal, collision]), [personal])
        XCTAssertEqual(reconcile(local: [], remote: [collision, personal]), [personal])
    }

    func testSnapshotIncludesEveryMemberAndMoreThanTwoHundredWorkouts() {
        let remote = (0..<450).map { index in
            workout("run-\(index)", user: "member-\(index % 3)", offset: Double(index))
        }

        let result = reconcile(local: [], remote: Array(remote.reversed()))

        XCTAssertEqual(result, remote)
        XCTAssertEqual(Set(result.map(\.userId)), ["member-0", "member-1", "member-2"])
    }

    func testLowerBoundIsInclusiveAndSameDateUsesStableIdentifierOrder() {
        let first = workout("a", user: "alice", offset: 0)
        let second = workout("b", user: "bob", offset: 0)
        let tooOld = workout("old", user: "carol", offset: -1)
        let last = workout("last", user: "dave", offset: 1)

        XCTAssertEqual(
            reconcile(local: [tooOld], remote: [last, second, tooOld, first]),
            [first, second, last]
        )
    }

    func testOwnRemoteWorkoutDoesNotRequireTeamSharingConsent() {
        var own = workout("own", user: "me", shared: false)
        own.teamId = "different-team"
        let notShared = workout("not-shared", user: "alice", shared: false)

        XCTAssertEqual(reconcile(local: [], remote: [notShared, own]), [own])
    }

    private func reconcile(local: [WorkoutEntry], remote: [WorkoutEntry]) -> [WorkoutEntry] {
        TeamWorkoutSnapshot.reconcile(
            local: local,
            remote: remote,
            currentUserID: "me",
            teamID: "team-a",
            since: since
        )
    }

    private func profile(_ id: String, owner: String?) -> UserProfile {
        UserProfile(
            id: id,
            displayName: id,
            initials: "AA",
            colorHex: "#34C759",
            ownerUserRecordName: owner
        )
    }

    private func workout(
        _ id: String,
        user: String,
        shared: Bool = true,
        offset: TimeInterval = 60
    ) -> WorkoutEntry {
        WorkoutEntry(
            id: id,
            userId: user,
            start: since.addingTimeInterval(offset),
            end: since.addingTimeInterval(offset + 600),
            distanceMeters: 1_609.344,
            durationSec: 600,
            avgHR: nil,
            source: "apple",
            runType: .recovery,
            isManual: false,
            isShared: shared,
            teamId: "team-a"
        )
    }
}
