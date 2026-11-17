import Foundation

/// An indexed TripUpdates feed.
struct RealtimeSnapshot: Sendable {
    let feedTimestamp: Date?
    let fetchedAt: Date
    private let updatesByTripID: [String: [GTFSRTripUpdate]]
    /// Trips that are not in the static schedule (`ADDED`).
    let addedTrips: [GTFSRTripUpdate]

    init(feed: GTFSRFeedMessage, fetchedAt: Date = .now) {
        self.fetchedAt = fetchedAt
        feedTimestamp = feed.header?.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }

        var byTrip: [String: [GTFSRTripUpdate]] = [:]
        var added: [GTFSRTripUpdate] = []
        for entity in feed.entity ?? [] where entity.isDeleted != true {
            guard let update = entity.tripUpdate else { continue }
            if update.trip.scheduleRelationship == .added {
                added.append(update)
            } else if let tripID = update.trip.tripID {
                byTrip[tripID, default: []].append(update)
            }
        }
        updatesByTripID = byTrip
        addedTrips = added
    }

    /// The update for a scheduled trip on a given service day. Updates without a
    /// `start_date` match any day.
    func update(forTripID tripID: String, serviceDate: GTFSDate) -> GTFSRTripUpdate? {
        guard let updates = updatesByTripID[tripID] else { return nil }
        return updates.first { update in
            guard let raw = update.trip.startDate, let date = GTFSDate(string: raw) else { return true }
            return date == serviceDate
        }
    }

    var tripCount: Int { updatesByTripID.count + addedTrips.count }
}

/// One bus's last reported position.
struct VehiclePosition: Identifiable, Sendable, Equatable {
    let tripID: String
    let latitude: Double
    let longitude: Double
    /// Degrees clockwise from north.
    let bearing: Double?
    /// When the position was measured.
    let timestamp: Date?
    let vehicleID: String?

    var id: String { tripID + "/" + (vehicleID ?? "") }
}

/// An indexed VehiclePositions feed.
struct VehicleSnapshot: Sendable {
    let feedTimestamp: Date?
    let fetchedAt: Date
    private let positionsByTripID: [String: [(startDate: GTFSDate?, position: VehiclePosition)]]

    init(feed: GTFSRFeedMessage, fetchedAt: Date = .now) {
        self.fetchedAt = fetchedAt
        feedTimestamp = feed.header?.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0.value)) }

        var byTrip: [String: [(startDate: GTFSDate?, position: VehiclePosition)]] = [:]
        for entity in feed.entity ?? [] where entity.isDeleted != true {
            guard let vehicle = entity.vehicle, let tripID = vehicle.trip?.tripID, let position = vehicle.position,
                  position.latitude != 0 || position.longitude != 0 else { continue }
            byTrip[tripID, default: []].append((
                startDate: vehicle.trip?.startDate.flatMap(GTFSDate.init(string:)),
                position: VehiclePosition(
                    tripID: tripID,
                    latitude: position.latitude,
                    longitude: position.longitude,
                    bearing: position.bearing,
                    timestamp: vehicle.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0.value)) },
                    vehicleID: vehicle.vehicle?.id
                )
            ))
        }
        positionsByTripID = byTrip
    }

    /// The bus running a scheduled trip on a given service day. Positions without a
    /// `start_date` match any day.
    func position(forTripID tripID: String, serviceDate: GTFSDate) -> VehiclePosition? {
        positionsByTripID[tripID]?.first { $0.startDate == nil || $0.startDate == serviceDate }?.position
    }

    /// Every bus running one of `tripIDs`, on any day.
    func positions(forTripIDs tripIDs: Set<String>) -> [VehiclePosition] {
        tripIDs.flatMap { positionsByTripID[$0]?.map(\.position) ?? [] }
    }

    var vehicleCount: Int { positionsByTripID.values.reduce(0) { $0 + $1.count } }
}

enum RealtimeError: LocalizedError, Equatable {
    case missingAPIKey
    case unauthorized
    case rateLimited
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your NTA API key in Settings for live times."
        case .unauthorized: "The NTA API key was rejected."
        case .rateLimited: "The NTA API rate limit was reached."
        case .httpStatus(let code): "The NTA API returned HTTP \(code)."
        }
    }
}

