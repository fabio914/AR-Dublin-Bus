import CoreLocation
import Foundation
import Testing
@testable import ARDublinBus

struct ShapeCodingTests {
    @Test func coordinatesRoundTripToAboutOneMetre() {
        let points = [
            CLLocationCoordinate2D(latitude: 53.348596, longitude: -6.259485),
            CLLocationCoordinate2D(latitude: 53.3486, longitude: -6.2594),
            CLLocationCoordinate2D(latitude: 53.2707, longitude: -9.0568),
            CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093),
        ]
        let decoded = ShapeCoding.decode(ShapeCoding.encode(points))
        #expect(decoded.count == points.count)
        for (original, copy) in zip(points, decoded) {
            // Rounded to 1e-5 degrees: at most half a unit off (plus floating-point noise).
            #expect(abs(original.latitude - copy.latitude) <= 0.51e-5)
            #expect(abs(original.longitude - copy.longitude) <= 0.51e-5)
        }
    }

    @Test func nearbyPointsTakeFewBytes() {
        let points = (0..<100).map { CLLocationCoordinate2D(latitude: 53.35 + Double($0) * 0.0001, longitude: -6.26 - Double($0) * 0.0001) }
        // The first point is large; each following step (10 units) fits in one byte per axis.
        #expect(ShapeCoding.encode(points).count < 210)
    }

    @Test func integersRoundTrip() {
        let values = [0, 1, -1, 63, -64, 64, 1_000_000, -1_000_000, Int(Int32.max), Int(Int32.min), 86_400 * 2]
        #expect(ShapeCoding.decodeIntegers(ShapeCoding.encodeIntegers(values)) == values)
        #expect(ShapeCoding.decode(Data()).isEmpty)
    }
}

struct CSVByteReaderTests {
    private func parse<T>(_ text: String, _ parser: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        Array(text.utf8).withUnsafeBufferPointer(parser)
    }

    @Test func parsesTimes() {
        #expect(parse("08:10:00", CSVByteReader.parseTime) == 8 * 3600 + 600)
        #expect(parse("8:05:09", CSVByteReader.parseTime) == 8 * 3600 + 309)
        #expect(parse("25:35:00", CSVByteReader.parseTime) == 25 * 3600 + 2100)
        #expect(parse("", CSVByteReader.parseTime) == nil)
        #expect(parse("08:10", CSVByteReader.parseTime) == nil)
        #expect(parse("8h10:00", CSVByteReader.parseTime) == nil)
    }

    @Test func parsesNumbers() {
        #expect(parse("42", CSVByteReader.parseInt) == 42)
        #expect(parse("-7", CSVByteReader.parseInt) == -7)
        #expect(parse("4a", CSVByteReader.parseInt) == nil)
        #expect(parse("53.3911812567086", CSVByteReader.parseDouble).map { abs($0 - 53.3911812567086) < 1e-12 } == true)
        #expect(parse("-6.26218732212012", CSVByteReader.parseDouble).map { abs($0 - -6.26218732212012) < 1e-12 } == true)
        #expect(parse("12", CSVByteReader.parseDouble) == 12)
        #expect(parse("1.2.3", CSVByteReader.parseDouble) == nil)
        #expect(parse("1e5", CSVByteReader.parseDouble) == nil)
    }

    @Test func readsRequestedColumnsInAnyOrder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("csv-\(UUID().uuidString).txt")
        try "\u{FEFF}a,b,c\r\n1, x ,3\r\n\"4,5\",\"y\"\"z\",6\r\n\r\n7,w,9".write(to: url, atomically: true, encoding: .utf8)
        var rows: [[String]] = []
        try CSVByteReader.forEachRow(in: url, columns: ["c", "b", "a"]) { row in
            rows.append([row.string(0), row.string(1), row.string(2)])
        }
        #expect(rows == [["3", "x", "1"], ["6", "y\"z", "4,5"], ["9", "w", "7"]])

        #expect(throws: TimetableError.self) {
            try CSVByteReader.forEachRow(in: url, columns: ["missing"]) { _ in }
        }
    }
}
