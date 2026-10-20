import Foundation

/// Device-local, short-lived evidence of a selected-week import. Never sent
/// wholesale to the API, and never inferred from a permission dialog alone.
struct WeeklyReviewImportRecord: Equatable {
    let userID: String
    let weekStart: Date
    let completedAt: Date?
    let succeeded: Bool

    func syncState(userID: String, weekStart: Date, userConfirmedData: Bool,
                   now: Date) -> WeeklyReviewHealthKitSyncState {
        guard self.userID == userID, self.weekStart == weekStart else { return .unknown }
        guard succeeded else { return .failed }
        guard userConfirmedData, let completedAt,
              completedAt <= now, now.timeIntervalSince(completedAt) <= 15 * 60 else { return .unknown }
        return .complete
    }
}

/// Wire-only input contract for the weekly-review service. These types are
/// intentionally separate from `WorkoutEntry`: the service must never receive
/// a HealthKit ID, CloudKit ID, user/profile ID, note, route, raw heart-rate
/// sample, or other incidental app-model field.
enum WeeklyReviewHealthKitSyncState: String, Codable, Equatable, Sendable {
    case complete
    case notAuthorized = "not_authorized"
    case unknown
    case failed
}

enum WeeklyReviewWeekState: String, Codable, Equatable, Sendable {
    case inProgress = "in_progress"
    case complete
}

enum WeeklyReviewRunType: String, Codable, Equatable, Sendable {
    case recovery
    case tempo
    case long
    case other
}

enum WeeklyReviewWorkoutSource: String, Codable, Equatable, Sendable {
    case healthKit = "healthkit"
    case strava
    case manual
}

enum WeeklyReviewBreakReason: String, Codable, Equatable, Sendable {
    case none
    case illness
    case injury
    case travel
    case life
    case other
}

struct WeeklyReviewDataFreshness: Codable, Equatable, Sendable {
    var healthKitSyncState: WeeklyReviewHealthKitSyncState
    var lastSuccessfulImportAt: String?

    enum CodingKeys: String, CodingKey {
        case healthKitSyncState = "healthkit_sync_state"
        case lastSuccessfulImportAt = "last_successful_import_at"
    }
}

struct WeeklyReviewPlannedMiles: Codable, Equatable, Sendable {
    var recovery: Double
    var tempo: Double
    var long: Double
}

struct WeeklyReviewPlanWeek: Codable, Equatable, Sendable {
    var weekStart: String
    var requiredMiles: Double
    var requiredRuns: Int
    var plannedMilesByType: WeeklyReviewPlannedMiles

    enum CodingKeys: String, CodingKey {
        case weekStart = "week_start"
        case requiredMiles = "required_miles"
        case requiredRuns = "required_runs"
        case plannedMilesByType = "planned_miles_by_type"
    }
}

struct WeeklyReviewZoneSeconds: Codable, Equatable, Sendable {
    var z1: Double
    var z2: Double
    var z3: Double
    var z4: Double
    var z5: Double
}

struct WeeklyReviewWorkoutInput: Codable, Equatable, Sendable {
    var evidenceID: String
    var weekStart: String
    var startedOn: String
    var runType: WeeklyReviewRunType
    var distanceMiles: Double
    var durationSeconds: Double
    var averageHeartRateBPM: Double?
    var zoneSeconds: WeeklyReviewZoneSeconds?
    var source: WeeklyReviewWorkoutSource

    enum CodingKeys: String, CodingKey {
        case evidenceID = "evidence_id"
        case weekStart = "week_start"
        case startedOn = "started_on"
        case runType = "run_type"
        case distanceMiles = "distance_miles"
        case durationSeconds = "duration_seconds"
        case averageHeartRateBPM = "avg_hr_bpm"
        case zoneSeconds = "zone_seconds"
        case source
    }
}

struct WeeklyReviewPhysiology: Codable, Equatable, Sendable {
    var latestVO2MaxMLKgMin: Double?
    var latestVO2MaxObservedOn: String?

    enum CodingKeys: String, CodingKey {
        case latestVO2MaxMLKgMin = "latest_vo2_max_ml_kg_min"
        case latestVO2MaxObservedOn = "latest_vo2_max_observed_on"
    }
}

struct WeeklyReviewBreakContext: Codable, Equatable, Sendable {
    var reason: WeeklyReviewBreakReason
    var hasNote: Bool

    enum CodingKeys: String, CodingKey {
        case reason
        case hasNote = "has_note"
    }
}

struct WeeklyReviewRequestV1: Codable, Equatable, Sendable {
    static let schemaVersion = "weekly-review-input/v1"

