import Foundation

// Mirror of the GTFS-Realtime `FeedMessage` (TripUpdates and VehiclePositions). The app reads the NTA's
// GTFS-R API as protobuf (see GTFSRealtimeProtobuf.swift); the JSON decoding here reads the
// same feed with `?format=json`, which is easier to write by hand for tests.
//
// The decoder normalises keys (drops `_`, lowercases), so both the snake_case and
// the protobuf-JSON lowerCamelCase spellings decode. Integers and enums are
// accepted as either JSON numbers or strings.

struct GTFSRFeedMessage: Decodable, Sendable {
    let header: Header?
    let entity: [Entity]?

    struct Header: Decodable, Sendable {
        let timestamp: FlexibleInt?

        enum CodingKeys: String, CodingKey { case timestamp }
    }

    struct Entity: Decodable, Sendable {
        let id: String?
        let isDeleted: Bool?
        let tripUpdate: GTFSRTripUpdate?
        let vehicle: GTFSRVehiclePosition?

        init(id: String?, isDeleted: Bool?, tripUpdate: GTFSRTripUpdate?, vehicle: GTFSRVehiclePosition? = nil) {
            self.id = id
            self.isDeleted = isDeleted
            self.tripUpdate = tripUpdate
            self.vehicle = vehicle
        }

        enum CodingKeys: String, CodingKey {
            case id
            case isDeleted = "isdeleted"
            case tripUpdate = "tripupdate"
            case vehicle
        }
    }

    static func decode(from data: Data) throws -> GTFSRFeedMessage {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            NormalizedKey(path.last!.stringValue)
        }
        return try decoder.decode(GTFSRFeedMessage.self, from: data)
    }
}

struct GTFSRTripUpdate: Decodable, Sendable {
    let trip: TripDescriptor
    let stopTimeUpdate: [StopTimeUpdate]?
    let delay: FlexibleInt?
    let timestamp: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case trip
        case stopTimeUpdate = "stoptimeupdate"
        case delay
        case timestamp
    }

    struct TripDescriptor: Decodable, Sendable {
        let tripID: String?
        let routeID: String?
        let startTime: String?
        let startDate: String?
        let scheduleRelationship: TripRelationship?

        enum CodingKeys: String, CodingKey {
            case tripID = "tripid"
            case routeID = "routeid"
            case startTime = "starttime"
            case startDate = "startdate"
            case scheduleRelationship = "schedulerelationship"
        }
    }

    struct StopTimeUpdate: Decodable, Sendable {
        let stopSequence: FlexibleInt?
        let stopID: String?
        let arrival: StopTimeEvent?
        let departure: StopTimeEvent?
        let scheduleRelationship: StopRelationship?

        enum CodingKeys: String, CodingKey {
            case stopSequence = "stopsequence"
            case stopID = "stopid"
            case arrival
            case departure
            case scheduleRelationship = "schedulerelationship"
        }
    }

    struct StopTimeEvent: Decodable, Sendable {
        let delay: FlexibleInt?
        let time: FlexibleInt?

        enum CodingKeys: String, CodingKey { case delay, time }
    }
}

/// Where a bus is (the `Vehicles` endpoint).
struct GTFSRVehiclePosition: Decodable, Sendable {
    let trip: GTFSRTripUpdate.TripDescriptor?
    let position: Position?
    /// When the position was measured (POSIX seconds).
    let timestamp: FlexibleInt?
    let vehicle: Descriptor?

    struct Position: Decodable, Sendable, Equatable {
        let latitude: Double
        let longitude: Double
        /// Degrees clockwise from north.
        let bearing: Double?
    }

    struct Descriptor: Decodable, Sendable {
        let id: String?
        let label: String?
    }
}

enum TripRelationship: Sendable, Equatable, Decodable {
    case scheduled, added, unscheduled, canceled, replacement, duplicated, deleted, other

    init(from decoder: Decoder) throws {
        switch try FlexibleEnum(from: decoder) {
        case .number(0), .name("SCHEDULED"): self = .scheduled
        case .number(1), .name("ADDED"): self = .added
        case .number(2), .name("UNSCHEDULED"): self = .unscheduled
        case .number(3), .name("CANCELED"), .name("CANCELLED"): self = .canceled
        case .number(5), .name("REPLACEMENT"): self = .replacement
        case .number(6), .name("DUPLICATED"): self = .duplicated
        case .number(7), .name("DELETED"): self = .deleted
        default: self = .other
        }
    }
}

enum StopRelationship: Sendable, Equatable, Decodable {
    case scheduled, skipped, noData, unscheduled, other

    init(from decoder: Decoder) throws {
        switch try FlexibleEnum(from: decoder) {
        case .number(0), .name("SCHEDULED"): self = .scheduled
        case .number(1), .name("SKIPPED"): self = .skipped
        case .number(2), .name("NO_DATA"): self = .noData
        case .number(3), .name("UNSCHEDULED"): self = .unscheduled
        default: self = .other
        }
    }
}

/// An integer that may be encoded as a JSON number or a string (protobuf JSON encodes 64-bit ints as strings).
struct FlexibleInt: Decodable, Sendable, Equatable, ExpressibleByIntegerLiteral {
    let value: Int

    init(_ value: Int) { self.value = value }

    init(integerLiteral value: Int) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = Int(double)
        } else if let string = try? container.decode(String.self), let int = Int(string) {
            value = int
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an integer")
        }
    }
}

private enum FlexibleEnum: Equatable {
    case number(Int)
    case name(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .number(int)
        } else {
            self = .name(try container.decode(String.self).uppercased())
        }
    }
}

private struct NormalizedKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string.replacingOccurrences(of: "_", with: "").lowercased()
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