/// Fetches the NTA GTFS-Realtime feeds (Dublin Bus, Go-Ahead, Bus Éireann…): TripUpdates for
/// live times, and VehiclePositions for where the buses are.
///
/// Each feed covers the whole network, so a single cached copy is shared by every stop and
/// refetched at most once per `minimumInterval` to respect the NTA's fair-usage policy. They're
/// fetched as protobuf, about a sixth of the size of the JSON. Vehicle positions are only
/// fetched while a line is on screen.
actor RealtimeClient {
    static let endpoint = URL(string: "https://api.nationaltransport.ie/gtfsr/v2/TripUpdates?format=protobuf")!
    static let vehiclesEndpoint = URL(string: "https://api.nationaltransport.ie/gtfsr/v2/Vehicles?format=protobuf")!

    /// A feed older than this is no longer shown as live.
    static let maximumAge: TimeInterval = 5 * 60

    private let tripUpdateFeed: RealtimeFeed<RealtimeSnapshot>
    private let vehicleFeed: RealtimeFeed<VehicleSnapshot>

    init(session: URLSession = .shared, minimumInterval: TimeInterval = 60, apiKey: @escaping @Sendable () -> String?) {
        tripUpdateFeed = RealtimeFeed(endpoint: Self.endpoint, session: session, minimumInterval: minimumInterval,
                                      maximumAge: Self.maximumAge, apiKey: apiKey) { data, now in
            RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(protobuf: data), fetchedAt: now)
        }
        vehicleFeed = RealtimeFeed(endpoint: Self.vehiclesEndpoint, session: session, minimumInterval: minimumInterval,
                                   maximumAge: Self.maximumAge, apiKey: apiKey) { data, now in
            VehicleSnapshot(feed: try GTFSRFeedMessage.decode(protobuf: data), fetchedAt: now)
        }
    }

    /// Live times: a snapshot no older than `minimumInterval`, fetching if needed.
    /// If a refetch fails, the previous snapshot is returned while it is younger than `maximumAge`.
    func snapshot(now: Date = .now) async throws -> RealtimeSnapshot {
        try await tripUpdateFeed.snapshot(now: now)
    }

    /// Bus positions, cached like `snapshot(now:)`.
    func vehicles(now: Date = .now) async throws -> VehicleSnapshot {
        try await vehicleFeed.snapshot(now: now)
    }

    /// Forgets cached data and errors, e.g. after the API key changes.
    func reset() async {
        await tripUpdateFeed.reset()
        await vehicleFeed.reset()
    }
}

/// One GTFS-R endpoint, fetched at most once per `minimumInterval` and cached.
actor RealtimeFeed<Snapshot: Sendable> {
    private let endpoint: URL
    private let session: URLSession
    private let minimumInterval: TimeInterval
    private let maximumAge: TimeInterval
    private let apiKey: @Sendable () -> String?
    private let decode: @Sendable (Data, Date) throws -> Snapshot
    private var cached: (snapshot: Snapshot, fetchedAt: Date)?
    private var lastAttempt: Date?
    private var lastError: Error?
    private var inFlight: Task<Snapshot, Error>?

    init(endpoint: URL, session: URLSession, minimumInterval: TimeInterval, maximumAge: TimeInterval,
         apiKey: @escaping @Sendable () -> String?, decode: @escaping @Sendable (Data, Date) throws -> Snapshot) {
        self.endpoint = endpoint
        self.session = session
        self.minimumInterval = minimumInterval
        self.maximumAge = maximumAge
        self.apiKey = apiKey
        self.decode = decode
    }

    func snapshot(now: Date) async throws -> Snapshot {
        if let inFlight { return try await inFlight.value }

        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval {
            if let cached = usableCache(at: now) { return cached }
            if let lastError { throw lastError }
        }

        guard let key = apiKey(), !key.isEmpty else {
            throw RealtimeError.missingAPIKey
        }

        lastAttempt = now
        let (endpoint, session, decode) = (self.endpoint, self.session, self.decode)
        let task = Task { try await Self.fetch(endpoint, session: session, apiKey: key, now: now, decode: decode) }
        inFlight = task
        defer { inFlight = nil }

        do {
            let snapshot = try await task.value
            cached = (snapshot, now)
            lastError = nil
            return snapshot
        } catch {
            lastError = error
            // A stale feed is still better than none for a few minutes.
            if let cached = usableCache(at: now) { return cached }
            throw error
        }
    }

    private func usableCache(at now: Date) -> Snapshot? {
        guard let cached, now.timeIntervalSince(cached.fetchedAt) < maximumAge else { return nil }
        return cached.snapshot
    }

    func reset() {
        cached = nil
        lastAttempt = nil
        lastError = nil
    }

    private static func fetch(_ endpoint: URL, session: URLSession, apiKey: String, now: Date,
                              decode: @escaping @Sendable (Data, Date) throws -> Snapshot) async throws -> Snapshot {
        var request = URLRequest(url: endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw RealtimeError.unauthorized
            case 429: throw RealtimeError.rateLimited
            default: throw RealtimeError.httpStatus(http.statusCode)
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            try decode(data, now)
        }.value
    }
}
