import Foundation

// Messages exchanged between the watch app and the iPhone app over WatchConnectivity.
// The watch sends its location; the phone, which holds the timetable and the
// realtime feed, replies with the boards of the stops around it.

struct WatchNearbyRequest: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    /// Maximum number of stops to return.
    var stopLimit: Int = 8
}

struct WatchNearbyResponse: Codable, Equatable {
    struct Stop: Codable, Equatable, Identifiable {
        let code: String
        let name: String
        /// Metres from the requested location.
        let distance: Double
        let departures: [Departure]

        var id: String { code }
    }

    struct Departure: Codable, Equatable, Identifiable {
        let id: String
        let route: String
        let destination: String
        let expected: Date
        let isRealtime: Bool
        let isCancelled: Bool

        /// "Due", "7 min", or a clock time an hour or more away.
        func eta(from now: Date) -> String {
            let minutes = max(0, Int(expected.timeIntervalSince(now) / 60))
            if minutes == 0 { return "Due" }
            if minutes < 60 { return "\(minutes) min" }
            return expected.formatted(Self.clockFormat)
        }

        static let clockFormat = Date.FormatStyle(
            date: .omitted,
            time: .shortened,
            timeZone: TimeZone(identifier: "Europe/Dublin")!
        )
    }

    var stops: [Stop]
    /// Why live times are missing, if they are.
    var realtimeIssue: String?
    var generatedAt: Date
    /// Set instead of `stops` when the phone couldn't answer.
    var error: String?

    static func failure(_ message: String, at date: Date = .now) -> WatchNearbyResponse {
        WatchNearbyResponse(stops: [], realtimeIssue: nil, generatedAt: date, error: message)
    }
}

enum WatchMessageCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
