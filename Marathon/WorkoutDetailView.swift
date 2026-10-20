import SwiftUI
#if canImport(Charts)
import Charts
#endif
import HealthKit
#if canImport(MapKit)
import MapKit
#endif

struct WorkoutDetailView: View {
    @EnvironmentObject var store: WorkoutStore
    private let initialWorkout: WorkoutEntry

    init(workout: WorkoutEntry) {
        initialWorkout = workout
    }

    private var liveWorkout: WorkoutEntry? {
        store.workouts.first(where: { $0.id == initialWorkout.id })
    }

    // The snapshot supplies only a stable identity once this screen is open.
    // Visible content is hidden if the record is deleted or no longer shared.
    private var workout: WorkoutEntry { liveWorkout ?? initialWorkout }

    private struct DetailLoadKey: Equatable {
        let workout: WorkoutEntry?
        let viewerID: String
    }

    private var detailLoadKey: DetailLoadKey {
        DetailLoadKey(workout: liveWorkout, viewerID: store.me.id)
    }

    @State private var hrPoints: [HRPoint] = []
    @State private var zone: ZoneBreakdown = ZoneBreakdown()
    @State private var isLoading = true
    @State private var error: String?

    // Route state
    @State private var routeCoords: [CLLocationCoordinate2D] = []
    @State private var isRouteLoading = true
    @State private var routeError: String?

    // Resting HR for HRR segments
    @State private var restingHR: Int = 60

    // Likes state
    @State private var likes: [WorkoutLike] = []
    @State private var isLikesLoading = true
    @State private var likesError: String?

