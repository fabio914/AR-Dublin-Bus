import CoreLocation
import Foundation
import Testing
@testable import ARDublinBus

struct StaticTimetableTests {
    @Test func loadsStopsRoutesAndVersion() throws {
        let timetable = try GTFSFixture().load()
        #expect(timetable.stopsByCode["271"]?.first?.id == GTFSFixture.stopID)
        #expect(timetable.stopsByCode["271"]?.first?.name == "O'Connell St Lwr")
        #expect(timetable.stopsByCode["115"]?.first?.name == "Ballymun Rd, Ch")
        #expect(timetable.routes["r44"]?.shortName == "44")
        #expect(timetable.version == "test-1")
    }

    @Test func callsIncludeTripDetails() throws {
        let timetable = try GTFSFixture().load()
        let calls = try timetable.calls(atStopIDs: [GTFSFixture.stopID])

        #expect(Set(calls.map(\.tripID)) == ["T1", "T2", "T3", "T4", "T5", "T7", "T8", "T9", "N1"])
        #expect(calls.allSatisfy { $0.stopID == GTFSFixture.stopID })

        let t1 = try #require(calls.first { $0.tripID == "T1" })
        #expect(t1.arrival == 8 * 3600 + 10 * 60)
        #expect(t1.stopSequence == 10)
        #expect(t1.routeID == "r27")
        #expect(t1.serviceID == "WK")
        #expect(t1.headsign == "Clare Hall")

        let t4 = try #require(calls.first { $0.tripID == "T4" })
        #expect(t4.headsign == "Enniskerry")
        #expect(t4.routeID == "r44")

        let night = try #require(calls.first { $0.tripID == "N1" })
        #expect(night.arrival == 24 * 3600 + 35 * 60)
    }

    @Test func callsForSeveralAndUnknownStops() throws {
        let timetable = try GTFSFixture().load()
        let calls = try timetable.calls(atStopIDs: ["8220DB000115", "8220DB0002711", "nope"])
        #expect(Set(calls.map(\.tripID)) == ["T1", "T10"])
    }

    @Test func tripsWithTheSameStopsAndGapsSharePatterns() throws {
        let fixture = try GTFSFixture()
        let statistics = try TimetableDatabaseBuilder.build(fromGTFS: fixture.directory, to: fixture.databaseURL)
        // The row at the unknown stop "X8220DB000271" is skipped.
        #expect(statistics.calls == 11)
        // T1 (two stops), T10 (the decoy stop), and every trip calling only at stop 271.
        #expect(statistics.patterns == 3)
        // S1 and S2 have the same geometry.
        #expect(statistics.shapes == 1)
        #expect(statistics.trips == 10)
    }

    @Test func dwellTimesArePreserved() throws {
        let timetable = try GTFSFixture(stopTimes: """
        trip_id,arrival_time,departure_time,stop_id,stop_sequence
        T1,08:00:00,08:02:30,8220DB000115,1
        T1,08:20:00,08:21:00,8220DB000271,2
        T2,09:00:00,09:02:30,8220DB000115,1
        T2,09:20:00,09:21:00,8220DB000271,2
        """).load()
        let calls = try timetable.calls(atStopIDs: [GTFSFixture.stopID]).sorted { $0.tripID < $1.tripID }
        #expect(calls.map(\.arrival) == [8 * 3600 + 20 * 60, 9 * 3600 + 20 * 60])
        #expect(calls.map(\.departure) == [8 * 3600 + 21 * 60, 9 * 3600 + 21 * 60])
    }

