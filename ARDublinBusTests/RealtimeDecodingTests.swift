import Foundation
import Testing
@testable import ARDublinBus

struct RealtimeDecodingTests {
    static let snakeCaseFeed = """
    {
      "header": {"gtfs_realtime_version": "2.0", "incrementality": "FULL_DATASET", "timestamp": "1763280000"},
      "entity": [
        {"id": "T1", "trip_update": {
          "trip": {"trip_id": "T1", "start_time": "07:50:00", "start_date": "20261116",
                   "schedule_relationship": "SCHEDULED", "route_id": "r27", "direction_id": 0},
          "stop_time_update": [
            {"stop_sequence": 5, "stop_id": "X", "arrival": {"delay": 120}, "departure": {"delay": "150"},
             "schedule_relationship": "SCHEDULED"}
          ],
          "timestamp": "1763280000"
        }},
        {"id": "T4", "trip_update": {"trip": {"trip_id": "T4", "schedule_relationship": "CANCELED"}}},
        {"id": "A1", "trip_update": {
          "trip": {"trip_id": "A1", "route_id": "r11", "schedule_relationship": "ADDED"},
          "stop_time_update": [{"stop_id": "8220DB000271", "arrival": {"time": "1763280900"}}]
        }},
        {"id": "gone", "is_deleted": true, "trip_update": {"trip": {"trip_id": "GONE"}}}
      ]
    }
    """

    static let camelCaseFeed = """
    {
      "header": {"gtfsRealtimeVersion": "2.0", "timestamp": 1763280000},
      "entity": [
        {"id": "1", "tripUpdate": {
          "trip": {"tripId": "T2", "startDate": "20261116", "scheduleRelationship": 0},
          "stopTimeUpdate": [{"stopSequence": "10", "arrival": {"time": 1763281500}, "scheduleRelationship": 1}]
        }}
      ]
    }
    """

    @Test func decodesSnakeCaseWithStringNumbers() throws {
        let feed = try GTFSRFeedMessage.decode(from: Data(Self.snakeCaseFeed.utf8))
        #expect(feed.header?.timestamp?.value == 1_763_280_000)
        #expect(feed.entity?.count == 4)

        let update = try #require(feed.entity?.first?.tripUpdate)
        #expect(update.trip.tripID == "T1")
        #expect(update.trip.scheduleRelationship == .scheduled)
        #expect(update.stopTimeUpdate?.first?.stopSequence?.value == 5)
        #expect(update.stopTimeUpdate?.first?.arrival?.delay?.value == 120)
        #expect(update.stopTimeUpdate?.first?.departure?.delay?.value == 150)
        #expect(feed.entity?[1].tripUpdate?.trip.scheduleRelationship == .canceled)
    }

    @Test func decodesCamelCaseWithNumericEnums() throws {
        let feed = try GTFSRFeedMessage.decode(from: Data(Self.camelCaseFeed.utf8))
        let update = try #require(feed.entity?.first?.tripUpdate)
        #expect(update.trip.tripID == "T2")
        #expect(update.trip.scheduleRelationship == .scheduled)
        #expect(update.stopTimeUpdate?.first?.stopSequence?.value == 10)
        #expect(update.stopTimeUpdate?.first?.scheduleRelationship == .skipped)
        #expect(update.stopTimeUpdate?.first?.arrival?.time?.value == 1_763_281_500)
    }

    @Test func snapshotIndexesTripsAndAddedServices() throws {
        let snapshot = RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(from: Data(Self.snakeCaseFeed.utf8)))
        let monday = GTFSDate(year: 2026, month: 11, day: 16)

        #expect(snapshot.feedTimestamp == Date(timeIntervalSince1970: 1_763_280_000))
        #expect(snapshot.update(forTripID: "T1", serviceDate: monday) != nil)
        // T1's update is for the 16th only.
        #expect(snapshot.update(forTripID: "T1", serviceDate: monday.adding(days: 1)) == nil)
        // No start_date: applies to any day.
        #expect(snapshot.update(forTripID: "T4", serviceDate: monday.adding(days: 3)) != nil)
        #expect(snapshot.update(forTripID: "GONE", serviceDate: monday) == nil)
        #expect(snapshot.addedTrips.map(\.trip.tripID) == ["A1"])
    }

    @Test func rejectsNonNumericIntegers() {
        let json = #"{"entity":[{"trip_update":{"trip":{"trip_id":"x"},"delay":"soon"}}]}"#
        #expect(throws: DecodingError.self) { try GTFSRFeedMessage.decode(from: Data(json.utf8)) }
    }
}
