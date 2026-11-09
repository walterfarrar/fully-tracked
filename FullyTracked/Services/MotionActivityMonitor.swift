import CoreLocation
import CoreMotion
import Foundation
import SwiftData

@MainActor
final class MotionActivityMonitor {
    static let shared = MotionActivityMonitor()

    private let motion = CMMotionActivityManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "FullyTracked.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var container: ModelContainer?
    private var updatesStarted = false
    private var didLoadOpen = false
    private var openKind: String?
    private var openStartedAt: Date?
    private var lastQueryAt: Date?
    private var tripActive = false
    private var tripTask: Task<Void, Never>?
    private var backgroundSession: CLBackgroundActivitySession?
    private var lastTripLocation: CLLocation?

    private static let openKindKey = "fullyTracked.motion.openKind"
    private static let openStartKey = "fullyTracked.motion.openStart"
    private static let tripSpacingMeters: CLLocationDistance = 150

    private init() {}

    func attach(_ container: ModelContainer) {
        self.container = container
    }

    func start() {
        loadOpenSegment()
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        if !updatesStarted {
            updatesStarted = true
            motion.startActivityUpdates(to: queue) { [weak self] activity in
                guard let activity else { return }
                let sample = MotionSample(
                    kind: MotionNaming.kind(activity),
                    confident: activity.confidence == .medium || activity.confidence == .high,
                    startedAt: activity.startDate
                )
                Task { @MainActor in
                    self?.ingest([sample])
                }
            }
        }
        noteAwake()
    }

    func stop() {
        if updatesStarted {
            motion.stopActivityUpdates()
            updatesStarted = false
        }
        stopTrip()
    }

    /// Catches up on motion history after a foreground open or a background location wake.
    func noteAwake() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        let now = Date()
        if let lastQueryAt, now.timeIntervalSince(lastQueryAt) < 30 {
            return
        }
        lastQueryAt = now
        loadOpenSegment()
        let earliest = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var from = openStartedAt ?? now.addingTimeInterval(-6 * 60 * 60)
        if from < earliest { from = earliest }
        if from > now { from = now.addingTimeInterval(-60) }
        motion.queryActivityStarting(from: from, to: now, to: queue) { [weak self] activities, error in
            guard error == nil, let activities else { return }
            let samples = activities.map { activity in
                MotionSample(
                    kind: MotionNaming.kind(activity),
                    confident: activity.confidence == .medium || activity.confidence == .high,
                    startedAt: activity.startDate
                )
            }
            Task { @MainActor in
                self?.ingest(samples)
            }
        }
    }

    private func ingest(_ samples: [MotionSample]) {
        let ordered = samples.sorted { $0.startedAt < $1.startedAt }
        guard let last = ordered.last else { return }
        for sample in ordered.dropLast() {
            noteSegment(kind: sample.kind, startedAt: sample.startedAt)
        }
        noteSegment(kind: last.kind, startedAt: last.startedAt)
        let travel = last.kind == "automotive" || last.kind == "cycling" || last.kind == "running"
        if travel {
            if last.confident {
                startTrip()
            }
        } else if last.kind == "stationary" || last.kind == "walking" {
            stopTrip()
        }
    }

    private func noteSegment(kind: String, startedAt: Date) {
        guard let currentKind = openKind, let currentStart = openStartedAt else {
            rememberOpen(kind: kind, startedAt: startedAt)
            return
        }
        if currentKind == kind {
            if startedAt < currentStart {
                rememberOpen(kind: kind, startedAt: startedAt)
            }
            return
        }
        let endedAt = max(startedAt, currentStart)
        let minutes = endedAt.timeIntervalSince(currentStart) / 60
        if minutes >= 2 {
            saveActivity(kind: currentKind, startedAt: currentStart, durationMinutes: minutes)
        }
        rememberOpen(kind: kind, startedAt: startedAt)
    }

    private func startTrip() {
        guard !tripActive else { return }
        guard LocationTracker.shared.canTrackInBackground else { return }
        tripActive = true
        if lastTripLocation == nil {
            lastTripLocation = LocationTracker.shared.mostRecentLocation()
        }
        if backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
        tripTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            let updates = CLLocationUpdate.liveUpdates(.otherNavigation)
            do {
                for try await update in updates {
                    if Task.isCancelled { return }
                    if update.authorizationDenied {
                        break
                    }
                    let fix = update.location.map(LocationFix.init(location:))
                    if self.handleTrip(fix, isStationary: update.isStationary) {
                        break
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // A location failure ends this stream. A later wake can start another. Nothing is invented.
            }
            if !Task.isCancelled {
                self.stopTrip()
            }
        }
    }

    /// Returns true when the live stream should stop.
    private func handleTrip(_ fix: LocationFix?, isStationary: Bool) -> Bool {
        if isStationary {
            return true
        }
        guard let fix, fix.isRecordable() else { return false }
        if let lastTripLocation {
            let here = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
            if here.distance(from: lastTripLocation) < Self.tripSpacingMeters {
                return false
            }
        }
        guard LocationTracker.shared.recordTripFix(fix) else { return false }
        lastTripLocation = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        return false
    }

    private func stopTrip() {
        let task = tripTask
        tripActive = false
        tripTask = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        task?.cancel()
    }

    private func saveActivity(kind: String, startedAt: Date, durationMinutes: Double) {
        guard durationMinutes >= 2, let context = container?.mainContext else { return }
        if alreadySaved(kind: kind, startedAt: startedAt) { return }
        let entry = JournalEntry(type: .activity, occurredAt: startedAt)
        entry.kind = kind
        entry.durationMinutes = durationMinutes
        entry.source = "motion"
        context.insert(entry)
        do {
            try context.save()
        } catch {
            context.delete(entry)
        }
    }

    private func alreadySaved(kind: String, startedAt: Date) -> Bool {
        guard let context = container?.mainContext else { return false }
        let rows = (try? context.fetch(FetchDescriptor<JournalEntry>())) ?? []
        return rows.contains { entry in
            guard entry.entryType == .activity, entry.kind == kind else { return false }
            return abs(entry.occurredAt.timeIntervalSince(startedAt)) < 2
        }
    }

    private func loadOpenSegment() {
        guard !didLoadOpen else { return }
        didLoadOpen = true
        let kind = UserDefaults.standard.string(forKey: Self.openKindKey)
        let started = UserDefaults.standard.object(forKey: Self.openStartKey) as? Date
        if let kind, let started, !kind.isEmpty {
            openKind = kind
            openStartedAt = started
        }
    }

    private func rememberOpen(kind: String, startedAt: Date) {
        openKind = kind
        openStartedAt = startedAt
        UserDefaults.standard.set(kind, forKey: Self.openKindKey)
        UserDefaults.standard.set(startedAt, forKey: Self.openStartKey)
    }
}

private struct MotionSample: Sendable {
    var kind: String
    var confident: Bool
    var startedAt: Date
}

private enum MotionNaming {
    static func kind(_ activity: CMMotionActivity) -> String {
        if activity.automotive { return "automotive" }
        if activity.cycling { return "cycling" }
        if activity.running { return "running" }
        if activity.walking { return "walking" }
        if activity.stationary { return "stationary" }
        return "unknown"
    }
}
