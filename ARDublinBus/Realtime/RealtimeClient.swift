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

/// Fetches the NTA GTFS-Realtime TripUpdates feed (Dublin Bus, Go-Ahead, Bus Éireann…).
///
/// The feed covers the whole network, so a single cached copy is shared by every
/// stop and refetched at most once per `minimumInterval` to respect the NTA's
/// fair-usage policy.
actor RealtimeClient {
    static let endpoint = URL(string: "https://api.nationaltransport.ie/gtfsr/v2/TripUpdates?format=json")!

    private let session: URLSession
    private let apiKey: @Sendable () -> String?
    private let minimumInterval: TimeInterval
    /// A feed older than this is no longer shown as live.
    static let maximumAge: TimeInterval = 5 * 60
    private var cached: RealtimeSnapshot?
    private var lastAttempt: Date?
    private var lastError: Error?
    private var inFlight: Task<RealtimeSnapshot, Error>?

    init(session: URLSession = .shared, minimumInterval: TimeInterval = 60, apiKey: @escaping @Sendable () -> String?) {
        self.session = session
        self.minimumInterval = minimumInterval
        self.apiKey = apiKey
    }

    /// Returns a snapshot no older than `minimumInterval`, fetching if needed.
    /// If a refetch fails, the previous snapshot is returned while it is younger than `maximumAge`.
    func snapshot(now: Date = .now) async throws -> RealtimeSnapshot {
        if let inFlight { return try await inFlight.value }

        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval {
            if let cached = usableCache(at: now) { return cached }
            if let lastError { throw lastError }
        }

        guard let key = apiKey(), !key.isEmpty else {
            throw RealtimeError.missingAPIKey
        }

        lastAttempt = now
        let session = self.session
        let task = Task { try await Self.fetch(session: session, apiKey: key, now: now) }
        inFlight = task
        defer { inFlight = nil }

        do {
            let snapshot = try await task.value
            cached = snapshot
            lastError = nil
            return snapshot
        } catch {
            lastError = error
            // A stale feed is still better than none for a few minutes.
            if let cached = usableCache(at: now) { return cached }
            throw error
        }
    }

    private func usableCache(at now: Date) -> RealtimeSnapshot? {
        guard let cached, now.timeIntervalSince(cached.fetchedAt) < Self.maximumAge else { return nil }
        return cached
    }

    /// Forgets cached data and errors, e.g. after the API key changes.
    func reset() {
        cached = nil
        lastAttempt = nil
        lastError = nil
    }

    private static func fetch(session: URLSession, apiKey: String, now: Date) async throws -> RealtimeSnapshot {
        var request = URLRequest(url: endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(from: data), fetchedAt: now)
        }.value
    }
}