    var schemaVersion: String = WeeklyReviewRequestV1.schemaVersion
    var requestID: UUID
    var reviewedWeekStart: String
    var generatedAt: String
    var timezone: String
    var weekState: WeeklyReviewWeekState
    var dataFreshness: WeeklyReviewDataFreshness
    var plans: [WeeklyReviewPlanWeek]
    var workouts: [WeeklyReviewWorkoutInput]
    var physiology: WeeklyReviewPhysiology?
    var breakContext: WeeklyReviewBreakContext

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case reviewedWeekStart = "reviewed_week_start"
        case generatedAt = "generated_at"
        case timezone
        case weekState = "week_state"
        case dataFreshness = "data_freshness"
        case plans
        case workouts
        case physiology
        case breakContext = "break_context"
    }
}

/// Local-only inputs. `WorkoutEntry` and `userID` are consumed here, never
/// embedded in `WeeklyReviewRequestV1`.
struct WeeklyReviewBuildInput {
    var userID: String
    var reviewedWeek: Date
    var workouts: [WorkoutEntry]
    var plan: PlanSplit
    var requiredRuns: Int
    var healthKitSyncState: WeeklyReviewHealthKitSyncState
    var lastSuccessfulImportAt: Date?
    var latestVO2Max: Double?
    var latestVO2MaxObservedOn: Date?
    var breakReason: BreakReason
    var hasBreakNote: Bool
    var timezone: TimeZone
    var generatedAt: Date
    var requestID: UUID

    init(userID: String,
         reviewedWeek: Date,
         workouts: [WorkoutEntry],
         plan: PlanSplit,
         requiredRuns: Int,
         healthKitSyncState: WeeklyReviewHealthKitSyncState,
         lastSuccessfulImportAt: Date?,
         latestVO2Max: Double?,
         latestVO2MaxObservedOn: Date?,
         breakReason: BreakReason,
         hasBreakNote: Bool,
         timezone: TimeZone = .current,
         generatedAt: Date = Date(),
         requestID: UUID = UUID()) {
        self.userID = userID
        self.reviewedWeek = reviewedWeek
        self.workouts = workouts
        self.plan = plan
        self.requiredRuns = requiredRuns
        self.healthKitSyncState = healthKitSyncState
        self.lastSuccessfulImportAt = lastSuccessfulImportAt
        self.latestVO2Max = latestVO2Max
        self.latestVO2MaxObservedOn = latestVO2MaxObservedOn
        self.breakReason = breakReason
        self.hasBreakNote = hasBreakNote
        self.timezone = timezone
        self.generatedAt = generatedAt
        self.requestID = requestID
    }
}

enum WeeklyReviewRequestBuildError: LocalizedError, Equatable {
    case missingUser
    case futureWeek
    case invalidPlan
    case invalidRequiredRuns
    case invalidImportTimestamp
    case tooManyWorkouts
    case invalidWorkout(id: String)

    var errorDescription: String? {
        switch self {
        case .missingUser:
            return "A signed-in profile is required to build a weekly review."
        case .futureWeek:
            return "A weekly review cannot be created for a future week."
        case .invalidPlan:
            return "The selected week has an invalid training plan."
        case .invalidRequiredRuns:
            return "The selected week has an invalid required-run count."
        case .invalidImportTimestamp:
            return "The review import timestamp is invalid."
        case .tooManyWorkouts:
            return "A weekly review supports at most 80 workouts. No workouts were silently omitted."
        case .invalidWorkout(let id):
            return "Workout '\(id)' has invalid review data."
        }
    }
}

/// The one allowlisted path from local health-derived records to the backend
/// wire model. It is pure so its privacy boundary can be unit-tested without a
/// live backend, Azure resource, or HealthKit access.
enum WeeklyReviewRequestBuilder {
    static func build(_ input: WeeklyReviewBuildInput) throws -> WeeklyReviewRequestV1 {
        let userID = input.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, userID != "me" else {
            throw WeeklyReviewRequestBuildError.missingUser
        }

        let calendar = isoCalendar(timezone: input.timezone)
        let reviewedWeek = calendar.dateInterval(of: .weekOfYear, for: input.reviewedWeek)?.start
            ?? calendar.startOfDay(for: input.reviewedWeek)
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: input.generatedAt)?.start
            ?? calendar.startOfDay(for: input.generatedAt)
        guard reviewedWeek <= currentWeek else {
            throw WeeklyReviewRequestBuildError.futureWeek
        }

        guard validPlan(input.plan) else {
            throw WeeklyReviewRequestBuildError.invalidPlan
        }
        guard (0...14).contains(input.requiredRuns) else {
            throw WeeklyReviewRequestBuildError.invalidRequiredRuns
        }
        if let lastSuccessfulImportAt = input.lastSuccessfulImportAt,
           lastSuccessfulImportAt > input.generatedAt {
            throw WeeklyReviewRequestBuildError.invalidImportTimestamp
        }

