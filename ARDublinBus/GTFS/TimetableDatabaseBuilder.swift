import CoreLocation
import Foundation

/// Converts an extracted GTFS feed into the compact SQLite database the app reads.
///
/// The ~260 MB of CSV files become a database of about 13 MB:
///
/// - `stop_times.txt` (millions of rows) is reduced to **trip patterns**. Most trips repeat
///   another trip's stops with the same gaps between them, just starting at a different
///   time, so each trip stores a pattern and a start time, and `pattern_stops` lists each
///   pattern's stops once. A stop's calls are found by joining its patterns with the trips
///   that use them.
/// - `shapes.txt` is deduplicated by geometry and stored as one compact blob per shape.
/// - Stops get an R-tree index for map queries.
enum TimetableDatabaseBuilder {
    static let schemaVersion = 3

    static let requiredFiles = ["stops.txt", "routes.txt", "trips.txt", "stop_times.txt"]
    static let optionalFiles = ["calendar.txt", "calendar_dates.txt", "feed_info.txt", "shapes.txt"]

    static let schema = """
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE stops (id INTEGER PRIMARY KEY, stop_id TEXT NOT NULL, code TEXT NOT NULL, name TEXT NOT NULL, lat REAL, lon REAL);
    CREATE VIRTUAL TABLE stops_index USING rtree(id, min_lat, max_lat, min_lon, max_lon);
    CREATE TABLE routes (id INTEGER PRIMARY KEY, route_id TEXT NOT NULL, short_name TEXT NOT NULL, long_name TEXT NOT NULL);
    CREATE TABLE services (id INTEGER PRIMARY KEY, service_id TEXT NOT NULL, days INTEGER, start_date INTEGER, end_date INTEGER);
    CREATE TABLE service_exceptions (service INTEGER NOT NULL, date INTEGER NOT NULL, type INTEGER NOT NULL);
    CREATE TABLE headsigns (id INTEGER PRIMARY KEY, text TEXT NOT NULL);
    CREATE TABLE shapes (id INTEGER PRIMARY KEY, points BLOB NOT NULL);
    -- Each pattern's calls in order, as varints: sequence, stop, departure offset, dwell (repeated).
    CREATE TABLE patterns (id INTEGER PRIMARY KEY, calls BLOB NOT NULL);
    CREATE TABLE trips (
        id INTEGER PRIMARY KEY, trip_id TEXT NOT NULL, route INTEGER NOT NULL, service INTEGER NOT NULL,
        headsign INTEGER NOT NULL, pattern INTEGER, start INTEGER, shape INTEGER
    );
    -- departure_offset: seconds after the trip's start; dwell: departure minus arrival;
    -- is_last: 1 at the final stop of a pattern with several stops (nobody boards there).
    CREATE TABLE pattern_stops (
        stop INTEGER NOT NULL, pattern INTEGER NOT NULL, sequence INTEGER NOT NULL,
        departure_offset INTEGER NOT NULL, dwell INTEGER NOT NULL, is_last INTEGER NOT NULL,
        PRIMARY KEY (stop, pattern, sequence)
    ) WITHOUT ROWID;
    -- The routes calling at each stop, for the badges in search results and AR labels.
    CREATE TABLE stop_routes (stop INTEGER NOT NULL, route INTEGER NOT NULL, PRIMARY KEY (stop, route)) WITHOUT ROWID;
    """

    static let indexes = """
    CREATE UNIQUE INDEX trips_trip_id ON trips(trip_id);
    CREATE INDEX trips_pattern ON trips(pattern, start);
    """

    struct Statistics: Sendable {
        var stops = 0
        var trips = 0
        var calls = 0
        var patterns = 0
        var shapes = 0
        /// How long each step took, for tuning.
        var durations: [(step: String, duration: Duration)] = []
    }

    /// Builds the database at `url` (replacing any existing file) from the GTFS files in `directory`.
    @discardableResult
    static func build(fromGTFS directory: URL, to url: URL) throws -> Statistics {
        let fileManager = FileManager.default
        for file in requiredFiles where !fileManager.fileExists(atPath: directory.appendingPathComponent(file).path) {
            throw TimetableError.missingFile(file)
        }
        try? fileManager.removeItem(at: url)

        let database = try SQLiteDatabase(url: url, readOnly: false)
        try database.execute("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;")
        try database.execute(schema)

        var builder = Builder(directory: directory, database: database)
        let clock = ContinuousClock()
        var durations: [(String, Duration)] = []
        func step(_ name: String, _ body: () throws -> Void) rethrows {
            durations.append((name, try clock.measure(body)))
        }
        try database.transaction {
            try step("stops, routes, services") {
                try builder.importStops()
                try builder.importRoutes()
                try builder.importServices()
            }
            try step("trips") { try builder.importTrips() }
            try step("stop times") { try builder.importStopTimes() }
            try step("shapes") { try builder.importShapes() }
            try step("patterns") { try builder.writeTripsAndPatterns() }
            try builder.writeMeta()
        }
        try step("indexes") { try database.execute(indexes) }
        var statistics = builder.statistics
        statistics.durations = durations
        return statistics
    }

