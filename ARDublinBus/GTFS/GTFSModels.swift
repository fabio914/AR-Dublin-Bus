import CoreLocation
import Foundation

/// The time zone every Dublin Bus timetable is expressed in.
enum Dublin {
    static let timeZone = TimeZone(identifier: "Europe/Dublin")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

struct GTFSStop: Hashable, Sendable {
    let id: String
    let code: String
    let name: String
    let latitude: Double?
    let longitude: Double?
}

extension GTFSStop {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A stop (all GTFS stops sharing one stop code) and its distance from the user.
struct NearbyStop: Hashable, Sendable, Identifiable {
    let stop: GTFSStop
    let stopIDs: Set<String>
    /// Metres.
    let distance: Double

    var id: String { stop.code }
}

struct GTFSRoute: Hashable, Sendable {
    let id: String
    let shortName: String
    let longName: String
}

struct GTFSTrip: Hashable, Sendable {
    let id: String
    let routeID: String
    let serviceID: String
    let headsign: String
}

/// One scheduled visit of a trip to a stop (a row of `stop_times.txt`), with the trip's details.
struct StopCall: Hashable, Sendable {
    let tripID: String
    let stopID: String
    /// Seconds after the start of the service day. May exceed 24h for trips running past midnight.
    let arrival: Int
    let departure: Int
    let stopSequence: Int
    let routeID: String
    let serviceID: String
    let headsign: String

    init(tripID: String, stopID: String, arrival: Int, departure: Int, stopSequence: Int,
         routeID: String = "", serviceID: String = "", headsign: String = "") {
        self.tripID = tripID
        self.stopID = stopID
        self.arrival = arrival
        self.departure = departure
        self.stopSequence = stopSequence
        self.routeID = routeID
        self.serviceID = serviceID
        self.headsign = headsign
    }
}

/// Identifies one run of a trip, as seen from the stop it was picked at.
struct TripReference: Hashable, Sendable {
    let tripID: String
    let serviceDate: GTFSDate
    /// The stop the user was looking at, highlighted on the line screen.
    let stopID: String
    let stopSequence: Int
}

/// A trip's full schedule and shape, from the timetable.
struct TripDetails: Sendable {
    struct Call: Sendable {
        let stop: GTFSStop
        let call: StopCall
    }

    let tripID: String
    let route: GTFSRoute
    let headsign: String
    let serviceID: String
    /// Every stop in order of `stopSequence`.
    let calls: [Call]
    /// The route's path; empty if the feed has no shape for this trip.
    let shape: [CLLocationCoordinate2D]
}

/// A latitude/longitude rectangle, e.g. the visible part of a map.
struct CoordinateBounds: Hashable, Sendable {
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double
}

/// A calendar date in GTFS terms (`YYYYMMDD`), independent of time zone.
struct GTFSDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYYMMDD`.
    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 8, let value = Int(trimmed) else { return nil }
        self.init(year: value / 10_000, month: (value / 100) % 100, day: value % 100)
    }

    init(date: Date, calendar: Calendar = Dublin.calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year!, month: components.month!, day: components.day!)
    }

    var intValue: Int { year * 10_000 + month * 100 + day }

    var description: String { String(format: "%04d%02d%02d", year, month, day) }

    static func < (lhs: GTFSDate, rhs: GTFSDate) -> Bool { lhs.intValue < rhs.intValue }

    /// Monday = 0 … Sunday = 6, matching the column order of `calendar.txt`.
    func weekdayIndex(calendar: Calendar = Dublin.calendar) -> Int {
        let weekday = calendar.component(.weekday, from: noon(calendar: calendar)) // 1 = Sunday
        return (weekday + 5) % 7
    }

    func adding(days: Int, calendar: Calendar = Dublin.calendar) -> GTFSDate {
        let date = calendar.date(byAdding: .day, value: days, to: noon(calendar: calendar))!
        return GTFSDate(date: date, calendar: calendar)
    }

    /// GTFS times are measured from "noon minus 12h" of the service day,
    /// which differs from midnight only on daylight-saving transition days.
    func serviceDayReference(calendar: Calendar = Dublin.calendar) -> Date {
        noon(calendar: calendar).addingTimeInterval(-12 * 3600)
    }

    private func noon(calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}

/// Which `service_id`s run on which days (`calendar.txt` + `calendar_dates.txt`).
struct ServiceCalendar: Sendable {
    struct Entry: Sendable {
        /// Monday-first flags.
        let weekdays: [Bool]
        let start: GTFSDate
        let end: GTFSDate
    }

    var regular: [String: Entry] = [:]
    var added: [GTFSDate: Set<String>] = [:]
    var removed: [GTFSDate: Set<String>] = [:]

    func isActive(_ serviceID: String, on date: GTFSDate, calendar: Calendar = Dublin.calendar) -> Bool {
        if removed[date]?.contains(serviceID) == true { return false }
        if added[date]?.contains(serviceID) == true { return true }
        guard let entry = regular[serviceID], entry.start <= date, date <= entry.end else { return false }
        return entry.weekdays[date.weekdayIndex(calendar: calendar)]
    }
}

enum GTFSTime {
    /// Parses `H:MM:SS` / `HH:MM:SS` (hours may be ≥ 24) into seconds.
    static func seconds(from string: some StringProtocol) -> Int? {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Int(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }
}