    @Test func readsQuotedPaddedAndCRLFRows() throws {
        let timetable = try GTFSFixture(
            trips: "route_id,service_id,trip_id,trip_headsign\r\nr27,WK,\"T,1\",Clare Hall\r\nr27,WK,T2,Clare Hall\r\n",
            stopTimes: "trip_id,arrival_time,departure_time,stop_id,stop_sequence\r\n"
                + "\"T,1\",08:00:00,08:00:00,8220DB000271,1\r\n"
                + "T2, 8:05:00, 8:05:00, 8220DB000271 ,2\r\n"
        ).load()
        let calls = try timetable.calls(atStopIDs: [GTFSFixture.stopID])
        #expect(Set(calls.map(\.tripID)) == ["T,1", "T2"])
        #expect(calls.first { $0.tripID == "T2" }?.arrival == 8 * 3600 + 5 * 60)
    }

    @Test func tripDetailsListStopsInOrderWithShape() throws {
        let timetable = try GTFSFixture().load()
        let details = try #require(try timetable.tripDetails(tripID: "T1"))

        #expect(details.route.shortName == "27")
        #expect(details.headsign == "Clare Hall")
        #expect(details.calls.map(\.stop.code) == ["115", "271"])
        #expect(details.calls.map(\.call.arrival) == [7 * 3600 + 50 * 60, 8 * 3600 + 10 * 60])
        #expect(details.calls.map(\.call.stopSequence) == [1, 10])

        #expect(details.shape.count == 3)
        #expect(abs(details.shape[0].latitude - 53.38796) < 1e-5)
        #expect(abs(details.shape[2].longitude - -6.259485) < 1e-5)

        // T2 uses S2, which has the same geometry (its points were listed out of order).
        let t2 = try #require(try timetable.tripDetails(tripID: "T2"))
        #expect(t2.shape.count == 3)
        #expect(abs(t2.shape[0].latitude - 53.38796) < 1e-5)

        #expect(try timetable.tripDetails(tripID: "T4")?.shape.isEmpty == true)
        #expect(try timetable.tripDetails(tripID: "nope") == nil)
    }

    @Test func worksWithoutShapes() throws {
        let timetable = try GTFSFixture(shapes: nil).load()
        #expect(try timetable.tripDetails(tripID: "T1")?.shape.isEmpty == true)
    }

    @Test func findsStopsInsideBounds() throws {
        let timetable = try GTFSFixture().load()
        let aroundOConnellStreet = CoordinateBounds(minLatitude: 53.34, maxLatitude: 53.36, minLongitude: -6.27, maxLongitude: -6.25)
        let result = try timetable.stops(in: aroundOConnellStreet, limit: 100)
        #expect(result.stops.map(\.code) == ["271"])
        #expect(!result.isTruncated)

        let ireland = CoordinateBounds(minLatitude: 51, maxLatitude: 56, minLongitude: -11, maxLongitude: -5)
        let truncated = try timetable.stops(in: ireland, limit: 2)
        #expect(truncated.stops.count == 2)
        #expect(truncated.isTruncated)
    }

    @Test func missingRequiredFileThrows() throws {
        let fixture = try GTFSFixture()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("trips.txt"))
        #expect(throws: TimetableError.self) { try fixture.load() }
    }

    @Test func rejectsDatabaseFromAnotherSchemaVersion() throws {
        let fixture = try GTFSFixture()
        _ = try fixture.load()
        let database = try SQLiteDatabase(url: fixture.databaseURL, readOnly: false)
        try database.execute("UPDATE meta SET value = '0' WHERE key = 'schema_version'")
        #expect(throws: TimetableError.self) { try StaticTimetable.open(databaseAt: fixture.databaseURL) }
    }

    /// Runs against the real Dublin Bus feed when `TEST_RUNNER_GTFS_DIR` points at an
    /// extracted copy (xcodebuild strips the `TEST_RUNNER_` prefix).
    @Test(.enabled(if: RealGTFS.directory != nil))
    func realFeedDatabaseMatchesStopTimes() throws {
        let timetable = try RealGTFS.timetable()
        let stops = try #require(timetable.stopsByCode["271"])
        let stopIDs = Set(stops.map(\.id))

        var calls: [StopCall] = []
        let queryTime = try ContinuousClock().measure { calls = try timetable.calls(atStopIDs: stopIDs) }

        // Every row of stop_times.txt for this stop, found with a plain byte search and
        // parsed with `CSV.parseLine`, independently of the database builder.
        let expected = try RealGTFS.stopTimesRows(forStopIDs: stopIDs)
        func time(_ seconds: Int) -> String { String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        let actual = Set(calls.map { "\($0.tripID) \($0.stopSequence) \(time($0.arrival)) \(time($0.departure))" })

        let routes = Set(calls.compactMap { timetable.routes[$0.routeID]?.shortName })
        print("Real feed: \(calls.count) calls at stop 271 in \(queryTime), routes \(routes.sorted())")
        #expect(actual == expected)
        #expect(routes.isSuperset(of: ["11", "44"]))

        let firstCall = try #require(calls.first)
        let trip = try #require(try timetable.tripDetails(tripID: firstCall.tripID))
        #expect(trip.calls.contains { $0.stop.code == "271" })
        #expect(trip.shape.count > 50)

        let map = try timetable.stops(in: CoordinateBounds(minLatitude: 53.344, maxLatitude: 53.353, minLongitude: -6.267, maxLongitude: -6.252), limit: 500)
        print("Real feed: \(map.stops.count) stops in a ~1 km map area")
        #expect(map.stops.contains { $0.code == "271" })
    }
}

