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

    @Test(.enabled(if: RealGTFS.directory != nil))
    func realFeedNearbyStopsQueryQuickly() throws {
        let timetable = try RealGTFS.timetable()
        let nearby = timetable.stops(near: oConnellStLower, within: 600, limit: 12)
        let ids = nearby.reduce(into: Set<String>()) { $0.formUnion($1.stopIDs) }

        var calls: [StopCall] = []
        let elapsed = try ContinuousClock().measure { calls = try timetable.calls(atStopIDs: ids) }
        print("Real feed: \(nearby.count) stops within 600 m of 271, \(calls.count) calls, queried in \(elapsed)")
        print("  ", nearby.map { "\($0.stop.code) \($0.stop.name) \(Int($0.distance))m" })

        #expect(nearby.first?.stop.code == "271")
        #expect(nearby.count > 3)
        #expect(Set(calls.map(\.stopID)).isSubset(of: ids))
    }
}
