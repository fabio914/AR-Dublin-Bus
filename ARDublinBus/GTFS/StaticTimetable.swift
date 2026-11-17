import CoreLocation
import Foundation

enum TimetableError: LocalizedError {
    case missingFile(String)
    case missingColumns(file: String)
    case incompatibleDatabase

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): "The timetable is missing \(name)."
        case .missingColumns(let file): "\(file) has an unexpected format."
        case .incompatibleDatabase: "The timetable needs to be downloaded again."
        }
    }
}

/// The static GTFS schedule, read from the database built by `TimetableDatabaseBuilder`.
///
/// Stops, routes and the service calendar are small and kept in memory; trips, calls
/// and shapes are queried on demand.
final class StaticTimetable: @unchecked Sendable {
    let stopsByCode: [String: [GTFSStop]]
    /// By GTFS `route_id`.
    let routes: [String: GTFSRoute]
    let services: ServiceCalendar
    /// Identifies the feed so caches can be invalidated when it changes.
    let version: String

    private let stopsByRow: [Int: GTFSStop]
    private let stopRowsByID: [String: Int]
    private let searchIndex: StopSearchIndex
    private let database: SQLiteDatabase
    /// SQLite connections must not be used from two threads at once.
    private let lock = NSLock()

    /// Opens a database built by `TimetableDatabaseBuilder`.
    static func open(databaseAt url: URL) throws -> StaticTimetable {
        let database = try SQLiteDatabase(url: url, readOnly: true)
        return try StaticTimetable(database: database)
    }

    /// Builds the database from an extracted GTFS feed, then opens it.
    static func build(fromGTFS directory: URL, databaseURL: URL) throws -> StaticTimetable {
        try TimetableDatabaseBuilder.build(fromGTFS: directory, to: databaseURL)
        return try open(databaseAt: databaseURL)
    }

    private init(database: SQLiteDatabase) throws {
        self.database = database

        var meta: [String: String] = [:]
        let metaQuery = try database.prepare("SELECT key, value FROM meta")
        while try metaQuery.step() { meta[metaQuery.string(0)] = metaQuery.string(1) }
        guard meta["schema_version"] == String(TimetableDatabaseBuilder.schemaVersion) else {
            throw TimetableError.incompatibleDatabase
        }
        version = meta["feed_version"] ?? "unknown"

        var stopsByCode: [String: [GTFSStop]] = [:]
        var stopsByRow: [Int: GTFSStop] = [:]
        var stopRowsByID: [String: Int] = [:]
        let stops = try database.prepare("SELECT id, stop_id, code, name, lat, lon FROM stops")
        while try stops.step() {
            let stop = GTFSStop(id: stops.string(1), code: stops.string(2), name: stops.string(3),
                                latitude: stops.optionalDouble(4), longitude: stops.optionalDouble(5))
            stopsByCode[stop.code, default: []].append(stop)
            stopsByRow[stops.int(0)] = stop
            stopRowsByID[stop.id] = stops.int(0)
        }
        self.stopsByCode = stopsByCode
        self.stopsByRow = stopsByRow
        self.stopRowsByID = stopRowsByID
        searchIndex = StopSearchIndex(stopsByCode: stopsByCode)

        var routes: [String: GTFSRoute] = [:]
        let routeQuery = try database.prepare("SELECT route_id, short_name, long_name FROM routes")
        while try routeQuery.step() {
            let route = GTFSRoute(id: routeQuery.string(0), shortName: routeQuery.string(1), longName: routeQuery.string(2))
            routes[route.id] = route
        }
        self.routes = routes

        var services = ServiceCalendar()
        let serviceQuery = try database.prepare("SELECT service_id, days, start_date, end_date FROM services WHERE days IS NOT NULL")
        while try serviceQuery.step() {
            let days = serviceQuery.int(1)
            services.regular[serviceQuery.string(0)] = .init(
                weekdays: (0..<7).map { days & (1 << $0) != 0 },
                start: GTFSDate(intValue: serviceQuery.int(2)),
                end: GTFSDate(intValue: serviceQuery.int(3))
            )
        }
        let exceptions = try database.prepare("""
            SELECT s.service_id, e.date, e.type FROM service_exceptions e JOIN services s ON s.id = e.service
            """)
        while try exceptions.step() {
            let date = GTFSDate(intValue: exceptions.int(1))
            switch exceptions.int(2) {
            case 1: services.added[date, default: []].insert(exceptions.string(0))
            case 2: services.removed[date, default: []].insert(exceptions.string(0))
            default: break
            }
        }
        self.services = services
    }