    /// Holds the lookup tables while importing.
    private struct Builder {
        let directory: URL
        let database: SQLiteDatabase
        var statistics = Statistics()

        var stopRows: [String: Int32] = [:]
        var routeRows: [String: Int] = [:]
        var serviceRows: [String: Int] = [:]
        var headsignRows: [String: Int] = [:]

        struct Trip {
            let id: String
            let route: Int
            let service: Int
            let headsign: Int
            let shapeID: String?
        }

        struct Call {
            let sequence: Int32
            let stop: Int32
            let arrival: Int32
            let departure: Int32
        }

        var trips: [Trip] = []
        var tripIndex: [String: Int] = [:]
        var callsByTrip: [[Call]] = []
        /// Shape row for each GTFS shape_id (after deduplicating geometry).
        var shapeRows: [String: Int] = [:]

        init(directory: URL, database: SQLiteDatabase) {
            self.directory = directory
            self.database = database
        }

        private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
        private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

        mutating func importStops() throws {
            let insert = try database.prepare("INSERT INTO stops VALUES (?, ?, ?, ?, ?, ?)")
            let index = try database.prepare("INSERT INTO stops_index VALUES (?, ?, ?, ?, ?)")
            try CSV.forEachRow(in: url("stops.txt")) { row in
                guard let id = row.value("stop_id"), stopRows[id] == nil else { return }
                let rowID = Int32(stopRows.count + 1)
                stopRows[id] = rowID
                let latitude = row.value("stop_lat").flatMap(Double.init)
                let longitude = row.value("stop_lon").flatMap(Double.init)
                try insert.run(Int(rowID), id, row.value("stop_code") ?? id, row.value("stop_name") ?? "", latitude, longitude)
                if let latitude, let longitude {
                    try index.run(Int(rowID), latitude, latitude, longitude, longitude)
                }
            }
            statistics.stops = stopRows.count
        }

        mutating func importRoutes() throws {
            try CSV.forEachRow(in: url("routes.txt")) { row in
                guard let id = row.value("route_id") else { return }
                _ = try routeRow(id, shortName: row.value("route_short_name"), longName: row.value("route_long_name"))
            }
        }

        private mutating func routeRow(_ id: String, shortName: String? = nil, longName: String? = nil) throws -> Int {
            if let row = routeRows[id] { return row }
            let row = routeRows.count + 1
            routeRows[id] = row
            try database.prepare("INSERT INTO routes VALUES (?, ?, ?, ?)")
                .run(row, id, shortName ?? longName ?? id, longName ?? "")
            return row
        }

        mutating func importServices() throws {
            if exists("calendar.txt") {
                let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
                try CSV.forEachRow(in: url("calendar.txt")) { row in
                    guard let id = row.value("service_id"),
                          let start = row.value("start_date").flatMap(GTFSDate.init(string:)),
                          let end = row.value("end_date").flatMap(GTFSDate.init(string:)) else { return }
                    let mask = days.enumerated().reduce(0) { mask, day in row.value(day.element) == "1" ? mask | (1 << day.offset) : mask }
                    _ = try serviceRow(id, days: mask, start: start.intValue, end: end.intValue)
                }
            }
            if exists("calendar_dates.txt") {
                let insert = try database.prepare("INSERT INTO service_exceptions VALUES (?, ?, ?)")
                try CSV.forEachRow(in: url("calendar_dates.txt")) { row in
                    guard let id = row.value("service_id"),
                          let date = row.value("date").flatMap(GTFSDate.init(string:)),
                          let type = row.value("exception_type").flatMap(Int.init) else { return }
                    try insert.run(try serviceRow(id), date.intValue, type)
                }
            }
        }

        private mutating func serviceRow(_ id: String, days: Int? = nil, start: Int? = nil, end: Int? = nil) throws -> Int {
            if let row = serviceRows[id] { return row }
            let row = serviceRows.count + 1
            serviceRows[id] = row
            try database.prepare("INSERT INTO services VALUES (?, ?, ?, ?, ?)").run(row, id, days, start, end)
            return row
        }

