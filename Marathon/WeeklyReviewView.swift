import SwiftUI

/// Reviews are requested explicitly and kept only while this screen is open.
/// Neither navigating here nor refreshing HealthKit submits data to the service.
@MainActor
struct WeeklyReviewView: View {
    let week: Date

    @EnvironmentObject private var store: WorkoutStore
    @State private var consentToSend = false
    @State private var userConfirmedData = false
    @State private var isVisible = false
    @State private var isGenerating = false
    @State private var providerConfigurationRejected = false
    @State private var errorMessage: String?
    @State private var response: WeeklyReviewResponseV1?
    @State private var submittedWorkouts: [WeeklyReviewWorkoutInput] = []
    @State private var requestToken: UUID?
    @State private var generationTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?

    private let configurationResult: Result<WeeklyReviewConfiguration, Error>

    init(week: Date) {
        self.week = week
        configurationResult = Result { try WeeklyReviewConfiguration.load() }
    }

    private var configuration: WeeklyReviewConfiguration? {
        try? configurationResult.get()
    }

    private var configurationSetupError: String? {
        if case .failure(let error) = configurationResult { return error.localizedDescription }
        return nil
    }

    private var weekStart: Date {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar.dateInterval(of: .weekOfYear, for: week)?.start ?? week
    }