    private func withDatabase<T>(_ body: (SQLiteDatabase) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(database)
    }

    // MARK: Calls

    /// The scheduled calls at the given stops (GTFS `stop_id`s), including calls where the
    /// trip ends (`isLastStop`).
    ///
    /// - Parameter arrivalWindows: only calls arriving within one of these ranges (seconds after
    ///   the start of the service day) are returned; `nil` returns every call.
    func calls(atStopIDs stopIDs: Set<String>, arrivalWindows: [ClosedRange<Int>]? = nil) throws -> [StopCall] {
        let rows = stopIDs.compactMap { id in stopRowsByID[id].map { (id: id, row: $0) } }
        guard !rows.isEmpty else { return [] }

        // Overlapping windows are merged, so no call is returned twice.
        var windows: [ClosedRange<Int>] = []
        for window in (arrivalWindows ?? [Int(Int32.min)...Int(Int32.max)]).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = windows.last, window.lowerBound <= last.upperBound {
                windows[windows.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else {
                windows.append(window)
            }
        }

        return try withDatabase { database in
            let query = try database.prepare("""
                SELECT t.trip_id, t.start + ps.departure_offset - ps.dwell, t.start + ps.departure_offset, ps.sequence,
                       r.route_id, s.service_id, h.text, ps.is_last
                FROM pattern_stops ps
                JOIN trips t ON t.pattern = ps.pattern
                JOIN routes r ON r.id = t.route
                JOIN services s ON s.id = t.service
                JOIN headsigns h ON h.id = t.headsign
                WHERE ps.stop = ?1
                  -- The arrival is within the window; written as a range of trip start times so
                  -- the (pattern, start) index finds the trips.
                  AND t.start BETWEEN ?2 - ps.departure_offset + ps.dwell AND ?3 - ps.departure_offset + ps.dwell
                """)
            var calls: [StopCall] = []
            for (stopID, row) in rows {
                for window in windows {
                    query.bind(row, at: 1)
                    query.bind(window.lowerBound, at: 2)
                    query.bind(window.upperBound, at: 3)
                    while try query.step() {
                        calls.append(StopCall(
                            tripID: query.string(0), stopID: stopID,
                            arrival: query.int(1), departure: query.int(2), stopSequence: query.int(3),
                            routeID: query.string(4), serviceID: query.string(5), headsign: query.string(6),
                            isLastStop: query.int(7) != 0
                        ))
                    }
                    query.reset()
                }
            }
            return calls
        }
    }

    // MARK: Trips

    /// A trip's stops in order and its shape, or `nil` if the trip isn't in the timetable.
    func tripDetails(tripID: String) throws -> TripDetails? {
        try withDatabase { database in
            let query = try database.prepare("""
                SELECT t.start, p.calls, sh.points, r.route_id, s.service_id, h.text
                FROM trips t
                JOIN routes r ON r.id = t.route
                JOIN services s ON s.id = t.service
                JOIN headsigns h ON h.id = t.headsign
                LEFT JOIN patterns p ON p.id = t.pattern
                LEFT JOIN shapes sh ON sh.id = t.shape
                WHERE t.trip_id = ?
                """)
            query.bind(tripID, at: 1)
            guard try query.step() else { return nil }

            let start = query.optionalInt(0) ?? 0
            let routeID = query.string(3)
            let serviceID = query.string(4)
            let headsign = query.string(5)

            // Each call is four integers: sequence, stop row, departure offset, dwell.
            let values = ShapeCoding.decodeIntegers(query.data(1))
            var calls: [TripDetails.Call] = []
            var index = 0
            while index + 3 < values.count {
                let (sequence, stopRow, offset, dwell) = (values[index], values[index + 1], values[index + 2], values[index + 3])
                index += 4
                guard let stop = stopsByRow[stopRow] else { continue }
                calls.append(.init(stop: stop, call: StopCall(
                    tripID: tripID, stopID: stop.id,
                    arrival: start + offset - dwell, departure: start + offset, stopSequence: sequence,
                    routeID: routeID, serviceID: serviceID, headsign: headsign
                )))
            }

            return TripDetails(
                tripID: tripID,
                route: routes[routeID] ?? GTFSRoute(id: routeID, shortName: routeID, longName: ""),
                headsign: headsign,
                serviceID: serviceID,
                calls: calls,
                shape: ShapeCoding.decode(query.data(2))
            )
        }
    }

    // MARK: Lines

    /// Every route leaving the stops with this code (trips ending there are left out), with
    /// its destinations and its paths from the stop onwards, sorted naturally by route name.
    func lines(atStopCode code: String) throws -> [StopLine] {
        let stopRows = (stopsByCode[code] ?? []).compactMap { stopRowsByID[$0.id] }
        guard !stopRows.isEmpty else { return [] }

        struct Variant {
            let pattern: Int
            let sequence: Int
            let calls: Data
            let routeID: String
            let headsign: String
            let shape: Int?
            let trips: Int
        }

        return try withDatabase { database in
            // Each way of leaving the stop: a pattern (the stops a trip makes) with the route,
            // destination and shape of the trips using it.
            let query = try database.prepare("""
                SELECT ps.pattern, ps.sequence, p.calls, r.route_id, h.text, t.shape, COUNT(*)
                FROM pattern_stops ps
                JOIN patterns p ON p.id = ps.pattern
                JOIN trips t ON t.pattern = ps.pattern
                JOIN routes r ON r.id = t.route
                JOIN headsigns h ON h.id = t.headsign
                WHERE ps.stop = ? AND ps.is_last = 0
                GROUP BY ps.pattern, ps.sequence, t.route, t.headsign, t.shape
                """)
            var variants: [Variant] = []
            for row in stopRows {
                query.bind(row, at: 1)
                while try query.step() {
                    variants.append(Variant(
                        pattern: query.int(0), sequence: query.int(1), calls: query.data(2),
                        routeID: query.string(3), headsign: query.string(4), shape: query.optionalInt(5),
                        trips: query.int(6)
                    ))
                }
                query.reset()
            }

            let shapeQuery = try database.prepare("SELECT points FROM shapes WHERE id = ?")
            var shapes: [Int: [CLLocationCoordinate2D]] = [:]
            func shape(_ row: Int) throws -> [CLLocationCoordinate2D] {
                if let cached = shapes[row] { return cached }
                shapeQuery.bind(row, at: 1)
                let points = try shapeQuery.step() ? ShapeCoding.decode(shapeQuery.data(0)) : []
                shapeQuery.reset()
                shapes[row] = points
                return points
            }

            struct Line {
                var tripsByHeadsign: [String: Int] = [:]
                /// Keyed so the same path is drawn once.
                var paths: [String: [CLLocationCoordinate2D]] = [:]
            }
            var lines: [String: Line] = [:]
            /// The earliest start found on each shape, per route: a later one is part of it.
            var shapeStarts: [String: [Int: Int]] = [:]

            for variant in variants {
                lines[variant.routeID, default: Line()].tripsByHeadsign[variant.headsign, default: 0] += variant.trips

                // Calls are four integers each: sequence, stop row, departure offset, dwell.
                let values = ShapeCoding.decodeIntegers(variant.calls)
                var sequences: [Int] = []
                var stops: [GTFSStop?] = []
                var index = 0
                while index + 3 < values.count {
                    sequences.append(values[index])
                    stops.append(stopsByRow[values[index + 1]])
                    index += 4
                }
                guard let target = sequences.firstIndex(of: variant.sequence) else { continue }
                let coordinates = stops.map { $0?.coordinate }
                let points = try variant.shape.map(shape) ?? []
                let (path, shapeStart) = StopLinePath.remainder(of: points, stops: coordinates, target: target)
                guard path.count > 1 else { continue }

                if let shapeRow = variant.shape, let shapeStart {
                    // A later start on the same shape (a loop calling here twice) is part of this path.
                    if let existing = shapeStarts[variant.routeID]?[shapeRow], existing <= shapeStart { continue }
                    shapeStarts[variant.routeID, default: [:]][shapeRow] = shapeStart
                    lines[variant.routeID]?.paths["shape \(shapeRow)"] = path
                } else {
                    // No usable shape: the path joins the stops, so key it by them.
                    let key = "stops " + stops[target...].map { $0?.id ?? "?" }.joined(separator: ",")
                    lines[variant.routeID]?.paths[key] = path
                }
            }

            return lines.map { routeID, line in
                StopLine(
                    route: routes[routeID] ?? GTFSRoute(id: routeID, shortName: routeID, longName: ""),
                    headsigns: line.tripsByHeadsign.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key),
                    paths: line.paths.sorted { $0.key < $1.key }.map(\.value)
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.route.shortName.localizedStandardCompare(rhs.route.shortName)
                return order == .orderedSame ? lhs.route.id < rhs.route.id : order == .orderedAscending
            }
        }
    }

    /// A route's trips leaving the stops with this code (trips ending there are left out),
    /// grouped by destination, each with a typical trip's stops and path. `nil` if the stop or
    /// route isn't in the timetable.
    func lineDetails(routeID: String, stopCode: String) throws -> LineDetails? {
        let codeStops = stopsByCode[stopCode] ?? []
        let stopRows = codeStops.compactMap { stopRowsByID[$0.id] }
        guard !stopRows.isEmpty, let route = routes[routeID],
              let stop = codeStops.first(where: { $0.coordinate != nil }) ?? codeStops.first else { return nil }

        struct Call {
            let departure: LineDirection.Departure
            let pattern: Int
            let shape: Int?
        }
        /// The trips sharing a pattern and shape, so their stops and path are the same.
        struct Variant: Hashable {
            let pattern: Int
            let sequence: Int
            let shape: Int?
        }

        return try withDatabase { database in
            let query = try database.prepare("""
                SELECT t.trip_id, s.service_id, t.start + ps.departure_offset - ps.dwell, ps.sequence,
                       ps.pattern, t.shape, h.text
                FROM pattern_stops ps
                JOIN trips t ON t.pattern = ps.pattern
                JOIN routes r ON r.id = t.route
                JOIN services s ON s.id = t.service
                JOIN headsigns h ON h.id = t.headsign
                WHERE ps.stop = ?1 AND ps.is_last = 0 AND r.route_id = ?2
                """)
            var callsByHeadsign: [String: [Call]] = [:]
            for row in stopRows {
                guard let stopID = stopsByRow[row]?.id else { continue }
                query.bind(row, at: 1)
                query.bind(routeID, at: 2)
                while try query.step() {
                    let departure = LineDirection.Departure(
                        tripID: query.string(0), serviceID: query.string(1), time: query.int(2),
                        stopID: stopID, stopSequence: query.int(3)
                    )
                    callsByHeadsign[query.string(6), default: []]
                        .append(Call(departure: departure, pattern: query.int(4), shape: query.optionalInt(5)))
                }
                query.reset()
            }

            let patternQuery = try database.prepare("SELECT calls FROM patterns WHERE id = ?")
            let shapeQuery = try database.prepare("SELECT points FROM shapes WHERE id = ?")

            let directions = try callsByHeadsign.compactMap { headsign, calls -> LineDirection? in
                // The stops and path of the most frequent variant stand for the destination.
                var counts: [Variant: Int] = [:]
                for call in calls {
                    counts[Variant(pattern: call.pattern, sequence: call.departure.stopSequence, shape: call.shape), default: 0] += 1
                }
                guard let variant = counts.max(by: { ($0.value, $1.key.pattern) < ($1.value, $0.key.pattern) })?.key else { return nil }

                patternQuery.bind(variant.pattern, at: 1)
                let values = try patternQuery.step() ? ShapeCoding.decodeIntegers(patternQuery.data(0)) : []
                patternQuery.reset()

                // Calls are four integers each: sequence, stop row, departure offset, dwell.
                var entries: [(stop: GTFSStop, sequence: Int, arrival: Int)] = []
                var index = 0
                while index + 3 < values.count {
                    if let stop = stopsByRow[values[index + 1]] {
                        entries.append((stop, values[index], values[index + 2] - values[index + 3]))
                    }
                    index += 4
                }
                guard let target = entries.firstIndex(where: { $0.sequence == variant.sequence }) else { return nil }
                let origin = entries[target].arrival
                let stops = entries.map { LineDirection.Stop(stop: $0.stop, sequence: $0.sequence, offset: $0.arrival - origin) }

                var shape: [CLLocationCoordinate2D] = []
                if let shapeRow = variant.shape {
                    shapeQuery.bind(shapeRow, at: 1)
                    if try shapeQuery.step() { shape = ShapeCoding.decode(shapeQuery.data(0)) }
                    shapeQuery.reset()
                }
                if shape.count < 2 { shape = stops.compactMap(\.stop.coordinate) }

                return LineDirection(
                    headsign: headsign,
                    stops: stops,
                    stopIndex: target,
                    shape: shape,
                    departures: calls.map(\.departure).sorted { ($0.time, $0.tripID) < ($1.time, $1.tripID) }
                )
            }
            .sorted { ($0.departures.count, $1.headsign) > ($1.departures.count, $0.headsign) }

            return LineDetails(route: route, stop: stop, directions: directions, services: services)
        }
    }

    // MARK: Stops

    /// Stops inside `bounds`, using the R-tree index. `isTruncated` is true when more
    /// than `limit` stops are inside.
    func stops(in bounds: CoordinateBounds, limit: Int) throws -> (stops: [GTFSStop], isTruncated: Bool) {
        try withDatabase { database in
            let query = try database.prepare("""
                SELECT id FROM stops_index
                WHERE min_lat <= ? AND max_lat >= ? AND min_lon <= ? AND max_lon >= ?
                LIMIT ?
                """)
            query.bind(bounds.maxLatitude, at: 1)
            query.bind(bounds.minLatitude, at: 2)
            query.bind(bounds.maxLongitude, at: 3)
            query.bind(bounds.minLongitude, at: 4)
            query.bind(limit + 1, at: 5)
            var stops: [GTFSStop] = []
            while try query.step() {
                if let stop = stopsByRow[query.int(0)] { stops.append(stop) }
            }
            let isTruncated = stops.count > limit
            return (Array(stops.prefix(limit)), isTruncated)
        }
    }

    /// Stops whose number or name matches `query` (see `StopSearchIndex`), with their routes.
    func searchStops(_ query: String, limit: Int) throws -> [StopSearchResult] {
        try withRoutes(searchIndex.search(query, limit: limit))
    }

    /// Each stop with the routes calling at it (at any stop sharing its code), sorted naturally.
    func withRoutes(_ stops: [GTFSStop]) throws -> [StopSearchResult] {
        try withDatabase { database in
            let routeQuery = try database.prepare("""
                SELECT r.short_name FROM stop_routes sr
                JOIN routes r ON r.id = sr.route
                WHERE sr.stop = ?
                """)
            return try stops.map { stop in
                var routes: Set<String> = []
                for row in (stopsByCode[stop.code] ?? [stop]).compactMap({ stopRowsByID[$0.id] }) {
                    routeQuery.bind(row, at: 1)
                    while try routeQuery.step() { routes.insert(routeQuery.string(0)) }
                    routeQuery.reset()
                }
                let sorted = routes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                return StopSearchResult(stop: stop, routes: sorted)
            }
        }
    }

    /// Stops within `radius` metres of `coordinate`, nearest first, one entry per stop code.
    /// If none are that close, the nearest `fallbackCount` stops are returned instead.
    func stops(near coordinate: CLLocationCoordinate2D, within radius: CLLocationDistance,
               limit: Int, fallbackCount: Int = 3) -> [NearbyStop] {
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let all = stopsByCode.compactMap { _, stops -> NearbyStop? in
            guard let stop = stops.first(where: { $0.latitude != nil && $0.longitude != nil }) else { return nil }
            let location = CLLocation(latitude: stop.latitude!, longitude: stop.longitude!)
            return NearbyStop(stop: stop, stopIDs: Set(stops.map(\.id)), distance: origin.distance(from: location))
        }
        .sorted { $0.distance < $1.distance }

        let close = all.prefix { $0.distance <= radius }
        return Array(close.isEmpty ? all.prefix(fallbackCount) : close.prefix(limit))
    }
}

extension GTFSDate {
    /// From `YYYYMMDD` as an integer.
    init(intValue: Int) {
        self.init(year: intValue / 10_000, month: (intValue / 100) % 100, day: intValue % 100)
    }
}
