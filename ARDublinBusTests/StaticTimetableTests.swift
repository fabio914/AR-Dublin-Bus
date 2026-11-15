import Foundation
import Testing
@testable import ARDublinBus

struct StaticTimetableTests {
    @Test func loadsStopsRoutesAndTrips() throws {
        let timetable = try GTFSFixture().load()
        #expect(timetable.stopsByCode["271"]?.first?.id == GTFSFixture.stopID)
        #expect(timetable.stopsByCode["271"]?.first?.name == "O'Connell St Lwr")
        #expect(timetable.stopsByCode["115"]?.first?.name == "Ballymun Rd, Ch")
        #expect(timetable.routes["r44"]?.shortName == "44")
        #expect(timetable.trips["T4"]?.headsign == "Enniskerry")
        #expect(timetable.version == "test-1")
    }

    @Test func scanFindsOnlyExactStopMatches() throws {
        let timetable = try GTFSFixture().load()
        let calls = try timetable.calls(atStopIDs: [GTFSFixture.stopID])
        let trips = Set(calls.map(\.tripID))

        #expect(trips == ["T1", "T2", "T3", "T4", "T5", "T7", "T8", "T9", "N1"])
        #expect(calls.allSatisfy { $0.stopID == GTFSFixture.stopID })

        let t1 = try #require(calls.first { $0.tripID == "T1" })
        #expect(t1.arrival == 8 * 3600 + 10 * 60)
        #expect(t1.stopSequence == 10)

        let night = try #require(calls.first { $0.tripID == "N1" })
        #expect(night.arrival == 24 * 3600 + 35 * 60)
    }

    @Test func scanHandlesMultipleStopsAndMissingStops() throws {
        let timetable = try GTFSFixture().load()
        let calls = try timetable.calls(atStopIDs: ["8220DB000115", "8220DB0002711", "nope"])
        #expect(Set(calls.map(\.tripID)) == ["T1", "T10"])
    }

    @Test func missingRequiredFileThrows() throws {
        let fixture = try GTFSFixture()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("trips.txt"))
        #expect(throws: TimetableError.self) { try fixture.load() }
    }

    /// Runs against the real Dublin Bus feed when `TEST_RUNNER_GTFS_DIR` points at an
    /// extracted copy (xcodebuild strips the `TEST_RUNNER_` prefix).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GTFS_DIR"] != nil))
    func realFeedFindsStop271() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GTFS_DIR"]!)
        let clock = ContinuousClock()

        var timetable: StaticTimetable?
        let loadTime = try clock.measure { timetable = try StaticTimetable.load(from: directory) }
        let loaded = try #require(timetable)
        let stops = try #require(loaded.stopsByCode["271"])

        var calls: [StopCall] = []
        let scanTime = try clock.measure { calls = try loaded.calls(atStopIDs: Set(stops.map(\.id))) }

        let routes = Set(calls.compactMap { loaded.trips[$0.tripID] }.compactMap { loaded.routes[$0.routeID]?.shortName })
        print("Real feed: load \(loadTime), scan \(scanTime), \(calls.count) calls, routes \(routes.sorted())")

        #expect(!calls.isEmpty)
        #expect(routes.isSuperset(of: ["11", "44"]))
    }
}