    private var weekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
    }

    private var ownWorkouts: [WorkoutEntry] {
        store.workouts.filter {
            $0.userId == store.me.id && $0.start >= weekStart && $0.start < weekEnd
        }.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }

    private struct InputSnapshot: Equatable {
        let userID: String
        let ownerID: String?
        let week: Date
        let workouts: [WorkoutEntry]
        let plan: PlanSplit
        let requiredRuns: Int
        let breakReason: BreakReason
        let hasNote: Bool
    }

    private var inputSnapshot: InputSnapshot {
        InputSnapshot(
            userID: store.me.id, ownerID: store.me.ownerUserRecordName,
            week: weekStart, workouts: ownWorkouts,
            plan: store.weeklyPlan(for: weekStart).suggested,
            requiredRuns: store.weekSummary(for: weekStart).requiredRuns,
            breakReason: store.weekBreaks[weekStart]?.reason ?? .none,
            hasNote: !(store.weekBreaks[weekStart]?.notes ?? "").isEmpty
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                weekSection
                workoutSection
                consentSection
                actionSection

                if let response {
                    reviewSection(response, proxy: proxy)
                    qualitySection(response)
                    metricsSection(response)
                }

                Section {
                    Text("A training recap, not medical advice or a personalized training prescription. Check the recorded metrics and your own context before acting on a review.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AthensTheme.cardGradient)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AthensTheme.backgroundGradient.ignoresSafeArea())
            .tint(AthensTheme.goldAccent)
            .navigationTitle("Weekly AI Review")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                refreshTask?.cancel()
                refreshTask = nil
                invalidateReview()
            }
            .onChange(of: inputSnapshot) { _, _ in invalidateReview() }
            .onChange(of: configuration) { _, _ in
                providerConfigurationRejected = false
                invalidateReview()
            }
            .onChange(of: consentToSend) { _, allowed in
                if !allowed { clearGeneratedReview() }
            }
            .onChange(of: userConfirmedData) { _, _ in clearGeneratedReview() }
        }
    }

    private var weekSection: some View {
        Section {
            Text("Week of \(weekStart.formatted(date: .abbreviated, time: .omitted))")
                .font(.headline)
            Text("Only your workouts in this selected week are included. Refresh first, then check the list before requesting a review.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button(action: refreshWorkouts) {
                HStack {
                    if store.isPreparingWeeklyReviewData { ProgressView() }
                    Label("Refresh workout data", systemImage: "arrow.clockwise")
                }
            }
            .disabled(!store.hasActiveProfile || store.isPreparingWeeklyReviewData || isGenerating)

            if let imported = store.weeklyReviewImport,
               imported.userID == store.me.id, imported.weekStart == weekStart {
                if imported.succeeded, let completedAt = imported.completedAt {
                    Text("Import finished \(completedAt.formatted(date: .omitted, time: .shortened)). AI commentary requires an import within the last 15 minutes and your confirmation. Apple Health cannot confirm that every read permission was granted; check your workout list.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("The latest import did not finish. A review will be limited to the available recorded metrics.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                }
            } else {
                Text("An import within the last 15 minutes and your confirmation are needed for AI commentary. Otherwise the service returns metrics only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !store.hasActiveProfile {
                Text("Complete profile setup before requesting a review.")
                    .font(.footnote)
            }
        }
        .listRowBackground(AthensTheme.cardGradient)
    }

    private var workoutSection: some View {
        Section("Check your selected week") {
            LabeledContent("Recorded workouts", value: "\(ownWorkouts.count)")
            LabeledContent("Recorded distance", value: "\(ownWorkouts.reduce(0) { $0 + $1.miles }.formatted(.number.precision(.fractionLength(1)))) mi")
            Text("Health imports include running and walking workouts lasting at least 8 minutes, with pace no slower than 15 minutes per mile. Shorter or slower workouts may be absent; manual entries are included.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Refresh adds newly found workouts; it does not reconcile edits or deletions in Apple Health. Check distances and durations too, and correct stale entries in the app before confirming.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            DisclosureGroup("Workout list") {
                if ownWorkouts.isEmpty {
                    Text("No workouts are currently recorded for this week. This does not prove that no workouts took place.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(ownWorkouts) { workout in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(workout.start.formatted(date: .abbreviated, time: .omitted)) · \(workout.runType.rawValue.capitalized)")
                        Text("\(workout.miles.formatted(.number.precision(.fractionLength(1)))) mi · \((workout.durationSec / 60).formatted(.number.precision(.fractionLength(0)))) min")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle("I checked this week's workout list; it includes all workouts I want reviewed.", isOn: $userConfirmedData)
                .font(.subheadline)
                .disabled(store.isPreparingWeeklyReviewData || isGenerating || !store.hasActiveProfile)
        }
        .listRowBackground(AthensTheme.cardGradient)
    }

    private var consentSection: some View {
        Section("Where your data goes") {
            if let configuration {
                LabeledContent("AI provider", value: configuration.provider.displayName)
                LabeledContent("Service host", value: configuration.endpoint.host ?? "Unknown")
                Text(configuration.endpoint.absoluteString)
                    .font(.caption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            } else {
                Label("Review service is not configured", systemImage: "gearshape")
                    .font(.headline)
                if let configurationSetupError {
                    Text(configurationSetupError).font(.footnote)
                }
                Text("Set WEEKLY_REVIEW_API_BASE_URL to your HTTPS Python service and WEEKLY_REVIEW_PROVIDER to azure or openai in the app's local build configuration. Both must match your service setup. No data can be submitted until configured.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("For this request, the Python service receives workout dates, distances, durations, run types and sources; your selected week's plan; optional average heart rate and zone totals; and timezone/import status. Break categories and notes are not sent because their saved ownership is unverified; weeks with saved break context get metrics only.")
                .font(.footnote)
            Text("No name, profile ID, note text, routes, raw heart-rate samples or teammates' workouts are included in the review payload. Sign in with Apple sends an identity token only to this service for authentication; it is not sent to the AI provider.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let configuration {
                Text("\(configuration.provider.displayName) receives derived metrics and data-quality context for the recap when AI commentary is available.")
                    .font(.footnote)
                if configuration.provider == .openai {
                    Text("This uses the OpenAI API, separately from any ChatGPT subscription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("I agree to send this selected week's data to this service and \(configuration.provider.displayName) when I tap Generate Review.", isOn: $consentToSend)
                    .font(.subheadline)
                    .disabled(!store.hasActiveProfile || store.isPreparingWeeklyReviewData)
            }
            Text("Reviews are not saved by this app. Turning consent off clears the displayed result and cancels any pending request; it cannot retract data already sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(AthensTheme.cardGradient)
    }

    private var actionSection: some View {
        Section {
            if isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Authenticating and requesting your review…")
                        .font(.subheadline)
                }
                Button("Cancel", role: .cancel) { clearGeneratedReview() }
            } else if response != nil {
                Button("Clear review to request another") { invalidateReview() }
            } else {
                Button(action: generateReview) {
                    Label(errorMessage == nil ? "Generate Review" : "Retry Review", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .disabled(configuration == nil || !consentToSend || !store.hasActiveProfile || store.isPreparingWeeklyReviewData || providerConfigurationRejected)
            }

            if providerConfigurationRejected {
                Label(WeeklyReviewClientError.providerChanged.localizedDescription, systemImage: "gearshape")
                    .font(.footnote)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            }
        }
        .listRowBackground(AthensTheme.cardGradient)
    }

    private func reviewSection(_ result: WeeklyReviewResponseV1, proxy: ScrollViewProxy) -> some View {
        Section(result.fallbackUsed ? "Metrics only — AI unavailable or limited data" : "AI-generated recap") {
            Text(result.fallbackUsed
                 ? "This is a deterministic summary, not AI-generated commentary."
                 : "Commentary is AI-generated; the numeric metrics below are calculated by the service.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            reviewItem(result.review.headline, metrics: result.metrics, proxy: proxy)
            ForEach(Array(result.review.items.enumerated()), id: \.offset) { _, item in
                reviewItem(item, metrics: result.metrics, proxy: proxy)
            }
            if result.review.nextFocus.text != result.review.headline.text {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next focus").font(.subheadline.weight(.semibold))
                    reviewItem(result.review.nextFocus, metrics: result.metrics, proxy: proxy)
                }
            }
        }
        .listRowBackground(AthensTheme.cardGradient)
    }

    private func reviewItem(_ item: WeeklyReviewItem, metrics: [WeeklyReviewMetric], proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.text)
            ForEach(item.evidenceIDs, id: \.self) { metricID in
                if let metric = metrics.first(where: { $0.id == metricID }) {
                    Button {
                        withAnimation { proxy.scrollTo(metricID, anchor: .center) }
                    } label: {
                        Label("\(metricTitle(metric.id)): \(metricValue(metric))", systemImage: "link")
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AthensTheme.goldAccent)
                    .accessibilityHint("Show the supporting calculated metric")
                }
            }
        }
    }

    private func qualitySection(_ result: WeeklyReviewResponseV1) -> some View {
        Section("Data quality") {
            LabeledContent("Review status", value: statusLabel(result))
            ForEach(result.dataQualityCodes, id: \.self) { code in
                Label(qualityLabel(code), systemImage: "info.circle")
                    .font(.footnote)
            }
        }
        .listRowBackground(AthensTheme.cardGradient)
    }

    private func metricsSection(_ result: WeeklyReviewResponseV1) -> some View {
        Section("Recorded metrics — calculated, not generated") {
            ForEach(result.metrics, id: \.id) { metric in
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(metricTitle(metric.id), value: metricValue(metric))
                    if !metric.sourceEvidenceIDs.isEmpty {
                        DisclosureGroup("Source workouts (\(metric.sourceEvidenceIDs.count))") {
                            ForEach(metric.sourceEvidenceIDs, id: \.self) { evidenceID in
                                if let workout = submittedWorkouts.first(where: { $0.evidenceID == evidenceID }) {
                                    Text("\(workout.startedOn) · \(workout.runType.rawValue.capitalized) · \(workout.distanceMiles.formatted(.number.precision(.fractionLength(1)))) mi")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
                .id(metric.id)
            }
            Text("Qualifying runs count workouts of at least one mile. Heart-rate coverage is the fraction of recorded workout duration with an average heart rate, not proof of continuous sample coverage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(AthensTheme.cardGradient)
    }

    private func refreshWorkouts() {
        invalidateReview()
        refreshTask?.cancel()
        refreshTask = Task {
            await store.prepareWeeklyReviewData(for: weekStart)
            refreshTask = nil
        }
    }

    private func generateReview() {
        guard let configuration, consentToSend, store.hasActiveProfile,
              !store.isPreparingWeeklyReviewData, !isGenerating, !providerConfigurationRejected else { return }
        clearGeneratedReview()
        let token = UUID()
        let snapshot = inputSnapshot
        requestToken = token
        isGenerating = true

        generationTask = Task { @MainActor in
            do {
                guard isVisible, requestToken == token, consentToSend,
                      inputSnapshot == snapshot, self.configuration == configuration else { throw CancellationError() }
                let confirmedData = userConfirmedData
                let request = try store.makeWeeklyReviewRequest(for: snapshot.week, userConfirmedData: confirmedData)
                let result = try await WeeklyReviewClient(configuration: configuration).generate(request, authorizeTransmission: {
                    guard isVisible, requestToken == token, consentToSend,
                          userConfirmedData == confirmedData, inputSnapshot == snapshot,
                          self.configuration == configuration else { throw CancellationError() }
                })
                try Task.checkCancellation()
                guard isVisible, requestToken == token, consentToSend,
                      inputSnapshot == snapshot, self.configuration == configuration else { return }
                submittedWorkouts = request.workouts
                response = result
                isGenerating = false
                generationTask = nil
            } catch {
                guard !Task.isCancelled, isVisible, requestToken == token,
                      consentToSend, inputSnapshot == snapshot, self.configuration == configuration else { return }
                if let clientError = error as? WeeklyReviewClientError, clientError == .providerChanged {
                    providerConfigurationRejected = true
                    errorMessage = nil
                } else if let authorizationError = error as? WeeklyReviewAuthorizationError,
                   authorizationError == .cancelled {
                    errorMessage = nil
                } else if case WeeklyReviewRequestBuildError.invalidWorkout = error {
                    errorMessage = "A recorded workout contains invalid distance or duration data. Check the selected week's workouts before retrying."
                } else {
                    errorMessage = error.localizedDescription
                }
                isGenerating = false
                generationTask = nil
            }
        }
    }

    private func invalidateReview() {
        userConfirmedData = false
        consentToSend = false
        clearGeneratedReview()
    }

    private func clearGeneratedReview() {
        generationTask?.cancel()
        generationTask = nil
        requestToken = nil
        isGenerating = false
        errorMessage = nil
        response = nil
        submittedWorkouts = []
    }

    private func statusLabel(_ result: WeeklyReviewResponseV1) -> String {
        switch result.status {
        case .complete: return "Available-data review complete"
        case .limitedData: return "Limited data or context"
        case .insufficientData: return "Workout completeness unconfirmed"
        case .unavailable: return "AI service unavailable"
        }
    }

    private func qualityLabel(_ code: String) -> String {
        switch code {
        case "healthkit_unknown": return "The selected week's workout completeness has not been confirmed."
        case "healthkit_failed": return "The latest workout import failed; recorded metrics may be incomplete."
        case "healthkit_not_authorized": return "Apple Health workout data is unavailable; recorded metrics may be incomplete."
        case "plan_missing": return "A training plan is missing for this week."
        case "current_week_in_progress": return "This week is still in progress; these are not final weekly totals."
        case "hr_coverage_low": return "Heart-rate coverage is limited; no conclusion about your fitness or recovery is supported."
        case "break_context_present": return "A break was recorded; the service will not infer medical causes or prescribe training."
        case "provider_unavailable": return "The AI provider is unavailable. Recorded metrics are still shown."
        case "provider_response_rejected", "invalid_model_response": return "The AI response did not pass validation. Only recorded metrics are shown."
        case "model_not_configured": return "The AI provider has not been configured on the service."
        default: return "The service reported an additional data-quality limitation (\(code.replacingOccurrences(of: "_", with: " ")))."
        }
    }

    private func metricTitle(_ id: String) -> String {
        switch id {
        case "m.data.healthkit_sync_state": return "Workout data status"
        case "m.data.week_state": return "Week status"
        case "m.data.workout_count": return "Recorded workouts"
        case "m.data.plan_available": return "Plan available"
        case "m.current.actual_miles": return "Recorded distance"
        case "m.current.actual_runs": return "Qualifying runs"
        case "m.current.duration_seconds": return "Recorded duration"
        case "m.current.weighted_pace_sec_per_mile": return "Distance-weighted pace"
        case "m.hr.coverage": return "Heart-rate coverage"
        case "m.current.planned_miles": return "Planned distance"
        case "m.current.required_runs": return "Required runs"
        case "m.vo2.latest": return "Latest recorded VO₂ max"
        default: return id.replacingOccurrences(of: "m.", with: "").replacingOccurrences(of: "_", with: " ")
        }
    }

    private func metricValue(_ metric: WeeklyReviewMetric) -> String {
        switch metric.value {
        case .null: return "Not available"
        case .boolean(let value): return value ? "Yes" : "No"
        case .text(let value):
            if metric.id == "m.data.healthkit_sync_state", value == "complete" { return "Imported and user-confirmed" }
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        case .number(let value):
            guard value.isFinite else { return "Not available" }
            switch metric.unit {
            case "fraction": return (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
            case "s": return (value / 60).formatted(.number.precision(.fractionLength(1))) + " min"
            case "s/mi":
                guard value >= 0, value < Double(Int.max) else { return "Not available" }
                let seconds = Int(value.rounded())
                return "\(seconds / 60):\(String(format: "%02d", seconds % 60)) /mi"
            case "workouts", "runs": return value.formatted(.number.precision(.fractionLength(0)))
            default: return "\(value.formatted(.number.precision(.fractionLength(0...2)))) \(metric.unit)"
            }
        }
    }
}
