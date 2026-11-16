import Foundation
import Testing
@testable import ARDublinBus

/// Collects the phases a `TimetableStore` reports.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimetablePhase] = []

    var phases: [TimetablePhase] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ phase: TimetablePhase) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(phase)
    }

    /// Waits until `condition` holds for the recorded phases, or `timeout` passes.
    func wait(timeout: Duration = .seconds(5), until condition: ([TimetablePhase]) -> Bool) async -> [TimetablePhase] {
        let deadline = ContinuousClock.now + timeout
        while !condition(phases), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return phases
    }
}

extension TimetablePhase {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

extension GTFSFixture {
    /// Builds the database and marks it as downloaded `age` ago, as `TimetableStore` would have.
    func install(downloaded age: TimeInterval) throws {
        _ = try load()
        try ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-age))
            .write(to: directory.appendingPathComponent(TimetableStore.metadataFileName), atomically: true, encoding: .utf8)
    }

    /// A feed URL that can't be downloaded.
    var missingFeedURL: URL { directory.appendingPathComponent("no-such-feed.zip") }
}

struct TimetableStoreTests {
    @Test func failedBackgroundRefreshGoesBackToReady() async throws {
        let fixture = try GTFSFixture()
        try fixture.install(downloaded: 10 * 24 * 3600)
        let store = TimetableStore(feedURL: fixture.missingFeedURL, directory: fixture.directory)
        let recorder = PhaseRecorder()
        await store.setPhaseHandler { recorder.record($0) }

        // The stale copy is used straight away…
        let timetable = try await store.loadedTimetable()
        #expect(timetable.stopsByCode["271"] != nil)

        // …and the refresh that then fails must not leave the phase at "downloading".
        let phases = await recorder.wait { phases in
            guard let downloading = phases.firstIndex(where: { $0.isDownloading }) else { return false }
            return phases[downloading...].contains(where: { $0.isReady })
        }
        #expect(phases.contains(where: { $0.isDownloading }))
        #expect(phases.last?.isReady == true)
    }

    @Test func freshTimetableIsNotRefreshed() async throws {
        let fixture = try GTFSFixture()
        try fixture.install(downloaded: 3600)
        let store = TimetableStore(feedURL: fixture.missingFeedURL, directory: fixture.directory)
        let recorder = PhaseRecorder()
        await store.setPhaseHandler { recorder.record($0) }

        _ = try await store.loadedTimetable()
        try await Task.sleep(for: .milliseconds(200))
        #expect(!recorder.phases.contains(where: { $0.isDownloading }))
        #expect(recorder.phases.last?.isReady == true)
    }
}