        mutating func importTrips() throws {
            try CSV.forEachRow(in: url("trips.txt")) { row in
                guard let id = row.value("trip_id"), tripIndex[id] == nil,
                      let routeID = row.value("route_id"),
                      let serviceID = row.value("service_id") else { return }
                let headsign = row.value("trip_headsign") ?? ""
                let headsignRow: Int
                if let existing = headsignRows[headsign] {
                    headsignRow = existing
                } else {
                    headsignRow = headsignRows.count + 1
                    headsignRows[headsign] = headsignRow
                }
                tripIndex[id] = trips.count
                trips.append(Trip(
                    id: id,
                    route: try routeRow(routeID),
                    service: try serviceRow(serviceID),
                    headsign: headsignRow,
                    shapeID: row.value("shape_id")
                ))
            }
            let insert = try database.prepare("INSERT INTO headsigns VALUES (?, ?)")
            for (text, row) in headsignRows { try insert.run(row, text) }
            callsByTrip = Array(repeating: [], count: trips.count)
            statistics.trips = trips.count
        }

        mutating func importStopTimes() throws {
            // Rows are normally grouped by trip, so remember the last trip_id's bytes
            // to avoid building a String and a dictionary lookup for every row.
            var lastTripBytes: [UInt8] = []
            var lastTrip: Int?
            var calls = 0
            let stopRows = self.stopRows
            let tripIndex = self.tripIndex

            try CSVByteReader.forEachRow(
                in: url("stop_times.txt"),
                columns: ["trip_id", "arrival_time", "departure_time", "stop_id", "stop_sequence"]
            ) { row in
                let tripBytes = row.field(0)
                if !lastTripBytes.withUnsafeBufferPointer({ CSVByteReader.equal($0, tripBytes) }) {
                    lastTripBytes = Array(tripBytes)
                    lastTrip = tripIndex[String(decoding: tripBytes, as: UTF8.self)]
                }
                let trip = lastTrip
                guard let trip,
                      let stop = stopRows[row.string(3)],
                      let sequence = row.int(4) else { return }
                let arrival = row.time(1)
                let departure = row.time(2)
                guard let arrivalOrDeparture = arrival ?? departure else { return }
                callsByTrip[trip].append(Call(
                    sequence: Int32(sequence),
                    stop: stop,
                    arrival: Int32(arrivalOrDeparture),
                    departure: Int32(departure ?? arrivalOrDeparture)
                ))
                calls += 1
            }
            statistics.calls = calls
        }

        mutating func importShapes() throws {
            guard exists("shapes.txt") else { return }
            typealias Point = (sequence: Int, latitude: Double, longitude: Double)
            var pointsByShape: [String: [Point]] = [:]
            // Rows are normally grouped by shape: collect the current shape's points locally.
            var currentShapeBytes: [UInt8] = []
            var currentShape: String?
            var currentPoints: [Point] = []
            func flush() {
                guard let currentShape, !currentPoints.isEmpty else { return }
                pointsByShape[currentShape, default: []].append(contentsOf: currentPoints)
                currentPoints.removeAll(keepingCapacity: true)
            }

            try CSVByteReader.forEachRow(
                in: url("shapes.txt"),
                columns: ["shape_id", "shape_pt_lat", "shape_pt_lon", "shape_pt_sequence"]
            ) { row in
                guard let latitude = row.double(1), let longitude = row.double(2), let sequence = row.int(3) else { return }
                let shapeBytes = row.field(0)
                if !currentShapeBytes.withUnsafeBufferPointer({ CSVByteReader.equal($0, shapeBytes) }) {
                    flush()
                    currentShapeBytes = Array(shapeBytes)
                    currentShape = String(decoding: shapeBytes, as: UTF8.self)
                }
                currentPoints.append((sequence, latitude, longitude))
            }
            flush()

            let insert = try database.prepare("INSERT INTO shapes VALUES (?, ?)")
            var rowsByGeometry: [[Int32]: Int] = [:]
            for (shapeID, points) in pointsByShape {
                let sorted = points.sorted { $0.sequence < $1.sequence }
                let coordinates = sorted.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                // Identical geometry (to ~1 m) is stored once.
                var key: [Int32] = []
                key.reserveCapacity(coordinates.count * 2)
                for point in coordinates {
                    key.append(Int32((point.latitude * ShapeCoding.scale).rounded()))
                    key.append(Int32((point.longitude * ShapeCoding.scale).rounded()))
                }
                if let row = rowsByGeometry[key] {
                    shapeRows[shapeID] = row
                    continue
                }
                let row = rowsByGeometry.count + 1
                rowsByGeometry[key] = row
                shapeRows[shapeID] = row
                try insert.run(row, ShapeCoding.encode(coordinates))
            }
            statistics.shapes = rowsByGeometry.count
        }

