import Foundation
import Testing
@testable import ARDublinBus

/// End-to-end check with real NTA data. Needs `TEST_RUNNER_GTFS_DIR` (extracted Dublin Bus
/// GTFS) and `TEST_RUNNER_REALTIME_JSON` (a saved `TripUpdates?format=json` response).
struct RealFeedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GTFS_DIR"] != nil
                   && ProcessInfo.processInfo.environment["REALTIME_JSON"] != nil))
    func liveDeparturesForStop271() throws {
        let environment = ProcessInfo.processInfo.environment
        let timetable = try StaticTimetable.load(from: URL(fileURLWithPath: environment["GTFS_DIR"]!))
        let data = try Data(contentsOf: URL(fileURLWithPath: environment["REALTIME_JSON"]!))
        let snapshot = RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(from: data))
        let now = try #require(snapshot.feedTimestamp)

        let stops = try #require(timetable.stopsByCode["271"])
        let ids = Set(stops.map(\.id))
        let departures = DepartureCalculator().departures(
            calls: try timetable.calls(atStopIDs: ids), stopIDs: ids, timetable: timetable, realtime: snapshot, now: now
        )

        print("Feed: \(snapshot.tripCount) trips at \(ETAText.clock(now))")
        for departure in departures {
            let kind = departure.isCancelled ? "CANCELLED" : departure.isRealtime ? "live \(Int(departure.delay))s" : "scheduled"
            print("  \(departure.route) → \(departure.destination): \(ETAText.relative(departure, now: now)) [\(kind)]")
        }
        #expect(snapshot.tripCount > 0)
        #expect(!departures.isEmpty)
    }
}
