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
    private var writeTask: Task<Void, Never>?

    private static let openKindKey = "fullyTracked.motion.openKind"
    private static let openStartKey = "fullyTracked.motion.openStart"

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
        guard !ordered.isEmpty else { return }
        var drafts: [ActivityDraft] = []
        for sample in ordered {
            if let draft = noteSegment(kind: sample.kind, startedAt: sample.startedAt) {
                drafts.append(draft)
            }
        }
        guard let container else { return }
        let batch = drafts
        let previous = writeTask
        let kind = openKind
        let startedAt = openStartedAt
        writeTask = Task {
            await previous?.value
            do {
                try await Task.detached(priority: .utility) {
                    try JournalBackgroundWriter.saveActivities(batch, container: container)
                }.value
                // Advance the persisted replay cursor only after the batch saves.
                if let kind, let startedAt {
                    UserDefaults.standard.set(kind, forKey: Self.openKindKey)
                    UserDefaults.standard.set(startedAt, forKey: Self.openStartKey)
                }
            } catch {
                // Keep the previous cursor so a later launch can replay this batch.
            }
        }
    }

    private func noteSegment(kind: String, startedAt: Date) -> ActivityDraft? {
        guard let currentKind = openKind, let currentStart = openStartedAt else {
            rememberOpen(kind: kind, startedAt: startedAt)
            return nil
        }
        if currentKind == kind {
            if startedAt < currentStart {
                rememberOpen(kind: kind, startedAt: startedAt)
            }
            return nil
        }
        let endedAt = max(startedAt, currentStart)
        let minutes = endedAt.timeIntervalSince(currentStart) / 60
        rememberOpen(kind: kind, startedAt: startedAt)
        guard minutes >= 2 else { return nil }
        return ActivityDraft(kind: currentKind, startedAt: currentStart, durationMinutes: minutes)
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
    }
}

private struct MotionSample: Sendable {
    var kind: String
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
