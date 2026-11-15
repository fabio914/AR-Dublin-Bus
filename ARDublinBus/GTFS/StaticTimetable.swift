import CoreLocation
import Foundation

enum TimetableError: LocalizedError {
    case missingFile(String)
    case missingColumns(file: String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): "The timetable is missing \(name)."
        case .missingColumns(let file): "\(file) has an unexpected format."
        }
    }
}

/// The static GTFS schedule, held in memory except for `stop_times.txt`,
/// which is too large to load and is searched on demand per stop.
struct StaticTimetable: Sendable {
    let stopsByCode: [String: [GTFSStop]]
    let routes: [String: GTFSRoute]
    let trips: [String: GTFSTrip]
    let services: ServiceCalendar
    let stopTimesURL: URL
    /// Identifies the feed so caches can be invalidated when it changes.
    let version: String

    static let requiredFiles = ["stops.txt", "routes.txt", "trips.txt", "stop_times.txt"]
    static let optionalFiles = ["calendar.txt", "calendar_dates.txt", "feed_info.txt"]

    static func load(from directory: URL) throws -> StaticTimetable {
        for file in requiredFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            throw TimetableError.missingFile(file)
        }

        // stops.txt
        var stopsByCode: [String: [GTFSStop]] = [:]
        try CSV.forEachRow(in: directory.appendingPathComponent("stops.txt")) { row in
            guard let id = row.value("stop_id"), let code = row.value("stop_code") else { return }
            let stop = GTFSStop(
                id: id,
                code: code,
                name: row.value("stop_name") ?? "",
                latitude: row.value("stop_lat").flatMap(Double.init),
                longitude: row.value("stop_lon").flatMap(Double.init)
            )
            stopsByCode[code, default: []].append(stop)
        }

        // routes.txt
        var routes: [String: GTFSRoute] = [:]
        try CSV.forEachRow(in: directory.appendingPathComponent("routes.txt")) { row in
            guard let id = row.value("route_id") else { return }
            routes[id] = GTFSRoute(
                id: id,
                shortName: row.value("route_short_name") ?? row.value("route_long_name") ?? id,
                longName: row.value("route_long_name") ?? ""
            )
        }

        // trips.txt
        var trips: [String: GTFSTrip] = [:]
        trips.reserveCapacity(100_000)
        try CSV.forEachRow(in: directory.appendingPathComponent("trips.txt")) { row in
            guard let id = row.value("trip_id"),
                  let routeID = row.value("route_id"),
                  let serviceID = row.value("service_id") else { return }
            trips[id] = GTFSTrip(id: id, routeID: routeID, serviceID: serviceID, headsign: row.value("trip_headsign") ?? "")
        }

        // calendar.txt / calendar_dates.txt
        var services = ServiceCalendar()
        let calendarURL = directory.appendingPathComponent("calendar.txt")
        if FileManager.default.fileExists(atPath: calendarURL.path) {
            let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
            try CSV.forEachRow(in: calendarURL) { row in
                guard let id = row.value("service_id"),
                      let start = row.value("start_date").flatMap(GTFSDate.init(string:)),
                      let end = row.value("end_date").flatMap(GTFSDate.init(string:)) else { return }
                services.regular[id] = .init(weekdays: days.map { row.value($0) == "1" }, start: start, end: end)
            }
        }
        let datesURL = directory.appendingPathComponent("calendar_dates.txt")
        if FileManager.default.fileExists(atPath: datesURL.path) {
            try CSV.forEachRow(in: datesURL) { row in
                guard let id = row.value("service_id"),
                      let date = row.value("date").flatMap(GTFSDate.init(string:)) else { return }
                switch row.value("exception_type") {
                case "1": services.added[date, default: []].insert(id)
                case "2": services.removed[date, default: []].insert(id)
                default: break
                }
            }
        }

        var version = "unknown"
        let feedInfoURL = directory.appendingPathComponent("feed_info.txt")
        if FileManager.default.fileExists(atPath: feedInfoURL.path) {
            try CSV.forEachRow(in: feedInfoURL) { row in
                version = row.value("feed_version") ?? version
            }
        }

