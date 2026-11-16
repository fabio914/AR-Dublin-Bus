import Foundation
import Testing
@testable import ARDublinBus

struct DepartureCalculatorTests {
    let timetable: StaticTimetable
    let calls: [StopCall]
    let stopIDs: Set<String> = [GTFSFixture.stopID]
    let calculator = DepartureCalculator()

    init() throws {
        timetable = try GTFSFixture().load()
        calls = try timetable.calls(atStopIDs: stopIDs)
    }

    private func snapshot(_ entities: String) throws -> RealtimeSnapshot {
        let json = #"{"header":{"timestamp":"1763280000"},"entity":[\#(entities)]}"#
        return RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(from: Data(json.utf8)))
    }

    private func departures(at now: Date, realtime: RealtimeSnapshot? = nil) -> [Departure] {
        calculator.departures(calls: calls, stopIDs: stopIDs, timetable: timetable, realtime: realtime, now: now)
    }

    @Test func tripsEndingAtTheStopAreNotDepartures() throws {
        // E1 ends at stop 271; C1 calls there and carries on.
        let fixture = try GTFSFixture(
            trips: """
            route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
            r27,WK,E1,O'Connell St,0
            r27,WK,C1,Clare Hall,0
            """,
            stopTimes: """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            E1,07:50:00,07:50:00,8220DB000115,1
            E1,08:10:00,08:10:00,8220DB000271,2
            C1,08:15:00,08:15:00,8220DB000271,1
            C1,08:40:00,08:40:00,8220DB000115,2
            """
        )
        let timetable = try fixture.load()
        let calls = try timetable.calls(atStopIDs: stopIDs)
        #expect(Dictionary(uniqueKeysWithValues: calls.map { ($0.tripID, $0.isLastStop) }) == ["E1": true, "C1": false])

        let result = calculator.departures(calls: calls, stopIDs: stopIDs, timetable: timetable, realtime: nil,
                                           now: .dublin(2026, 11, 16, 8, 0))
        #expect(result.map(\.id) == ["C1@20261116"])
    }

    @Test func loopRouteCallingTwiceGetsDistinctIDs() throws {
        let fixture = try GTFSFixture(
            trips: """
            route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
            r27,WK,L1,City loop,0
            """,
            stopTimes: """
            trip_id,arrival_time,departure_time,stop_id,stop_sequence
            L1,08:05:00,08:05:00,8220DB000271,1
            L1,08:20:00,08:20:00,8220DB000115,2
            L1,08:40:00,08:40:00,8220DB000271,3
            L1,08:55:00,08:55:00,8220DB000115,4
            """
        )
        let timetable = try fixture.load()
        let result = calculator.departures(calls: try timetable.calls(atStopIDs: stopIDs), stopIDs: stopIDs,
                                           timetable: timetable, realtime: nil, now: .dublin(2026, 11, 16, 8, 0))
        #expect(result.map(\.id) == ["L1@20261116", "L1@20261116#3"])
        #expect(result.map(\.trip?.stopSequence) == [1, 3])
    }

    @Test func scheduledOnlyWithoutRealtime() {
        // Monday 08:00.
        let result = departures(at: .dublin(2026, 11, 16, 8, 0))
        #expect(result.map(\.id) == ["T3@20261116", "T1@20261116", "T2@20261116", "T4@20261116", "T5@20261116"])
        #expect(result.allSatisfy { !$0.isRealtime && !$0.isCancelled })
        #expect(result.first?.route == "27")
        #expect(result[3].route == "44")
        #expect(result[3].destination == "Enniskerry")
        #expect(result.first?.trip == TripReference(tripID: "T3", serviceDate: GTFSDate(year: 2026, month: 11, day: 16),
                                                    stopID: GTFSFixture.stopID, stopSequence: 10))
        // T8 runs at weekends only; T9 is beyond the 90-minute window.
        #expect(!result.contains { $0.id.hasPrefix("T8") || $0.id.hasPrefix("T9") })
    }

    @Test func mergesRealtimeData() throws {
        let realtime = try snapshot("""
        {"id":"1","trip_update":{"trip":{"trip_id":"T1","start_date":"20261116"},
          "stop_time_update":[{"stop_sequence":5,"departure":{"delay":120}}]}},
        {"id":"2","trip_update":{"trip":{"trip_id":"T2","start_date":"20261116"},
          "stop_time_update":[{"stop_sequence":10,"arrival":{"time":"\(Int(Date.dublin(2026, 11, 16, 8, 25).timeIntervalSince1970))"}}]}},
        {"id":"3","trip_update":{"trip":{"trip_id":"T3","start_date":"20261116"},
          "stop_time_update":[{"stop_sequence":12,"arrival":{"delay":0}}]}},
        {"id":"4","trip_update":{"trip":{"trip_id":"T4","start_date":"20261116","schedule_relationship":"CANCELED"}}},
        {"id":"7","trip_update":{"trip":{"trip_id":"T7","start_date":"20261116"},
          "stop_time_update":[{"stop_sequence":2,"arrival":{"delay":1800}}]}},
        {"id":"A","trip_update":{"trip":{"trip_id":"A1","route_id":"r11","schedule_relationship":"ADDED"},
          "stop_time_update":[{"stop_id":"\(GTFSFixture.stopID)","arrival":{"time":"\(Int(Date.dublin(2026, 11, 16, 8, 15).timeIntervalSince1970))"}}]}}
        """)

        let now = Date.dublin(2026, 11, 16, 8, 0)
        let result = departures(at: now, realtime: realtime)

        // T3 has already passed this stop; T7 is 30 min late and now due.
        #expect(result.map(\.id) == ["T7@20261116", "T1@20261116", "added-A1", "T2@20261116", "T4@20261116", "T5@20261116"])

        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        #expect(byID["T7@20261116"]?.expected == .dublin(2026, 11, 16, 8, 0))
        #expect(byID["T7@20261116"]?.isRealtime == true)
        #expect(byID["T1@20261116"]?.expected == .dublin(2026, 11, 16, 8, 12))
        #expect(byID["T1@20261116"]?.delay == 120)
        #expect(byID["T2@20261116"]?.expected == .dublin(2026, 11, 16, 8, 25))
        #expect(byID["T4@20261116"]?.isCancelled == true)
        #expect(byID["T4@20261116"]?.isRealtime == false)
        #expect(byID["T5@20261116"]?.isRealtime == false)
        #expect(byID["added-A1"]?.route == "11")
        #expect(byID["added-A1"]?.isRealtime == true)
    }

    @Test func realtimeForAnotherServiceDayIsIgnored() throws {
        let realtime = try snapshot("""
        {"id":"1","trip_update":{"trip":{"trip_id":"T1","start_date":"20261117"},
          "stop_time_update":[{"stop_sequence":5,"departure":{"delay":600}}]}}
        """)
        let result = departures(at: .dublin(2026, 11, 16, 8, 0), realtime: realtime)
        let t1 = try #require(result.first { $0.id == "T1@20261116" })
        #expect(t1.expected == .dublin(2026, 11, 16, 8, 10))
        #expect(!t1.isRealtime)
    }

    @Test func includesYesterdaysTripsRunningPastMidnight() {
        // N1 is Monday's 24:35 trip, i.e. Tuesday 00:35.
        let result = departures(at: .dublin(2026, 11, 17, 0, 20))
        #expect(result.map(\.id) == ["N1@20261116"])
        #expect(result.first?.expected == .dublin(2026, 11, 17, 0, 35))
    }

    @Test func noServiceOnCancelledDays() {
        // WK is removed on Christmas Day; WE is added, so T8 runs.
        let result = departures(at: .dublin(2026, 12, 25, 8, 0))
        #expect(result.map(\.id) == ["T8@20261225"])
    }

    @Test func respectsLimit() {
        var limited = calculator
        limited.limit = 2
        let result = limited.departures(calls: calls, stopIDs: stopIDs, timetable: timetable, realtime: nil, now: .dublin(2026, 11, 16, 8, 0))
        #expect(result.count == 2)
    }

    // MARK: Status rules

    private func update(_ json: String) throws -> GTFSRTripUpdate {
        try #require(try snapshot(#"{"id":"x","trip_update":\#(json)}"#)
            .update(forTripID: "T", serviceDate: GTFSDate(year: 2026, month: 1, day: 1)))
    }

    private let call = StopCall(tripID: "T", stopID: GTFSFixture.stopID, arrival: 0, departure: 0, stopSequence: 10)

    @Test func skippedStopCountsAsCancelled() throws {
        let u = try update(#"{"trip":{"trip_id":"T"},"stop_time_update":[{"stop_sequence":10,"schedule_relationship":"SKIPPED"}]}"#)
        #expect(DepartureCalculator.status(of: u, at: call, stopIDs: [GTFSFixture.stopID]) == .cancelled)
    }

    @Test func noDataFallsBackToSchedule() throws {
        let u = try update(#"{"trip":{"trip_id":"T"},"stop_time_update":[{"stop_sequence":3,"schedule_relationship":"NO_DATA"}]}"#)
        #expect(DepartureCalculator.status(of: u, at: call, stopIDs: [GTFSFixture.stopID]) == .scheduledOnly)
    }

    @Test func exactMatchByStopIDWhenSequenceMissing() throws {
        let u = try update(#"{"trip":{"trip_id":"T"},"stop_time_update":[{"stop_id":"8220DB000271","arrival":{"delay":-60}}]}"#)
        #expect(DepartureCalculator.status(of: u, at: call, stopIDs: [GTFSFixture.stopID]) == .delay(-60))
    }

    @Test func usesNearestEarlierStop() throws {
        let u = try update(#"{"trip":{"trip_id":"T"},"stop_time_update":[{"stop_sequence":2,"arrival":{"delay":60}},{"stop_sequence":8,"arrival":{"delay":300}},{"stop_sequence":14,"arrival":{"delay":900}}]}"#)
        #expect(DepartureCalculator.status(of: u, at: call, stopIDs: [GTFSFixture.stopID]) == .delay(300))
    }

    @Test func tripLevelDelayAsFallback() throws {
        let u = try update(#"{"trip":{"trip_id":"T"},"delay":240}"#)
        #expect(DepartureCalculator.status(of: u, at: call, stopIDs: [GTFSFixture.stopID]) == .delay(240))
    }

    @Test func minutesAwayAndETAText() {
        let now = Date.dublin(2026, 11, 16, 8, 0)
        func departure(_ minutes: Double) -> Departure {
            let date = now.addingTimeInterval(minutes * 60)
            return Departure(id: "x", route: "27", destination: "", scheduled: date, expected: date, isRealtime: true, isCancelled: false)
        }
        #expect(ETAText.relative(departure(0.5), now: now) == "Due")
        #expect(ETAText.relative(departure(-1), now: now) == "Due")
        #expect(ETAText.relative(departure(7.9), now: now) == "7 min")
        #expect(departure(75).minutesAway(from: now) == 75)
        #expect(ETAText.relative(departure(75), now: now) == ETAText.clock(now.addingTimeInterval(75 * 60)))
    }
}
