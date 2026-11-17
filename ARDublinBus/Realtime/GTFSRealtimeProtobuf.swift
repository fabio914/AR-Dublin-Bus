import Foundation

// Reads the GTFS-Realtime `FeedMessage` from protobuf, as served by the NTA's GTFS-R API by
// default (about a sixth of the size of `?format=json`). Only the TripUpdates and
// VehiclePositions fields the app uses are read; everything else, such as alerts and
// extensions, is skipped.
//
// Field numbers are from gtfs-realtime.proto:
// https://gtfs.org/documentation/realtime/proto/

extension GTFSRFeedMessage {
    static func decode(protobuf data: Data) throws -> GTFSRFeedMessage {
        var reader = ProtobufReader(bytes: [UInt8](data))
        var header: Header?
        var entities: [Entity] = []
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): header = try Header(protobuf: reader.message())
            case (2, .lengthDelimited): entities.append(try Entity(protobuf: reader.message()))
            default: try reader.skip(field.wireType)
            }
        }
        return GTFSRFeedMessage(header: header, entity: entities)
    }
}

extension GTFSRFeedMessage.Header {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var timestamp: FlexibleInt?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (3, .varint): timestamp = FlexibleInt(try reader.uint64())
            default: try reader.skip(field.wireType)
            }
        }
        self.init(timestamp: timestamp)
    }
}

extension GTFSRFeedMessage.Entity {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var id: String?
        var isDeleted: Bool?
        var tripUpdate: GTFSRTripUpdate?
        var vehicle: GTFSRVehiclePosition?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): id = try reader.string()
            case (2, .varint): isDeleted = try reader.varint() != 0
            case (3, .lengthDelimited): tripUpdate = try GTFSRTripUpdate(protobuf: reader.message())
            case (4, .lengthDelimited): vehicle = try GTFSRVehiclePosition(protobuf: reader.message())
            default: try reader.skip(field.wireType)
            }
        }
        self.init(id: id, isDeleted: isDeleted, tripUpdate: tripUpdate, vehicle: vehicle)
    }
}

extension GTFSRVehiclePosition {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var trip: GTFSRTripUpdate.TripDescriptor?
        var position: Position?
        var timestamp: FlexibleInt?
        var vehicle: Descriptor?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): trip = try GTFSRTripUpdate.TripDescriptor(protobuf: reader.message())
            case (2, .lengthDelimited): position = try Position(protobuf: reader.message())
            case (5, .varint): timestamp = FlexibleInt(try reader.uint64())
            case (8, .lengthDelimited): vehicle = try Descriptor(protobuf: reader.message())
            default: try reader.skip(field.wireType)
            }
        }
        self.init(trip: trip, position: position, timestamp: timestamp, vehicle: vehicle)
    }
}

extension GTFSRVehiclePosition.Position {
    /// `nil` without a latitude and longitude (both are required by the spec).
    init?(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var latitude, longitude, bearing: Double?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .fixed32): latitude = Double(try reader.float())
            case (2, .fixed32): longitude = Double(try reader.float())
            case (3, .fixed32): bearing = Double(try reader.float())
            default: try reader.skip(field.wireType)
            }
        }
        guard let latitude, let longitude else { return nil }
        self.init(latitude: latitude, longitude: longitude, bearing: bearing)
    }
}

extension GTFSRVehiclePosition.Descriptor {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var id, label: String?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): id = try reader.string()
            case (2, .lengthDelimited): label = try reader.string()
            default: try reader.skip(field.wireType)
            }
        }
        self.init(id: id, label: label)
    }
}

extension GTFSRTripUpdate {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var trip: TripDescriptor?
        var stopTimeUpdates: [StopTimeUpdate] = []
        var timestamp: FlexibleInt?
        var delay: FlexibleInt?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): trip = try TripDescriptor(protobuf: reader.message())
            case (2, .lengthDelimited): stopTimeUpdates.append(try StopTimeUpdate(protobuf: reader.message()))
            case (4, .varint): timestamp = FlexibleInt(try reader.uint64())
            case (5, .varint): delay = FlexibleInt(try reader.int32())
            default: try reader.skip(field.wireType)
            }
        }
        // `trip` is required by the spec; an update without one matches nothing.
        self.init(
            trip: trip ?? TripDescriptor(tripID: nil, routeID: nil, startTime: nil, startDate: nil, scheduleRelationship: nil),
            stopTimeUpdate: stopTimeUpdates.isEmpty ? nil : stopTimeUpdates,
            delay: delay,
            timestamp: timestamp
        )
    }
}

extension GTFSRTripUpdate.TripDescriptor {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var tripID, routeID, startTime, startDate: String?
        var relationship: TripRelationship?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .lengthDelimited): tripID = try reader.string()
            case (2, .lengthDelimited): startTime = try reader.string()
            case (3, .lengthDelimited): startDate = try reader.string()
            case (4, .varint): relationship = TripRelationship(number: try reader.int32())
            case (5, .lengthDelimited): routeID = try reader.string()
            default: try reader.skip(field.wireType)
            }
        }
        self.init(tripID: tripID, routeID: routeID, startTime: startTime, startDate: startDate, scheduleRelationship: relationship)
    }
}

