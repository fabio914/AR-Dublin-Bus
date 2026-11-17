import Foundation
import Testing
@testable import ARDublinBus

/// End-to-end check with real NTA data. Needs `TEST_RUNNER_GTFS_DIR` (extracted Dublin Bus
/// GTFS) and `TEST_RUNNER_REALTIME_JSON` (a saved `TripUpdates?format=json` response).
struct RealFeedTests {
    @Test(.enabled(if: RealGTFS.directory != nil
                   && ProcessInfo.processInfo.environment["REALTIME_JSON"] != nil))
    func liveDeparturesForStop271() throws {
        let environment = ProcessInfo.processInfo.environment
        let timetable = try RealGTFS.timetable()
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

    /// Needs `TEST_RUNNER_REALTIME_JSON` and `TEST_RUNNER_REALTIME_PROTOBUF`: the same feed saved
    /// in both formats (`TripUpdates?format=json` and `?format=protobuf`), fetched within a few
    /// seconds of each other so both hold the same data.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REALTIME_JSON"] != nil
                   && ProcessInfo.processInfo.environment["REALTIME_PROTOBUF"] != nil))
    func protobufMatchesJSON() throws {
        let environment = ProcessInfo.processInfo.environment
        let json = try GTFSRFeedMessage.decode(from: Data(contentsOf: URL(fileURLWithPath: environment["REALTIME_JSON"]!)))
        let protobufData = try Data(contentsOf: URL(fileURLWithPath: environment["REALTIME_PROTOBUF"]!))
        let clock = ContinuousClock()
        var protobuf: GTFSRFeedMessage?
        let decodeTime = try clock.measure { protobuf = try GTFSRFeedMessage.decode(protobuf: protobufData) }
        let decoded = try #require(protobuf)
        print("Protobuf: \(protobufData.count) bytes, \(decoded.entity?.count ?? 0) entities, decoded in \(decodeTime)")

        try #require(json.header?.timestamp == decoded.header?.timestamp, "The files are from different fetches")
        #expect(Self.summaries(json) == Self.summaries(decoded))
        #expect(RealtimeSnapshot(feed: json).tripCount == RealtimeSnapshot(feed: decoded).tripCount)
    }

    /// Needs `TEST_RUNNER_VEHICLES_JSON` and `TEST_RUNNER_VEHICLES_PROTOBUF`: the same
    /// `Vehicles` feed saved in both formats, fetched within a few seconds of each other.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VEHICLES_JSON"] != nil
                   && ProcessInfo.processInfo.environment["VEHICLES_PROTOBUF"] != nil))
    func vehiclePositionsMatchJSON() throws {
        let environment = ProcessInfo.processInfo.environment
        let json = try GTFSRFeedMessage.decode(from: Data(contentsOf: URL(fileURLWithPath: environment["VEHICLES_JSON"]!)))
        let protobuf = try GTFSRFeedMessage.decode(protobuf: Data(contentsOf: URL(fileURLWithPath: environment["VEHICLES_PROTOBUF"]!)))
        try #require(json.header?.timestamp == protobuf.header?.timestamp, "The files are from different fetches")

        func summaries(_ feed: GTFSRFeedMessage) -> [String: String] {
            var result: [String: String] = [:]
            for entity in feed.entity ?? [] {
                guard let vehicle = entity.vehicle else { continue }
                let bearing = vehicle.position?.bearing.map { String(format: "%.0f", $0) } ?? "-"
                result[entity.id ?? "?"] = "\(vehicle.trip?.tripID ?? "") \(vehicle.trip?.startDate ?? "") \(bearing)"
                    + " \(vehicle.timestamp?.value ?? 0) \(vehicle.vehicle?.id ?? "")"
            }
            return result
        }
        func positions(_ feed: GTFSRFeedMessage) -> [String: GTFSRVehiclePosition.Position] {
            Dictionary(uniqueKeysWithValues: (feed.entity ?? []).compactMap { entity in
                entity.vehicle?.position.map { (entity.id ?? "?", $0) }
            })
        }
        let fromProtobuf = summaries(protobuf)
        print("Vehicles: \(fromProtobuf.count) positions")
        #expect(!fromProtobuf.isEmpty)
        #expect(summaries(json) == fromProtobuf)

        // Positions are floats in protobuf and decimals in JSON: equal to about a metre.
        let jsonPositions = positions(json)
        let protobufPositions = positions(protobuf)
        #expect(Set(jsonPositions.keys) == Set(protobufPositions.keys))
        let mismatched = jsonPositions.filter { id, position in
            guard let other = protobufPositions[id] else { return false }
            return abs(position.latitude - other.latitude) > 1e-5 || abs(position.longitude - other.longitude) > 1e-5
        }
        #expect(mismatched.isEmpty)
        #expect(VehicleSnapshot(feed: json).vehicleCount == VehicleSnapshot(feed: protobuf).vehicleCount)
    }

    /// Everything the app reads from each entity, as text, by entity ID.
    private static func summaries(_ feed: GTFSRFeedMessage) -> [String: String] {
        func event(_ event: GTFSRTripUpdate.StopTimeEvent?) -> String {
            event.map { "\($0.delay?.value ?? 0)@\($0.time?.value ?? 0)" } ?? "-"
        }
        var result: [String: String] = [:]
        for entity in feed.entity ?? [] {
            var text = "deleted=\(entity.isDeleted ?? false)"
            if let update = entity.tripUpdate {
                let trip = update.trip
                text += " trip=\(trip.tripID ?? "") route=\(trip.routeID ?? "") start=\(trip.startDate ?? "") \(trip.startTime ?? "")"
                text += " relationship=\(String(describing: trip.scheduleRelationship)) delay=\(update.delay?.value ?? 0)"
                for stop in update.stopTimeUpdate ?? [] {
                    text += " [\(stop.stopSequence?.value ?? -1) \(stop.stopID ?? "") \(event(stop.arrival)) \(event(stop.departure))"
                    text += " \(String(describing: stop.scheduleRelationship))]"
                }
            }
            result[entity.id ?? "?"] = text
        }
        return result
    }
}