/// Builds the database from a real GTFS feed once per test run.
enum RealGTFS {
    static let directory = ProcessInfo.processInfo.environment["GTFS_DIR"].map { URL(fileURLWithPath: $0) }

    private static let built: Result<StaticTimetable, Error>? = directory.map { directory in
        Result {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("real-timetable-\(UUID().uuidString).sqlite")
            let clock = ContinuousClock()
            var statistics = TimetableDatabaseBuilder.Statistics()
            let buildTime = try clock.measure { statistics = try TimetableDatabaseBuilder.build(fromGTFS: directory, to: url) }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("Real feed: built in \(buildTime), \(size / 1_000_000) MB, \(statistics.stops) stops, \(statistics.trips) trips, "
                  + "\(statistics.calls) calls, \(statistics.patterns) patterns, \(statistics.shapes) shapes")
            print("Real feed: build steps:", statistics.durations.map { "\($0.step) \($0.duration)" })
            return try StaticTimetable.open(databaseAt: url)
        }
    }

    /// "trip sequence arrival departure" for each row of stop_times.txt at the given stops.
    static func stopTimesRows(forStopIDs stopIDs: Set<String>) throws -> Set<String> {
        let data = try Data(contentsOf: directory!.appendingPathComponent("stop_times.txt"), options: .alwaysMapped)
        let header = String(decoding: data.prefix { $0 != UInt8(ascii: "\n") }, as: UTF8.self)
        let columns = CSV.columnIndex(for: CSV.parseLine(header))
        var rows: Set<String> = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let base = buffer.baseAddress!
            for stopID in stopIDs {
                let needle = Array(",\(stopID),".utf8)
                var offset = 0
                while let hit = needle.withUnsafeBytes({ memmem(base + offset, buffer.count - offset, $0.baseAddress, needle.count) }) {
                    var start = base.distance(to: UnsafeRawPointer(hit))
                    var end = start + 1
                    while start > 0, buffer[start - 1] != UInt8(ascii: "\n") { start -= 1 }
                    while end < buffer.count, buffer[end] != UInt8(ascii: "\n") { end += 1 }
                    offset = end
                    let fields = CSV.parseLine(String(decoding: UnsafeRawBufferPointer(rebasing: buffer[start..<end]), as: UTF8.self))
                    guard fields[columns["stop_id"]!] == stopID else { continue }
                    rows.insert(["trip_id", "stop_sequence", "arrival_time", "departure_time"]
                        .map { fields[columns[$0]!] }.joined(separator: " "))
                }
            }
        }
        return rows
    }

    static func timetable() throws -> StaticTimetable {
        guard let built else { throw TimetableError.missingFile("GTFS_DIR") }
        return try built.get()
    }
}