extension GTFSRTripUpdate.StopTimeUpdate {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var stopSequence: FlexibleInt?
        var stopID: String?
        var arrival, departure: GTFSRTripUpdate.StopTimeEvent?
        var relationship: StopRelationship?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint): stopSequence = FlexibleInt(try reader.uint64())
            case (2, .lengthDelimited): arrival = try GTFSRTripUpdate.StopTimeEvent(protobuf: reader.message())
            case (3, .lengthDelimited): departure = try GTFSRTripUpdate.StopTimeEvent(protobuf: reader.message())
            case (4, .lengthDelimited): stopID = try reader.string()
            case (5, .varint): relationship = StopRelationship(number: try reader.int32())
            default: try reader.skip(field.wireType)
            }
        }
        self.init(stopSequence: stopSequence, stopID: stopID, arrival: arrival, departure: departure, scheduleRelationship: relationship)
    }
}

extension GTFSRTripUpdate.StopTimeEvent {
    init(protobuf reader: ProtobufReader) throws {
        var reader = reader
        var delay, time: FlexibleInt?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, .varint): delay = FlexibleInt(try reader.int32())
            case (2, .varint): time = FlexibleInt(try reader.int64())
            default: try reader.skip(field.wireType)
            }
        }
        self.init(delay: delay, time: time)
    }
}

extension TripRelationship {
    init(number: Int) {
        self = switch number {
        case 0: .scheduled
        case 1: .added
        case 2: .unscheduled
        case 3: .canceled
        case 5: .replacement
        case 6: .duplicated
        case 7: .deleted
        default: .other
        }
    }
}

extension StopRelationship {
    init(number: Int) {
        self = switch number {
        case 0: .scheduled
        case 1: .skipped
        case 2: .noData
        case 3: .unscheduled
        default: .other
        }
    }
}

// MARK: - Wire format

enum ProtobufError: Error, Equatable {
    case truncated
    case malformedVarint
    case unsupportedWireType(Int)
}

/// Reads protobuf wire-format fields one at a time. Nested messages share the same bytes.
struct ProtobufReader {
    enum WireType: Equatable {
        case varint, fixed64, lengthDelimited, fixed32
    }

    private let bytes: [UInt8]
    private var index: Int
    private let end: Int

    init(bytes: [UInt8]) {
        self.init(bytes: bytes, range: 0..<bytes.count)
    }

    private init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        index = range.lowerBound
        end = range.upperBound
    }

    /// The next field's number and wire type, or `nil` at the end of the message.
    mutating func nextField() throws -> (number: Int, wireType: WireType)? {
        guard index < end else { return nil }
        let key = try varint()
        let wireType: WireType = switch key & 7 {
        case 0: .varint
        case 1: .fixed64
        case 2: .lengthDelimited
        case 5: .fixed32
        default: throw ProtobufError.unsupportedWireType(Int(key & 7)) // groups are deprecated
        }
        return (Int(key >> 3), wireType)
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard index < end else { throw ProtobufError.truncated }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { throw ProtobufError.malformedVarint }
        }
    }

    mutating func uint64() throws -> Int { Int(truncatingIfNeeded: try varint()) }

    /// Negative `int32`/`int64` values are sent as 10-byte two's complement varints.
    mutating func int64() throws -> Int { Int(Int64(bitPattern: try varint())) }

    mutating func int32() throws -> Int { Int(Int32(truncatingIfNeeded: try varint())) }

    /// A `float` field (wire type `fixed32`, little-endian IEEE 754).
    mutating func float() throws -> Float {
        guard end - index >= 4 else { throw ProtobufError.truncated }
        var bits: UInt32 = 0
        for offset in 0..<4 { bits |= UInt32(bytes[index + offset]) << (8 * offset) }
        index += 4
        return Float(bitPattern: bits)
    }

    mutating func string() throws -> String {
        String(decoding: bytes[try lengthDelimitedRange()], as: UTF8.self)
    }

    /// A reader for the embedded message in the current field.
    mutating func message() throws -> ProtobufReader {
        ProtobufReader(bytes: bytes, range: try lengthDelimitedRange())
    }

    mutating func skip(_ wireType: WireType) throws {
        switch wireType {
        case .varint: _ = try varint()
        case .fixed64: try advance(by: 8)
        case .fixed32: try advance(by: 4)
        case .lengthDelimited: _ = try lengthDelimitedRange()
        }
    }

    private mutating func lengthDelimitedRange() throws -> Range<Int> {
        let length = try varint()
        guard length <= UInt64(end - index) else { throw ProtobufError.truncated }
        let start = index
        index += Int(length)
        return start..<index
    }

    private mutating func advance(by count: Int) throws {
        guard end - index >= count else { throw ProtobufError.truncated }
        index += count
    }
}
