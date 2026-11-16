import SwiftUI

/// Transport for Ireland's colours, as used on stop flags and in both apps.
enum TFIColors {
    static let green = Color(red: 0 / 255, green: 102 / 255, blue: 84 / 255)
    static let darkGreen = Color(red: 0 / 255, green: 74 / 255, blue: 61 / 255)
    static let yellow = Color(red: 255 / 255, green: 210 / 255, blue: 0 / 255)
    /// Marks live times on a white card.
    static let live = Color(red: 0 / 255, green: 150 / 255, blue: 95 / 255)
    /// Marks live times on a dark background (the watch).
    static let liveOnDark = Color(red: 60 / 255, green: 210 / 255, blue: 140 / 255)
    static let ink = Color(red: 0.11, green: 0.12, blue: 0.13)
    static let secondaryInk = Color(red: 0.38, green: 0.4, blue: 0.42)
    static let separator = Color(red: 0.88, green: 0.89, blue: 0.9)
}

/// How times are written on boards.
enum ETAText {
    /// Clock times are always Dublin's, wherever the device is.
    static let clockFormat = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: TimeZone(identifier: "Europe/Dublin")!)

    /// Whole minutes until `expected`, never negative.
    static func minutes(until expected: Date, from now: Date) -> Int {
        max(0, Int(expected.timeIntervalSince(now) / 60))
    }

    /// "Due", "7 min", or a clock time when an hour or more away.
    static func relative(expected: Date, now: Date) -> String {
        let minutes = minutes(until: expected, from: now)
        if minutes == 0 { return "Due" }
        if minutes < 60 { return "\(minutes) min" }
        return clock(expected)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(clockFormat)
    }
}

enum DistanceText {
    /// A walking distance, such as "240 m".
    static func walking(_ metres: Double) -> String {
        Measurement(value: metres, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
