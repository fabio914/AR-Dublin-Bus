import CoreLocation
import simd
import Foundation

/// Everything the departures panel shows for one stop.
struct StopBoard: Equatable, Sendable {
    let stopCode: String
    let stopName: String
    let departures: [Departure]
    /// When live data is unavailable, why (departures then come from the timetable only).
    let realtimeIssue: String?
    let realtimeTimestamp: Date?
    let generatedAt: Date

    var hasLiveData: Bool { realtimeIssue == nil && realtimeTimestamp != nil }
}

enum DepartureServiceError: LocalizedError, Equatable {
    case unknownStop(String)
    case unknownTrip

    var errorDescription: String? {
        switch self {
        case .unknownStop(let code): "Stop \(code) isn't in the Dublin Bus timetable."
        case .unknownTrip: "This bus isn't in the timetable any more."
        }
    }
}

/// Builds boards, map stops and trip journeys from the timetable and the realtime feed.
actor DepartureService {
    let timetableStore: TimetableStore
    let realtimeClient: RealtimeClient
    private let calculator: DepartureCalculator

    init(timetableStore: TimetableStore, realtimeClient: RealtimeClient, calculator: DepartureCalculator = .init()) {
        self.timetableStore = timetableStore
        self.realtimeClient = realtimeClient
        self.calculator = calculator
    }

    /// All stop codes in the timetable (used to validate OCR results).
    func knownStopCodes() async throws -> Set<String> {
        Set(try await timetableStore.loadedTimetable().stopsByCode.keys)
    }

    func board(forStopCode code: String, now: Date = .now) async throws -> StopBoard {
        try await boards(forStopCodes: [code], now: now)[0]
    }

    /// Boards for several stops, sharing one realtime snapshot.
    /// Results are in the order of `codes`.
    func boards(forStopCodes codes: [String], now: Date = .now) async throws -> [StopBoard] {
        let timetable = try await timetableStore.loadedTimetable()
        var stopsByCode: [String: [GTFSStop]] = [:]
        for code in codes {
            guard let stops = timetable.stopsByCode[code], !stops.isEmpty else {
                throw DepartureServiceError.unknownStop(code)
            }
            stopsByCode[code] = stops
        }
        let callsByCode = try await calls(for: stopsByCode, timetable: timetable)
        let (realtime, realtimeIssue) = await realtimeSnapshot(now: now)

        return codes.map { code in
            let stops = stopsByCode[code]!
            let departures = calculator.departures(
                calls: callsByCode[code] ?? [],
                stopIDs: Set(stops.map(\.id)),
                timetable: timetable,
                realtime: realtime,
                now: now
            )
            return StopBoard(
                stopCode: code,
                stopName: stops[0].name,
                departures: departures,
                realtimeIssue: realtimeIssue,
                realtimeTimestamp: realtime?.feedTimestamp ?? realtime?.fetchedAt,
                generatedAt: now
            )
        }
    }

    /// Stops around a location, nearest first.
    static let nearbyRadius: CLLocationDistance = 600

    func nearbyStops(around coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = nearbyRadius, limit: Int = 12) async throws -> [NearbyStop] {
        try await timetableStore.loadedTimetable().stops(near: coordinate, within: radius, limit: limit)
    }

    /// Stops inside a map area, at most `limit` of them.
    func stops(in bounds: CoordinateBounds, limit: Int) async throws -> (stops: [GTFSStop], isTruncated: Bool) {
        let timetable = try await timetableStore.loadedTimetable()
        return try await Task.detached(priority: .userInitiated) {
            try timetable.stops(in: bounds, limit: limit)
        }.value
    }

    /// Stops matching a number or a name, for the Look up screen.
    func searchStops(_ query: String, limit: Int = 30) async throws -> [StopSearchResult] {
        let timetable = try await timetableStore.loadedTimetable()
        return try await Task.detached(priority: .userInitiated) {
            try timetable.searchStops(query, limit: limit)
        }.value
    }

    /// Stops within `radius` metres of `coordinate`, nearest first, with their routes: the pins
    /// shown in AR.
    func arStops(around coordinate: CLLocationCoordinate2D, radius: CLLocationDistance, limit: Int) async throws -> [ARStop] {
        let timetable = try await timetableStore.loadedTimetable()
        return try await Task.detached(priority: .userInitiated) {
            let plane = LocalTangentPlane(reference: coordinate)
            let span = plane.coordinate(at: SIMD2(radius, radius))
            let bounds = CoordinateBounds(
                minLatitude: 2 * coordinate.latitude - span.latitude, maxLatitude: span.latitude,
                minLongitude: 2 * coordinate.longitude - span.longitude, maxLongitude: span.longitude
            )
            let nearest = try timetable.stops(in: bounds, limit: 2000).stops
                .compactMap { stop -> (stop: GTFSStop, distance: Double)? in
                    guard let position = stop.coordinate else { return nil }
                    let distance = simd_length(plane.offset(of: position))
                    return distance <= radius ? (stop, distance) : nil
                }
                .sorted { $0.distance < $1.distance }
                .prefix(limit)
                .map(\.stop)
            return try timetable.withRoutes(nearest).map { ARStop(stop: $0.stop, routes: $0.routes) }
        }.value
    }

    /// A trip's stops, shape and live times, for the line screen.
    func journey(for reference: TripReference, now: Date = .now) async throws -> TripJourney {
        let timetable = try await timetableStore.loadedTimetable()
        let details = try await Task.detached(priority: .userInitiated) {
            try timetable.tripDetails(tripID: reference.tripID)
        }.value
        guard let details else { throw DepartureServiceError.unknownTrip }
        let (realtime, realtimeIssue) = await realtimeSnapshot(now: now)
        return TripJourney.make(details: details, reference: reference, realtime: realtime,
                                realtimeIssue: realtimeIssue, now: now)
    }

    private func realtimeSnapshot(now: Date) async -> (RealtimeSnapshot?, String?) {
        do {
            return (try await realtimeClient.snapshot(now: now), nil)
        } catch {
            return (nil, (error as? LocalizedError)?.errorDescription ?? "Live times are unavailable.")
        }
    }

    /// Calls per stop code, from the timetable database.
    private func calls(for stopsByCode: [String: [GTFSStop]], timetable: StaticTimetable) async throws -> [String: [StopCall]] {
        var codeByStopID: [String: String] = [:]
        for (code, stops) in stopsByCode {
            for stop in stops { codeByStopID[stop.id] = code }
        }
        let stopIDs = Set(codeByStopID.keys)
        let calls = try await Task.detached(priority: .userInitiated) {
            try timetable.calls(atStopIDs: stopIDs)
        }.value

        var grouped = Dictionary(uniqueKeysWithValues: stopsByCode.keys.map { ($0, [StopCall]()) })
        for call in calls {
            if let code = codeByStopID[call.stopID] { grouped[code, default: []].append(call) }
        }
        return grouped
    }
}

/// One upcoming bus at a nearby stop.
struct NearbyDeparture: Identifiable, Hashable, Sendable {
    let departure: Departure
    let stop: NearbyStop

    var id: String { departure.id }
}

enum NearbyDepartures {
    /// Merges boards of nearby stops into one chronological list. A bus calling at
    /// several of the stops is listed once, at the closest of them.
    static func merge(_ boards: [(stop: NearbyStop, board: StopBoard)], limit: Int = 25) -> [NearbyDeparture] {
        var best: [String: NearbyDeparture] = [:]
        for (stop, board) in boards {
            for departure in board.departures {
                if let existing = best[departure.id], existing.stop.distance <= stop.distance { continue }
                best[departure.id] = NearbyDeparture(departure: departure, stop: stop)
            }
        }
        return Array(best.values
            .sorted { ($0.departure.expected, $0.stop.distance) < ($1.departure.expected, $1.stop.distance) }
            .prefix(limit))
    }
}
