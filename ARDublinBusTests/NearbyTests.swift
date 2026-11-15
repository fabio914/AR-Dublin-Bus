import CoreLocation
import Foundation
import Testing
@testable import ARDublinBus

struct NearbyTests {
    /// O'Connell St Lwr (stop 271) in the fixture.
    let oConnellStLower = CLLocationCoordinate2D(latitude: 53.348596, longitude: -6.259485)

    @Test func findsNearbyStopsNearestFirst() throws {
        let timetable = try GTFSFixture().load()
        // 100 m north of stop 271.
        let here = CLLocationCoordinate2D(latitude: oConnellStLower.latitude + 0.0009, longitude: oConnellStLower.longitude)
        let nearby = timetable.stops(near: here, within: 600, limit: 10)

        #expect(nearby.map(\.stop.code) == ["271"])
        let distance = try #require(nearby.first?.distance)
        #expect(abs(distance - 100) < 5)
        #expect(nearby.first?.stopIDs == [GTFSFixture.stopID])
    }

    @Test func fallsBackToClosestStopsWhenNoneAreNear() throws {
        let timetable = try GTFSFixture().load()
        let galway = CLLocationCoordinate2D(latitude: 53.2707, longitude: -9.0568)
        let nearby = timetable.stops(near: galway, within: 600, limit: 10, fallbackCount: 2)
        #expect(nearby.count == 2)
        #expect(nearby.allSatisfy { $0.distance > 100_000 })
        #expect(nearby[0].distance <= nearby[1].distance)
    }

    @Test func respectsLimit() throws {
        let timetable = try GTFSFixture().load()
        let nearby = timetable.stops(near: oConnellStLower, within: 1_000_000, limit: 2)
        #expect(nearby.count == 2)
        #expect(nearby.first?.stop.code == "271")
    }

    @Test func singlePassScanMatchesPerStopScan() throws {
        let fixture = try GTFSFixture()
        let url = fixture.directory.appendingPathComponent("stop_times.txt")
        let ids: Set<String> = [GTFSFixture.stopID, "8220DB000115", "8220DB0002711", "missing"]

        let perStop = try StaticTimetable.scanStopTimes(at: url, stopIDs: ids, strategy: .perStop)
        let singlePass = try StaticTimetable.scanStopTimes(at: url, stopIDs: ids, strategy: .singlePass)

        #expect(Set(perStop) == Set(singlePass))
        #expect(perStop.count == singlePass.count)
        // The "X8220DB000271" row must not match.
        #expect(!singlePass.contains { $0.stopSequence == 11 })
        #expect(Set(singlePass.map(\.stopID)) == [GTFSFixture.stopID, "8220DB000115", "8220DB0002711"])
    }

    @Test func singlePassHandlesQuotedAndPaddedFields() throws {
        let fixture = try GTFSFixture(stopTimes: """
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        "T1,quoted",08:00:00,08:00:00,8220DB000271,1
        T2,08:05:00,08:05:00, 8220DB000271 ,2
        T3,08:10:00,08:10:00,8220DB000115,3
        """)
        let url = fixture.directory.appendingPathComponent("stop_times.txt")
        let calls = try StaticTimetable.scanStopTimes(at: url, stopIDs: [GTFSFixture.stopID, "a", "b"], strategy: .singlePass)
        #expect(Set(calls.map(\.tripID)) == ["T1,quoted", "T2"])
    }

    @Test func perStopScanDoesNotDuplicateLines() throws {
        // The trip ID contains another wanted stop's ID.
        let fixture = try GTFSFixture(stopTimes: """
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        trip-8220DB000115,08:00:00,08:00:00,8220DB000271,1
        """)
        let url = fixture.directory.appendingPathComponent("stop_times.txt")
        let calls = try StaticTimetable.scanStopTimes(at: url, stopIDs: [GTFSFixture.stopID, "8220DB000115"], strategy: .perStop)
        #expect(calls.count == 1)
    }

    @Test func mergeKeepsClosestStopAndSortsByTime() {
        let now = Date.dublin(2026, 11, 16, 8, 0)
        func departure(_ id: String, _ minutes: Double) -> Departure {
            let date = now.addingTimeInterval(minutes * 60)
            return Departure(id: id, route: "27", destination: "", scheduled: date, expected: date, isRealtime: true, isCancelled: false)
        }
        func stop(_ code: String, _ distance: Double) -> NearbyStop {
            NearbyStop(stop: GTFSStop(id: "id\(code)", code: code, name: code, latitude: nil, longitude: nil),
                       stopIDs: ["id\(code)"], distance: distance)
        }
        func board(_ code: String, _ departures: [Departure]) -> StopBoard {
            StopBoard(stopCode: code, stopName: code, departures: departures, realtimeIssue: nil, realtimeTimestamp: nil, generatedAt: now)
        }

        let near = stop("1", 80), far = stop("2", 300)
        let merged = NearbyDepartures.merge([
            (stop: far, board: board("2", [departure("A", 3), departure("B", 9)])),
            (stop: near, board: board("1", [departure("A", 5), departure("C", 1)])),
        ])

        #expect(merged.map(\.id) == ["C", "A", "B"])
        // Trip A calls at both stops: listed once, at the closer one.
        #expect(merged.first { $0.id == "A" }?.stop.stop.code == "1")
        #expect(NearbyDepartures.merge([(stop: near, board: board("1", (0..<40).map { departure("\($0)", Double($0)) }))]).count == 25)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GTFS_DIR"] != nil))
    func realFeedNearbyStopsScanQuickly() throws {
        let timetable = try StaticTimetable.load(from: URL(fileURLWithPath: ProcessInfo.processInfo.environment["GTFS_DIR"]!))
        let nearby = timetable.stops(near: oConnellStLower, within: 600, limit: 12)
        let ids = nearby.reduce(into: Set<String>()) { $0.formUnion($1.stopIDs) }

        var calls: [StopCall] = []
        let elapsed = try ContinuousClock().measure { calls = try timetable.calls(atStopIDs: ids) }
        print("Real feed: \(nearby.count) stops within 600 m of 271, \(calls.count) calls, single-pass scan \(elapsed)")
        print("  ", nearby.map { "\($0.stop.code) \($0.stop.name) \(Int($0.distance))m" })

        #expect(nearby.first?.stop.code == "271")
        #expect(nearby.count > 3)
        #expect(Set(calls.map(\.stopID)).isSubset(of: ids))
    }
}