    private var isMine: Bool { workout.userId == store.me.id }
    private var likeCount: Int { max(0, store.likeCountByWorkout[workout.id] ?? likes.count) }
    private var didLike: Bool { store.didILikeByWorkout[workout.id] ?? false }
    private var likeToggleInFlight: Bool { store.likeToggleInFlight.contains(workout.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if liveWorkout != nil {
                    summaryCard
                    likesCard
                    routeMapCard
                    hrChartCard
                    zonesCard
                    if let notes = workout.notes, !notes.isEmpty {
                        notesCard(notes: notes)
                    }
                } else {
                    Text("This workout is no longer available. It may have been deleted or is no longer shared.")
                        .foregroundStyle(AthensTheme.marbleWhite)
                }
            }
            .padding()
        }
        .navigationTitle("Workout Details")
        .navigationBarTitleDisplayMode(.inline)
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .refreshable { await store.refreshFromCloud() }
        .task(id: detailLoadKey) { await loadData(for: detailLoadKey) }
        .task(id: detailLoadKey) { await loadLikes() }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveCloudKitPush)) { note in
            // Best-effort refresh likes if a like push arrives for this owner (no-op if not for this workout)
            Task {
                if let sub = note.userInfo?["subscriptionID"] as? String,
                   sub.hasPrefix("likes_to_") || sub.hasPrefix("likes_sync_") {
                    await loadLikes()
                }
            }
        }
        .onReceive(store.$likeCountByWorkout) { map in
            let current = map[workout.id] ?? 0
            if !isLikesLoading, current != likes.count {
                Task { await loadLikes() }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text(workout.isManual ? "Sus Run" : workout.source.capitalized)
                    .font(.subheadline)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
            }

            HStack(spacing: 12) {
                metric(label: "Distance", value: String(format: "%.2f mi", metersToMiles(workout.distanceMeters)))
                metric(label: "Duration", value: secToHMS(workout.durationSec))
                if let p = workout.paceSecPerMile {
                    metric(label: "Pace", value: paceString(p))
                }
                if let avg = displayedAvgHR {
                    metric(label: "Avg HR", value: String(format: "%.0f bpm", avg))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    // Likes card
    @ViewBuilder
    private var likesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "heart")
                    .foregroundStyle(AthensTheme.terracotta)
                Text("Likes")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                if isLikesLoading {
                    ProgressView()
                }
                Button {
                    guard !store.me.id.isEmpty else { return }
                    Task {
                        await store.toggleLike(for: workout)
                        await loadLikes()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: didLike ? "heart.fill" : "heart")
                            .foregroundStyle(didLike ? AthensTheme.terracotta : AthensTheme.marbleWhite)
                        Text("\(likeCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .disabled(likeToggleInFlight || store.me.id.isEmpty)
            }

            if let err = likesError {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red)
            } else if !isLikesLoading && likes.isEmpty {
                Text("No likes yet.")
                    .font(.footnote)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
            } else if !likes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(likes) { like in
                        HStack(spacing: 8) {
                            let name = displayName(for: like.fromUserId)
                            let color = colorForUser(id: like.fromUserId)
                            ZStack {
                                Circle()
                                    .fill(color)
                                    .frame(width: 18, height: 18)
                                Text(initials(for: like.fromUserId))
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(.white)
                            }
                            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 0.5))

                            Text(name)
                                .foregroundColor(AthensTheme.marbleWhite)
                                .font(.subheadline.weight(.semibold))

                            Spacer()
                            Text(relativeString(to: like.createdAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.75))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    @ViewBuilder
    private var routeMapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "map")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("Route")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                if isRouteLoading { ProgressView() }
            }

            if let err = routeError {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red)
            }

            #if canImport(MapKit)
            if !routeCoords.isEmpty {
                if #available(iOS 17.0, macOS 14.0, *) {
                    Map(initialPosition: .region(regionForCoordinates(routeCoords))) {
                        MapPolyline(coordinates: routeCoords)
                            .stroke(AthensTheme.goldAccent, lineWidth: 4)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("Route map requires the latest OS.")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                }
            } else if !isRouteLoading && routeError == nil {
                Text(isMine ? "No route available for this workout." : "Route maps are available only for your own workouts.")
                    .font(.footnote)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
            }
            #else
            Text("Map not available on this platform.")
                .font(.footnote)
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
            #endif
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    @ViewBuilder
    private var hrChartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").foregroundStyle(AthensTheme.goldAccent)
                Text("Heart Rate")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                if isLoading && isMine { ProgressView() }
            }

            if let err = error, isMine {
                Text(err).font(.footnote).foregroundColor(.red)
            }

            #if canImport(Charts)
            if isMine {
                if !hrPoints.isEmpty {
                    let maxHR = HealthKitManager.shared.estimateMaxHR()
                    let segments = makeSegments(points: hrPoints, maxHR: maxHR, restingHR: restingHR)

                    Chart {
                        // 1) Base continuous line to keep the path visually contiguous across zone changes
                        ForEach(hrPoints) { pt in
                            LineMark(
                                x: .value("Time", pt.time),
                                y: .value("BPM", pt.bpm)
                            )
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.white.opacity(0.28))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                        }

                        // 2) Colored segments layered on top (per contiguous zone group)
                        ForEach(segments) { seg in
                            ForEach(seg.points) { pt in
                                LineMark(
                                    x: .value("Time", pt.time),
                                    y: .value("BPM", pt.bpm),
                                    series: .value("Segment", seg.id)
                                )
                                .interpolationMethod(.monotone)
                                .foregroundStyle(zoneColor(seg.zoneIndex))
                                .lineStyle(StrokeStyle(lineWidth: 2.2))
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 180)
                } else if !isLoading {
                    Text("No heart rate samples found.")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                }
            } else {
                let sharedPct = zone.percentages
                let hasSharedZones = zone.total > 0 && sharedPct.contains(where: { $0 > 0 })

                if hasSharedZones {
                    Chart {
                        ForEach(Array(sharedPct.prefix(5).enumerated()), id: \.offset) { idx, pct in
                            BarMark(
                                x: .value("Zone", "Z\(idx + 1)"),
                                y: .value("Percent", pct * 100)
                            )
                            .foregroundStyle(zoneColor(idx))
                            .cornerRadius(4)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 180)

                    HStack(spacing: 8) {
                        Text("Shared HR profile")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                        if let avg = workout.avgHR {
                            Text("•")
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.55))
                            Text(String(format: "Avg %.0f bpm", avg))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                        }
                    }
                } else if let avg = workout.avgHR {
                    Text(String(format: "Shared average HR: %.0f bpm", avg))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                } else {
                    Text("No shared heart rate data available for this run.")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                }
            }
            #else
            Text("Heart rate chart requires iOS 16 (Charts).")
                .font(.footnote)
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
            #endif
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    private var zonesCard: some View {
        let pct = zone.percentages
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("HR Zones")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
            }

            ZoneBar(percentages: pct)
                .frame(height: 8)

            VStack(spacing: 6) {
                zoneRow(label: "Z1", idx: 0, color: Color.blue.opacity(0.70))
                zoneRow(label: "Z2", idx: 1, color: Color.green.opacity(0.75))
                zoneRow(label: "Z3", idx: 2, color: AthensTheme.goldAccent.opacity(0.85))
                zoneRow(label: "Z4", idx: 3, color: AthensTheme.terracotta.opacity(0.90))
                zoneRow(label: "Z5", idx: 4, color: Color.red.opacity(0.90))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    private func notesCard(notes: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("Notes")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
            }
            Text(notes)
                .font(AthensTheme.BodyFont)
                .foregroundColor(AthensTheme.marbleWhite)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
            Text(value).font(.headline.monospacedDigit()).foregroundColor(AthensTheme.marbleWhite)
        }
    }

    private func zoneRow(label: String, idx: Int, color: Color) -> some View {
        let dur = (idx < zone.durations.count) ? zone.durations[idx] : 0
        let pct = (idx < zone.percentages.count) ? zone.percentages[idx] : 0
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.subheadline.weight(.semibold)).foregroundColor(AthensTheme.marbleWhite)
            Spacer()
            Text(String(format: "%.0f%%", pct * 100)).font(.subheadline.monospacedDigit()).foregroundColor(AthensTheme.marbleWhite)
            Text("•").foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
            Text(formatHMS(dur)).font(.subheadline.monospacedDigit()).foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
        }
    }

    // Derived

    // Prefer stored avgHR from the workout; fall back to computed average from samples
    private var displayedAvgHR: Double? {
        workout.avgHR ?? computedAvgHR
    }

    private var computedAvgHR: Double? {
        guard !hrPoints.isEmpty else { return nil }
        let sum = hrPoints.reduce(0.0) { $0 + Double($1.bpm) }
        return sum / Double(hrPoints.count)
    }

    // Data load

    @MainActor
    private func loadData(for input: DetailLoadKey) async {
        guard let entry = input.workout else { return }
        let mine = entry.userId == input.viewerID
        let initialSharedRoute = mine ? decodedSharedRoute(entry.sharedRoutePoints) : []
        isLoading = true
        error = nil
        hrPoints = []
        zone = entry.zones ?? store.zonesByWorkout[entry.id] ?? ZoneBreakdown()
        routeCoords = initialSharedRoute
        isRouteLoading = mine && entry.healthKitUUID != nil && initialSharedRoute.isEmpty
        routeError = nil
        do {
            if mine {
                try await HealthKitManager.shared.requestAuthorization()
                try Task.checkCancellation()

                let interval = DateInterval(start: entry.start, end: entry.end)
                let shouldFetchRoute = entry.healthKitUUID != nil && initialSharedRoute.isEmpty
                async let samplesTask = HealthKitManager.shared.fetchHeartRateSamples(in: interval)
                async let restingTask = HealthKitManager.shared.fetchLatestRestingHeartRate()
                async let routeTask: [CLLocationCoordinate2D] = {
                    guard shouldFetchRoute, let uuid = entry.healthKitUUID else { return [] }
                    return (try? await HealthKitManager.shared.fetchRouteCoordinates(for: uuid)) ?? []
                }()

                let samples = try await samplesTask
                let bpmUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
                let pts: [HRPoint] = samples.map { s in
                    let bpm = Int(s.quantity.doubleValue(for: bpmUnit).rounded())
                    return HRPoint(time: s.startDate, bpm: bpm)
                }

                let maxHR = HealthKitManager.shared.estimateMaxHR()
                guard detailLoadKey == input, !Task.isCancelled else { return }
                hrPoints = pts
                isLoading = false

                let rhr = try await restingTask
                let rhrInt = max(30, min(100, Int((rhr ?? 60).rounded())))
                let z = zoneBreakdownFromSamples(samples, interval: interval, maxHR: maxHR, restingHR: rhrInt)

                guard detailLoadKey == input, !Task.isCancelled else { return }
                zone = z
                store.zonesByWorkout[entry.id] = z
                restingHR = rhrInt

                // Route can lag; apply it after charts/zones so the detail feels responsive.
                let coords = await routeTask
                guard detailLoadKey == input, !Task.isCancelled else { return }
                if !coords.isEmpty { routeCoords = coords }
                if shouldFetchRoute { isRouteLoading = false }
            } else {
                // Non-owner view: use stored stats from the workout record (no HealthKit access)
                zone = entry.zones ?? ZoneBreakdown()
                restingHR = entry.restingHR ?? 60
                isLoading = false
                isRouteLoading = false
            }
        } catch {
            guard detailLoadKey == input, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            isLoading = false
            isRouteLoading = false
        }
    }

    @MainActor
    private func loadLikes() async {
        guard let entry = liveWorkout else { return }
        let viewerID = store.me.id
        isLikesLoading = true
        likesError = nil
        do {
            let list = try await CloudKitManager.shared.fetchLikes(workoutId: entry.id)
            guard liveWorkout != nil, store.me.id == viewerID, !Task.isCancelled else { return }
            let sorted = list.sorted { $0.createdAt < $1.createdAt }
            likes = sorted
            store.likeCountByWorkout[entry.id] = sorted.count
            store.didILikeByWorkout[entry.id] = sorted.contains(where: { $0.fromUserId == viewerID })
            isLikesLoading = false
        } catch {
            guard liveWorkout != nil, store.me.id == viewerID, !Task.isCancelled else { return }
            likesError = error.localizedDescription
            isLikesLoading = false
        }
    }

    // Helpers

    private func paceString(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d /mi", m, s)
    }

    private func formatHMS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        } else {
            return String(format: "%d min", m)
        }
    }

    private func relativeString(to date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func displayName(for userId: String) -> String {
        store.allUsers.first(where: { $0.id == userId })?.displayName ?? userId
    }

    private func initials(for userId: String) -> String {
        store.allUsers.first(where: { $0.id == userId })?.initials ?? String(userId.prefix(2)).uppercased()
    }

    private func colorForUser(id: String) -> Color {
        let hex = store.allUsers.first(where: { $0.id == id })?.colorHex ?? "#999999"
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 6, let v = UInt32(s, radix: 16) {
            let r = Double((v >> 16) & 0xFF) / 255.0
            let g = Double((v >> 8) & 0xFF) / 255.0
            let b = Double(v & 0xFF) / 255.0
            return Color(red: r, green: g, blue: b)
        }
        return AthensTheme.goldAccent
    }

    #if canImport(MapKit)
    private func decodedSharedRoute(_ points: [Double]?) -> [CLLocationCoordinate2D] {
        guard let points, points.count >= 4 else { return [] }
        let usableCount = points.count - (points.count % 2)
        guard usableCount >= 4 else { return [] }

        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(usableCount / 2)
        var idx = 0
        while idx + 1 < usableCount {
            let lat = points[idx]
            let lon = points[idx + 1]
            if lat.isFinite, lon.isFinite, abs(lat) <= 90, abs(lon) <= 180 {
                coords.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            idx += 2
        }
        return coords
    }

    private func regionForCoordinates(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                      span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2.0,
                                            longitude: (minLon + maxLon) / 2.0)
        var latDelta = max(0.002, (maxLat - minLat) * 1.2)
        var lonDelta = max(0.002, (maxLon - minLon) * 1.2)
        if !latDelta.isFinite || latDelta <= 0 { latDelta = 0.02 }
        if !lonDelta.isFinite || lonDelta <= 0 { lonDelta = 0.02 }
        return MKCoordinateRegion(center: center,
                                  span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
    #endif

    // MARK: - HR zone coloring helpers

    private func zoneColor(_ idx: Int) -> Color {
        switch idx {
        case 0: return Color.blue.opacity(0.70)
        case 1: return Color.green.opacity(0.75)
        case 2: return AthensTheme.goldAccent.opacity(0.85)
        case 3: return AthensTheme.terracotta.opacity(0.90)
        default: return Color.red.opacity(0.90)
        }
    }

    private func zoneIndexForBPM(_ bpm: Int, maxHR: Int, restingHR: Int) -> Int {
        guard maxHR > 0, bpm > 0 else { return 0 }
        let reserve = max(1.0, Double(maxHR - restingHR))
        let pct = (Double(bpm) - Double(restingHR)) / reserve
        if pct < 0.60 { return 0 } // Z1 (includes <50% HRR)
        if pct < 0.70 { return 1 }
        if pct < 0.80 { return 2 }
        if pct < 0.90 { return 3 }
        return 4
    }

    private func zoneBreakdownFromSamples(_ samples: [HKQuantitySample],
                                          interval: DateInterval,
                                          maxHR: Int,
                                          restingHR: Int) -> ZoneBreakdown {
        guard !samples.isEmpty else { return ZoneBreakdown() }

        let bpmUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        var durations = Array(repeating: 0.0, count: 5)
        var total: TimeInterval = 0
        let clampedEnd = interval.end

        for i in 0..<samples.count {
            let sample = samples[i]
            let nextStart = (i + 1 < samples.count) ? samples[i + 1].startDate : clampedEnd
            let segStart: Date = (i == 0) ? interval.start : max(sample.startDate, interval.start)
            let segEnd: Date = min(nextStart, clampedEnd)
            let dt = segEnd.timeIntervalSince(segStart)
            guard dt > 0 else { continue }

            let bpm = Int(sample.quantity.doubleValue(for: bpmUnit).rounded())
            let idx = zoneIndexForBPM(bpm, maxHR: maxHR, restingHR: restingHR)
            durations[idx] += dt
            total += dt
        }

        return ZoneBreakdown(durations: durations, total: total)
    }

    private func makeSegments(points: [HRPoint], maxHR: Int, restingHR: Int) -> [HRSegment] {
        guard !points.isEmpty else { return [] }
        var segments: [HRSegment] = []
        var segId = 0
        var currentZone = zoneIndexForBPM(points[0].bpm, maxHR: maxHR, restingHR: restingHR)
        var bucket: [HRPoint] = [points[0]]

        for pt in points.dropFirst() {
            let z = zoneIndexForBPM(pt.bpm, maxHR: maxHR, restingHR: restingHR)
            if z == currentZone {
                bucket.append(pt)
            } else {
                segments.append(HRSegment(id: segId, zoneIndex: currentZone, points: bucket))
                segId += 1
                currentZone = z
                bucket = [pt]
            }
        }
        segments.append(HRSegment(id: segId, zoneIndex: currentZone, points: bucket))
        return segments
    }
}

// Local types/views

private struct HRPoint: Identifiable {
    let id = UUID()
    let time: Date
    let bpm: Int
}

private struct HRSegment: Identifiable {
    let id: Int           // unique per contiguous segment
    let zoneIndex: Int    // 0...4
    let points: [HRPoint]
}

private struct ZoneBar: View {
    let percentages: [Double] // 0...1 for Z1...Z5
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = percentages.prefix(5).map { max(0.0, min(1.0, $0)) }
            let sum = clamped.reduce(0, +)
            let normalized = sum > 0 ? clamped.map { $0 / sum } : Array(repeating: 0.0, count: clamped.count)
            let segmentWidths = normalized.map { CGFloat($0) * width }

            let offsets: [CGFloat] = segmentWidths.indices.map { i in
                i == 0 ? 0 : segmentWidths[0..<i].reduce(0, +)
            }

            let colors: [Color] = [
                Color.blue.opacity(0.70),
                Color.green.opacity(0.75),
                AthensTheme.goldAccent.opacity(0.85),
                AthensTheme.terracotta.opacity(0.90),
                Color.red.opacity(0.90)
            ]

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                ForEach(segmentWidths.indices, id: \.self) { i in
                    Capsule()
                        .fill(colors[i])
                        .frame(width: segmentWidths[i])
                        .offset(x: offsets[i])
                        .animation(.easeOut(duration: 0.25), value: segmentWidths[i])
                }
            }
        }
        .frame(height: 8)
    }
}