        mutating func writeTripsAndPatterns() throws {
            var patternRows: [[Int]: Int] = [:]
            var patternStops: [(stop: Int32, pattern: Int32, sequence: Int32, offset: Int32, dwell: Int32, isLast: Bool)] = []
            let insertTrip = try database.prepare("INSERT INTO trips VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
            /// The routes using each pattern.
            var routesByPattern: [Int: Set<Int>] = [:]
            let insertPattern = try database.prepare("INSERT INTO patterns VALUES (?, ?)")

            for (index, trip) in trips.enumerated() {
                var pattern: Int?
                var start: Int?
                let calls = callsByTrip[index].sorted { $0.sequence < $1.sequence }
                callsByTrip[index] = []

                if let first = calls.first {
                    let tripStart = Int(first.arrival)
                    var key: [Int] = []
                    key.reserveCapacity(calls.count * 4)
                    for call in calls {
                        key.append(Int(call.sequence))
                        key.append(Int(call.stop))
                        key.append(Int(call.departure) - tripStart)
                        key.append(Int(call.departure - call.arrival))
                    }
                    if let existing = patternRows[key] {
                        pattern = existing
                    } else {
                        let row = patternRows.count + 1
                        patternRows[key] = row
                        try insertPattern.run(row, ShapeCoding.encodeIntegers(key))
                        for (position, call) in calls.enumerated() {
                            patternStops.append((call.stop, Int32(row), call.sequence,
                                                 Int32(Int(call.departure) - tripStart), call.departure - call.arrival,
                                                 calls.count > 1 && position == calls.count - 1))
                        }
                        pattern = row
                    }
                    start = tripStart
                }
                if let pattern { routesByPattern[pattern, default: []].insert(trip.route) }

                insertTrip.bind(index + 1, at: 1)
                insertTrip.bind(trip.id, at: 2)
                insertTrip.bind(trip.route, at: 3)
                insertTrip.bind(trip.service, at: 4)
                insertTrip.bind(trip.headsign, at: 5)
                insertTrip.bind(pattern, at: 6)
                insertTrip.bind(start, at: 7)
                insertTrip.bind(trip.shapeID.flatMap { shapeRows[$0] }, at: 8)
                _ = try insertTrip.step()
                insertTrip.reset()
            }

            // Insert in primary-key order, which keeps the WITHOUT ROWID table compact.
            patternStops.sort { ($0.stop, $0.pattern, $0.sequence) < ($1.stop, $1.pattern, $1.sequence) }
            let insert = try database.prepare("INSERT INTO pattern_stops VALUES (?, ?, ?, ?, ?, ?)")
            for row in patternStops {
                insert.bind(Int(row.stop), at: 1)
                insert.bind(Int(row.pattern), at: 2)
                insert.bind(Int(row.sequence), at: 3)
                insert.bind(Int(row.offset), at: 4)
                insert.bind(Int(row.dwell), at: 5)
                insert.bind(row.isLast ? 1 : 0, at: 6)
                _ = try insert.step()
                insert.reset()
            }
            statistics.patterns = patternRows.count

            // Every route of every pattern calling at a stop, once each, in primary-key order.
            var stopRoutes: Set<[Int]> = []
            for row in patternStops {
                for route in routesByPattern[Int(row.pattern)] ?? [] { stopRoutes.insert([Int(row.stop), route]) }
            }
            let insertStopRoute = try database.prepare("INSERT INTO stop_routes VALUES (?, ?)")
            for pair in stopRoutes.sorted(by: { ($0[0], $0[1]) < ($1[0], $1[1]) }) {
                try insertStopRoute.run(pair[0], pair[1])
            }
        }

        mutating func writeMeta() throws {
            var version = "unknown"
            if exists("feed_info.txt") {
                try CSV.forEachRow(in: url("feed_info.txt")) { row in version = row.value("feed_version") ?? version }
            }
            let insert = try database.prepare("INSERT INTO meta VALUES (?, ?)")
            try insert.run("schema_version", String(TimetableDatabaseBuilder.schemaVersion))
            try insert.run("feed_version", version)
        }
    }
}