        return StaticTimetable(
            stopsByCode: stopsByCode,
            routes: routes,
            trips: trips,
            services: services,
            stopTimesURL: directory.appendingPathComponent("stop_times.txt"),
            version: version
        )
    }

    /// Every scheduled call at the given stops. Scans the (memory-mapped) `stop_times.txt`.
    func calls(atStopIDs stopIDs: Set<String>) throws -> [StopCall] {
        try Self.scanStopTimes(at: stopTimesURL, stopIDs: stopIDs)
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

    enum ScanStrategy {
        /// Search the raw bytes for each stop ID (fast for one or two stops).
        case perStop
        /// Read every line once, checking its `stop_id` (fast for many stops).
        case singlePass
        case automatic
    }

    /// Finds the rows of a GTFS `stop_times.txt` that belong to `stopIDs` without
    /// parsing the whole (~200 MB) file: only lines that belong to one of the
    /// stops are parsed.
    static func scanStopTimes(at url: URL, stopIDs: Set<String>, strategy: ScanStrategy = .automatic) throws -> [StopCall] {
        let stopIDs = stopIDs.filter { !$0.isEmpty }
        guard !stopIDs.isEmpty else { return [] }

        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [StopCall] in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return [] }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = buffer.count
            let newline = UInt8(ascii: "\n")

            func lineEnd(from offset: Int) -> Int {
                guard offset < count, let found = memchr(base + offset, Int32(newline), count - offset) else { return count }
                return base.distance(to: UnsafeRawPointer(found))
            }

            func line(_ start: Int, _ end: Int) -> String {
                String(decoding: UnsafeBufferPointer(start: bytes + start, count: end - start), as: UTF8.self)
            }

            let headerEnd = lineEnd(from: 0)
            let columns = CSV.columnIndex(for: CSV.parseLine(line(0, headerEnd)))
            guard let tripColumn = columns["trip_id"],
                  let arrivalColumn = columns["arrival_time"],
                  let departureColumn = columns["departure_time"],
                  let stopColumn = columns["stop_id"],
                  let sequenceColumn = columns["stop_sequence"] else {
                throw TimetableError.missingColumns(file: "stop_times.txt")
            }
            let maxColumn = max(tripColumn, arrivalColumn, departureColumn, stopColumn, sequenceColumn)

            var calls: [StopCall] = []

            /// Parses one line and keeps it if it belongs to `expectedStopID` (or any of `stopIDs`).
            func appendCall(lineStart start: Int, end: Int, expectedStopID: String? = nil) {
                let fields = CSV.parseLine(line(start, end))
                guard fields.count > maxColumn else { return }
                let stopID = fields[stopColumn].trimmingCharacters(in: .whitespaces)
                guard expectedStopID.map({ $0 == stopID }) ?? stopIDs.contains(stopID),
                      let sequence = Int(fields[sequenceColumn].trimmingCharacters(in: .whitespaces)) else { return }

                let arrival = GTFSTime.seconds(from: fields[arrivalColumn])
                let departure = GTFSTime.seconds(from: fields[departureColumn])
                guard let arrivalOrDeparture = arrival ?? departure else { return }

                calls.append(StopCall(
                    tripID: fields[tripColumn],
                    stopID: stopID,
                    arrival: arrivalOrDeparture,
                    departure: departure ?? arrivalOrDeparture,
                    stopSequence: sequence
                ))
            }

            let useSinglePass = switch strategy {
            case .perStop: false
            case .singlePass: true
            case .automatic: stopIDs.count > 2
            }

            if useSinglePass {
                // Hash each line's stop_id bytes and only parse lines whose hash matches a wanted stop.
                let wantedHashes = Set(stopIDs.map { Self.fnv1a(Array($0.utf8)) })
                let comma = UInt8(ascii: ","), quote = UInt8(ascii: "\""), space = UInt8(ascii: " "), cr = UInt8(ascii: "\r")
                var start = headerEnd + 1

                while start < count {
                    let end = lineEnd(from: start)
                    defer { start = end + 1 }

                    // Locate the stop_id field by counting commas.
                    var index = start, field = 0, fieldStart = start, sawQuote = false
                    while index < end, field < stopColumn {
                        let byte = bytes[index]
                        if byte == comma { field += 1; fieldStart = index + 1 }
                        else if byte == quote { sawQuote = true }
                        index += 1
                    }
                    if sawQuote {
                        // Quoted fields may contain commas: fall back to a full parse.
                        appendCall(lineStart: start, end: end)
                        continue
                    }
                    guard field == stopColumn else { continue }

                    var fieldEnd = fieldStart
                    while fieldEnd < end, bytes[fieldEnd] != comma, bytes[fieldEnd] != cr { fieldEnd += 1 }
                    var trimmedStart = fieldStart, trimmedEnd = fieldEnd
                    while trimmedStart < trimmedEnd, bytes[trimmedStart] == space { trimmedStart += 1 }
                    while trimmedEnd > trimmedStart, bytes[trimmedEnd - 1] == space { trimmedEnd -= 1 }

                    let hash = Self.fnv1a(UnsafeBufferPointer(start: bytes + trimmedStart, count: trimmedEnd - trimmedStart))
                    if wantedHashes.contains(hash) {
                        appendCall(lineStart: start, end: end)
                    }
                }
            } else {
                for stopID in stopIDs {
                    let needle = Array(stopID.utf8)
                    var offset = headerEnd + 1

                    while offset < count,
                          let hit = needle.withUnsafeBytes({ memmem(base + offset, count - offset, $0.baseAddress, needle.count) }) {
                        let hitOffset = base.distance(to: UnsafeRawPointer(hit))
                        var start = hitOffset
                        while start > 0, bytes[start - 1] != newline { start -= 1 }
                        let end = lineEnd(from: hitOffset + needle.count)
                        offset = end + 1
                        appendCall(lineStart: start, end: end, expectedStopID: stopID)
                    }
                }
            }
            return calls
        }
    }

    /// 64-bit FNV-1a hash.
    private static func fnv1a<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }
}
