import CoreLocation
import Foundation

/// A route as seen from one stop: what the line screen shows.
struct LineReference: Hashable, Sendable {
    let routeID: String
    let stopCode: String
}

/// A route's stops, path and timetable from one stop, from the static timetable.
struct LineDetails: Sendable {
    let route: GTFSRoute
    /// The stop the line is seen from.
    let stop: GTFSStop
    /// One per destination leaving the stop, the most frequent first.
    let directions: [LineDirection]
    /// Which days each trip runs.
    let services: ServiceCalendar
}

/// The trips of a route leaving the stop for one destination.
struct LineDirection: Identifiable, Sendable {
    struct Stop: Identifiable, Sendable {
        let stop: GTFSStop
        let sequence: Int
        /// Seconds from the stop the line is seen from to this one, on a typical trip
        /// (negative for the stops before it).
        let offset: Int

        var id: Int { sequence }
    }

    /// One scheduled call at the stop the line is seen from.
    struct Departure: Sendable {
        let tripID: String
        let serviceID: String
        /// Seconds after the start of the service day. May exceed 24h past midnight.
        let time: Int
        let stopID: String
        let stopSequence: Int
    }

    let headsign: String
    /// Every stop of a typical trip, from the start of the route.
    let stops: [Stop]
    /// Where in `stops` the stop the line is seen from is.
    let stopIndex: Int
    /// The typical trip's path. Falls back to the stops' positions when the feed has no shape.
    let shape: [CLLocationCoordinate2D]
    /// Every scheduled call at the stop, on any day, by time.
    let departures: [Departure]

    var id: String { headsign }

    var tripIDs: Set<String> { Set(departures.map(\.tripID)) }

    /// The bus leaving the stop at a clock time, on one day.
    struct ScheduledDeparture: Identifiable, Hashable, Sendable {
        let time: Date
        let trip: TripReference

        var id: String { trip.tripID + "@\(trip.stopSequence)" }
    }

    /// The timetable for one service day, by time.
    func timetable(on date: GTFSDate, services: ServiceCalendar, calendar: Calendar = Dublin.calendar) -> [ScheduledDeparture] {
        let dayStart = date.serviceDayReference(calendar: calendar)
        return departures
            .filter { services.isActive($0.serviceID, on: date, calendar: calendar) }
            .map { departure in
                ScheduledDeparture(
                    time: dayStart.addingTimeInterval(TimeInterval(departure.time)),
                    trip: TripReference(tripID: departure.tripID, serviceDate: date,
                                        stopID: departure.stopID, stopSequence: departure.stopSequence)
                )
            }
    }
}
