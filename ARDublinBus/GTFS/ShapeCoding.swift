import CoreLocation
import Foundation

/// Compact binary encodings used in the timetable database.
///
/// Integers are stored as zigzag varints (small numbers, positive or negative, take one
/// or two bytes). Coordinates are rounded to 1e-5 degrees (about 1 m) and stored as
/// differences from the previous point, which are small along a bus route.
enum ShapeCoding {
    static let scale = 1e5

    static func encode(_ points: [CLLocationCoordinate2D]) -> Data {
        var data = Data()
        data.reserveCapacity(points.count * 4)
        var previousLatitude = 0, previousLongitude = 0
        for point in points {
            let latitude = Int((point.latitude * scale).rounded())
            let longitude = Int((point.longitude * scale).rounded())
            appendVarint(zigzag(latitude - previousLatitude), to: &data)
            appendVarint(zigzag(longitude - previousLongitude), to: &data)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return data
    }

    static func decode(_ data: Data) -> [CLLocationCoordinate2D] {
        let values = decodeIntegers(data)
        var points: [CLLocationCoordinate2D] = []
        points.reserveCapacity(values.count / 2)
        var latitude = 0, longitude = 0
        var index = 0
        while index + 1 < values.count {
            latitude += values[index]
            longitude += values[index + 1]
            points.append(CLLocationCoordinate2D(latitude: Double(latitude) / scale, longitude: Double(longitude) / scale))
            index += 2
        }
        return points
    }

    /// A list of signed integers as zigzag varints.
    static func encodeIntegers(_ values: [Int]) -> Data {
        var data = Data()
        data.reserveCapacity(values.count * 2)
        for value in values { appendVarint(zigzag(value), to: &data) }
        return data
    }

    static func decodeIntegers(_ data: Data) -> [Int] {
        var values: [Int] = []
        values.reserveCapacity(data.count)
        var current: UInt64 = 0
        var shift: UInt64 = 0
        for byte in data {
            current |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                values.append(Int(bitPattern: UInt(current >> 1)) ^ -Int(current & 1))
                current = 0
                shift = 0
            } else {
                shift += 7
                if shift > 63 { return values } // corrupt data
            }
        }
        return values
    }

    private static func zigzag(_ value: Int) -> UInt64 {
        UInt64(bitPattern: Int64((value << 1) ^ (value >> 63)))
    }

    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }
}
