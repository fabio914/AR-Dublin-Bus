import Foundation
import Testing
@testable import ARDublinBus

/// The line screen: a trip's stops with live times.
struct TripJourneyTests {
    let timetable: StaticTimetable
    let monday = GTFSDate(year: 2026, month: 11, day: 16)

    init() throws {
        timetable = try GTFSFixture().load()
    }

    private func reference(_ tripID: String) -> TripReference {
        TripReference(tripID: tripID, serviceDate: monday, stopID: GTFSFixture.stopID, stopSequence: 10)
    }

    private func snapshot(_ entities: String) throws -> RealtimeSnapshot {
        let json = #"{"header":{"timestamp":"1763280000"},"entity":[\#(entities)]}"#
        return RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(from: Data(json.utf8)))
    }

    @Test func timetableOnlyMarksStopsPassedByTime() throws {
        let details = try #require(try timetable.tripDetails(tripID: "T1"))
        let journey = TripJourney.make(details: details, reference: reference("T1"), realtime: nil,
                                       realtimeIssue: "No key", now: .dublin(2026, 11, 16, 8, 0))

        #expect(journey.route.shortName == "27")
        #expect(journey.headsign == "Clare Hall")
        #expect(journey.stops.map(\.stop.code) == ["115", "271", "2711"])
        #expect(journey.stops.map(\.scheduled) == [.dublin(2026, 11, 16, 7, 50), .dublin(2026, 11, 16, 8, 10), .dublin(2026, 11, 16, 8, 25)])
        #expect(journey.stops.map(\.hasPassed) == [true, false, false])
        #expect(journey.stops.allSatisfy { !$0.isRealtime })
        #expect(journey.origin?.stop.code == "271")
        #expect(journey.shape.count == 3)
        #expect(journey.realtimeIssue == "No key")
    }

    @Test func liveDelaysApplyFromTheUpdatedStopOnwards() throws {
        let realtime = try snapshot("""
        {"id":"1","trip_update":{"trip":{"trip_id":"T1","start_date":"20261116"},
          "stop_time_update":[{"stop_sequence":10,"arrival":{"delay":180}}]}}
        """)
        let details = try #require(try timetable.tripDetails(tripID: "T1"))
        let journey = TripJourney.make(details: details, reference: reference("T1"), realtime: realtime,
                                       realtimeIssue: nil, now: .dublin(2026, 11, 16, 8, 0))

        // The first update is for stop 271, so the bus is past stop 115.
        #expect(journey.stops[0].hasPassed)
        #expect(journey.stops[1].expected == .dublin(2026, 11, 16, 8, 13))
        #expect(journey.stops[1].isRealtime)
        #expect(!journey.stops[1].hasPassed)
        #expect(!journey.isCancelled)
    }

    @Test func cancelledTripCancelsEveryStop() throws {
        let realtime = try snapshot("""
        {"id":"4","trip_update":{"trip":{"trip_id":"T1","start_date":"20261116","schedule_relationship":"CANCELED"}}}
        """)
        let details = try #require(try timetable.tripDetails(tripID: "T1"))
        let journey = TripJourney.make(details: details, reference: reference("T1"), realtime: realtime,
                                       realtimeIssue: nil, now: .dublin(2026, 11, 16, 7, 0))
        #expect(journey.isCancelled)
        #expect(journey.stops.allSatisfy { $0.isCancelled && !$0.isRealtime })
    }

    @Test func fallsBackToStopPositionsWithoutAShape() throws {
        let details = try #require(try timetable.tripDetails(tripID: "T4"))
        let journey = TripJourney.make(details: details, reference: reference("T4"), realtime: nil,
                                       realtimeIssue: nil, now: .dublin(2026, 11, 16, 8, 0))
        #expect(journey.shape.count == 1)
        #expect(journey.shape.first?.latitude == 53.348596)
    }

    @Test func serviceBuildsJourneysFromTheStore() async throws {
        let fixture = try GTFSFixture()
        _ = try fixture.load()
        try ISO8601DateFormatter().string(from: .now)
            .write(to: fixture.directory.appendingPathComponent("downloaded-at.txt"), atomically: true, encoding: .utf8)
        let service = DepartureService(
            timetableStore: TimetableStore(directory: fixture.directory),
            realtimeClient: RealtimeClient(apiKey: { nil })
        )

        let board = try await service.board(forStopCode: "271", now: .dublin(2026, 11, 16, 8, 0))
        let trip = try #require(board.departures.first?.trip)
        let journey = try await service.journey(for: trip, now: .dublin(2026, 11, 16, 8, 0))
        #expect(journey.origin?.stop.code == "271")

        let stops = try await service.stops(in: CoordinateBounds(minLatitude: 53.3, maxLatitude: 53.4, minLongitude: -6.3, maxLongitude: -6.2), limit: 10)
        #expect(Set(stops.stops.map(\.code)) == ["271", "115"])

        await #expect(throws: DepartureServiceError.unknownTrip) {
            try await service.journey(for: reference("missing"))
        }
    }
}
