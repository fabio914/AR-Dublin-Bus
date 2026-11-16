import Foundation
import Testing
@testable import ARDublinBus

/// Builds protobuf messages for fixtures.
struct ProtobufWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: Int) {
        key(field, wireType: 0)
        append(UInt64(bitPattern: Int64(value)))
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtobufWriter) -> Void) {
        var nested = ProtobufWriter()
        build(&nested)
        bytes(field, nested.data)
    }

    mutating func fixed32(_ field: Int, _ value: UInt32) {
        key(field, wireType: 5)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wireType: 2)
        append(UInt64(value.count))
        data.append(value)
    }

    private mutating func key(_ field: Int, wireType: Int) {
        append(UInt64(field << 3 | wireType))
    }

    private mutating func append(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    static func build(_ build: (inout ProtobufWriter) -> Void) -> Data {
        var writer = ProtobufWriter()
        build(&writer)
        return writer.data
    }
}

struct RealtimeProtobufTests {
    /// The same feed as `RealtimeDecodingTests.snakeCaseFeed`, plus fields the app ignores.
    static let feed = ProtobufWriter.build { feed in
        feed.message(1) { header in
            header.string(1, "2.0")
            header.varint(2, 0) // FULL_DATASET
            header.varint(3, 1_763_280_000)
        }
        feed.message(2) { entity in
            entity.string(1, "T1")
            entity.message(3) { update in
                update.message(1) { trip in
                    trip.string(1, "T1")
                    trip.string(2, "07:50:00")
                    trip.string(3, "20261116")
                    trip.varint(4, 0) // SCHEDULED
                    trip.string(5, "r27")
                    trip.varint(6, 0) // direction_id: ignored
                }
                update.message(3) { vehicle in vehicle.string(1, "bus 42") } // ignored
                update.message(2) { stop in
                    stop.varint(1, 5)
                    stop.string(4, "X")
                    stop.message(2) { arrival in arrival.varint(1, 120) }
                    stop.message(3) { departure in
                        departure.varint(1, 150)
                        departure.varint(3, 30) // uncertainty: ignored
                    }
                    stop.varint(5, 0)
                }
                update.message(2) { stop in
                    stop.varint(1, 6)
                    stop.message(2) { arrival in arrival.varint(1, -45) } // early
                }
                update.varint(4, 1_763_280_000)
                update.fixed32(99, 7) // an unknown extension: skipped
            }
        }
        feed.message(2) { entity in
            entity.string(1, "T4")
            entity.message(3) { update in
                update.message(1) { trip in
                    trip.string(1, "T4")
                    trip.varint(4, 3) // CANCELED
                }
            }
        }
        feed.message(2) { entity in
            entity.string(1, "A1")
            entity.message(3) { update in
                update.message(1) { trip in
                    trip.string(1, "A1")
                    trip.string(5, "r11")
                    trip.varint(4, 1) // ADDED
                }
                update.message(2) { stop in
                    stop.string(4, "8220DB000271")
                    stop.message(2) { arrival in arrival.varint(2, 1_763_280_900) }
                }
            }
        }
        feed.message(2) { entity in
            entity.string(1, "gone")
            entity.varint(2, 1)
            entity.message(3) { update in update.message(1) { trip in trip.string(1, "GONE") } }
        }
        feed.message(2) { entity in
            entity.string(1, "V1")
            entity.message(4) { vehicle in vehicle.string(1, "a vehicle position") } // ignored
        }
    }

    @Test func decodesTripUpdates() throws {
        let feed = try GTFSRFeedMessage.decode(protobuf: Self.feed)
        #expect(feed.header?.timestamp?.value == 1_763_280_000)
        #expect(feed.entity?.map(\.id) == ["T1", "T4", "A1", "gone", "V1"])

        let update = try #require(feed.entity?.first?.tripUpdate)
        #expect(update.trip.tripID == "T1")
        #expect(update.trip.routeID == "r27")
        #expect(update.trip.startTime == "07:50:00")
        #expect(update.trip.startDate == "20261116")
        #expect(update.trip.scheduleRelationship == .scheduled)
        #expect(update.timestamp?.value == 1_763_280_000)

        let stops = try #require(update.stopTimeUpdate)
        #expect(stops.count == 2)
        #expect(stops[0].stopSequence?.value == 5)
        #expect(stops[0].stopID == "X")
        #expect(stops[0].arrival?.delay?.value == 120)
        #expect(stops[0].departure?.delay?.value == 150)
        #expect(stops[0].scheduleRelationship == .scheduled)
        #expect(stops[1].arrival?.delay?.value == -45)

        #expect(feed.entity?[1].tripUpdate?.trip.scheduleRelationship == .canceled)
        #expect(feed.entity?[2].tripUpdate?.stopTimeUpdate?.first?.arrival?.time?.value == 1_763_280_900)
        #expect(feed.entity?[3].isDeleted == true)
        #expect(feed.entity?[4].tripUpdate == nil)
    }

    @Test func snapshotMatchesTheJSONFeed() throws {
        let fromProtobuf = RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(protobuf: Self.feed))
        let fromJSON = RealtimeSnapshot(feed: try GTFSRFeedMessage.decode(from: Data(RealtimeDecodingTests.snakeCaseFeed.utf8)))
        let monday = GTFSDate(year: 2026, month: 11, day: 16)

        #expect(fromProtobuf.feedTimestamp == fromJSON.feedTimestamp)
        #expect(fromProtobuf.tripCount == fromJSON.tripCount)
        #expect(fromProtobuf.addedTrips.map(\.trip.tripID) == ["A1"])
        for tripID in ["T1", "T4", "GONE"] {
            #expect((fromProtobuf.update(forTripID: tripID, serviceDate: monday) != nil)
                    == (fromJSON.update(forTripID: tripID, serviceDate: monday) != nil))
        }
    }

    @Test func emptyFeedDecodes() throws {
        let feed = try GTFSRFeedMessage.decode(protobuf: Data())
        #expect(feed.header == nil)
        #expect(feed.entity?.isEmpty == true)
    }

    @Test func rejectsTruncatedData() {
        #expect(throws: ProtobufError.truncated) {
            try GTFSRFeedMessage.decode(protobuf: Self.feed.dropLast(3))
        }
    }

    @Test func rejectsGroups() {
        // Field 1 with wire type 3 (start group), which proto3 feeds never use.
        #expect(throws: ProtobufError.unsupportedWireType(3)) {
            try GTFSRFeedMessage.decode(protobuf: Data([0x0b]))
        }
    }
}