        let weekEnd = calendar.date(byAdding: .day, value: 7, to: reviewedWeek)
            ?? reviewedWeek.addingTimeInterval(7 * 24 * 60 * 60)
        let selectedWorkouts = input.workouts
            .filter { workout in
                workout.userId == userID
                    && workout.start >= reviewedWeek
                    && workout.start < weekEnd
            }
            .sorted { lhs, rhs in lhs.start < rhs.start }
        guard selectedWorkouts.count <= 80 else { throw WeeklyReviewRequestBuildError.tooManyWorkouts }
        let reviewedWorkouts = try selectedWorkouts.map { workout in
                guard workout.start <= input.generatedAt, workout.end <= input.generatedAt,
                      workout.end >= workout.start else {
                    throw WeeklyReviewRequestBuildError.invalidWorkout(id: workout.id)
                }
                return try makeWorkout(workout, weekStart: reviewedWeek, calendar: calendar)
            }

        let weekState: WeeklyReviewWeekState = reviewedWeek == currentWeek ? .inProgress : .complete
        let weekStartString = dayString(reviewedWeek, timezone: input.timezone)
        let planMiles = WeeklyReviewPlannedMiles(recovery: input.plan.recovery,
                                                  tempo: input.plan.tempo,
                                                  long: input.plan.long)
        let plan = WeeklyReviewPlanWeek(weekStart: weekStartString,
                                        requiredMiles: input.plan.recovery + input.plan.tempo + input.plan.long,
                                        requiredRuns: input.requiredRuns,
                                        plannedMilesByType: planMiles)

        let physiology: WeeklyReviewPhysiology?
        if let vo2 = input.latestVO2Max, vo2.isFinite, (10...100).contains(vo2),
           let observedOn = input.latestVO2MaxObservedOn, observedOn <= input.generatedAt,
           observedOn < weekEnd {
            physiology = WeeklyReviewPhysiology(
                latestVO2MaxMLKgMin: vo2,
                latestVO2MaxObservedOn: dayString(observedOn, timezone: input.timezone)
            )
        } else {
            physiology = nil
        }

        return WeeklyReviewRequestV1(
            requestID: input.requestID,
            reviewedWeekStart: weekStartString,
            generatedAt: timestampString(input.generatedAt, timezone: input.timezone),
            timezone: input.timezone.identifier,
            weekState: weekState,
            dataFreshness: WeeklyReviewDataFreshness(
                healthKitSyncState: input.healthKitSyncState,
                lastSuccessfulImportAt: input.lastSuccessfulImportAt.map {
                    timestampString($0, timezone: input.timezone)
                }
            ),
            plans: [plan],
            workouts: reviewedWorkouts,
            physiology: physiology,
            breakContext: WeeklyReviewBreakContext(
                reason: WeeklyReviewBreakReason(rawValue: input.breakReason.rawValue) ?? .other,
                hasNote: input.hasBreakNote
            )
        )
    }

    private static func makeWorkout(_ workout: WorkoutEntry,
                                    weekStart: Date,
                                    calendar: Calendar) throws -> WeeklyReviewWorkoutInput {
        let miles = workout.miles
        guard miles.isFinite, miles > 0, miles <= 200,
              workout.durationSec.isFinite, workout.durationSec > 0, workout.durationSec <= 86_400 else {
            throw WeeklyReviewRequestBuildError.invalidWorkout(id: workout.id)
        }

        let averageHeartRate: Double?
        if let value = workout.avgHR, value.isFinite, (30...260).contains(value) {
            averageHeartRate = value
        } else {
            averageHeartRate = nil
        }

        return WeeklyReviewWorkoutInput(
            evidenceID: "w-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            weekStart: dayString(weekStart, timezone: calendar.timeZone),
            startedOn: dayString(workout.start, timezone: calendar.timeZone),
            runType: WeeklyReviewRunType(rawValue: workout.runType.rawValue) ?? .other,
            distanceMiles: miles,
            durationSeconds: workout.durationSec,
            averageHeartRateBPM: averageHeartRate,
            zoneSeconds: validZones(workout.zones, duration: workout.durationSec),
            source: source(for: workout)
        )
    }

    private static func validPlan(_ plan: PlanSplit) -> Bool {
        let values = [plan.recovery, plan.tempo, plan.long]
        return values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 200 }
            && values.reduce(0, +) <= 200
    }

    private static func validZones(_ zones: ZoneBreakdown?, duration: Double) -> WeeklyReviewZoneSeconds? {
        guard let zones, zones.durations.count == 5 else { return nil }
        let values: [Double] = zones.durations.map { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.reduce(0, +) <= duration + 0.000_001 else {
            return nil
        }
        return WeeklyReviewZoneSeconds(z1: values[0], z2: values[1], z3: values[2], z4: values[3], z5: values[4])
    }

    private static func source(for workout: WorkoutEntry) -> WeeklyReviewWorkoutSource {
        if workout.isManual { return .manual }
        let source = workout.source.lowercased()
        return source.contains("strava") ? .strava : .healthKit
    }

    private static func isoCalendar(timezone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timezone
        return calendar
    }

    private static func dayString(_ date: Date, timezone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timestampString(_ date: Date, timezone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timezone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
