import Foundation

struct Departure: Identifiable, Hashable, Sendable {
    let id: String
    let route: String
    let destination: String
    let scheduled: Date
    let expected: Date
    /// Whether `expected` comes from live (GTFS-R) data rather than the timetable.
    let isRealtime: Bool
    let isCancelled: Bool
    /// The scheduled trip, for showing its line. `nil` for trips added by the live feed.
    var trip: TripReference? = nil

    var delay: TimeInterval { expected.timeIntervalSince(scheduled) }

    /// Whole minutes until `expected`, never negative.
    func minutesAway(from now: Date) -> Int {
        max(0, Int(expected.timeIntervalSince(now) / 60))
    }
}

/// Combines the static timetable with a realtime snapshot into the next departures at a stop.
struct DepartureCalculator {
    var calendar: Calendar = Dublin.calendar
    /// How far ahead to look.
    var lookAhead: TimeInterval = 90 * 60
    /// Buses that were due very recently are still shown ("Due").
    var lookBehind: TimeInterval = 60
    var limit = 12

    /// How the live data affects one scheduled call.
    enum RealtimeStatus: Equatable {
        case scheduledOnly
        case delay(Int)
        case absolute(Date)
        case cancelled
        /// The vehicle is already past this stop.
        case passed
    }

    func departures(
        calls: [StopCall],
        stopIDs: Set<String>,
        timetable: StaticTimetable,
        realtime: RealtimeSnapshot?,
        now: Date
    ) -> [Departure] {
        let today = GTFSDate(date: now, calendar: calendar)
        let earliest = now.addingTimeInterval(-lookBehind)
        let latest = now.addingTimeInterval(lookAhead)
        // Late buses can still be on their way long after their scheduled time.
        let maximumLateness: TimeInterval = 2 * 3600

        var results: [Departure] = []

        // Trips from yesterday can run past midnight (times ≥ 24:00:00); tomorrow's
        // early trips can fall inside the look-ahead window late at night.
        for dayOffset in -1...1 {
            let serviceDate = today.adding(days: dayOffset, calendar: calendar)
            let reference = serviceDate.serviceDayReference(calendar: calendar)

            // A trip that ends here can't be boarded, so it isn't a departure.
            for call in calls where !call.isLastStop {
                let scheduled = reference.addingTimeInterval(TimeInterval(call.arrival))
                guard scheduled >= earliest.addingTimeInterval(-maximumLateness),
                      scheduled <= latest.addingTimeInterval(30 * 60),
                      timetable.services.isActive(call.serviceID, on: serviceDate, calendar: calendar) else { continue }

                let status = realtime?.update(forTripID: call.tripID, serviceDate: serviceDate)
                    .map { Self.status(of: $0, at: call, stopIDs: stopIDs) } ?? .scheduledOnly

                let expected: Date
                switch status {
                case .passed: continue
                case .scheduledOnly, .cancelled: expected = scheduled
                case .delay(let seconds): expected = scheduled.addingTimeInterval(TimeInterval(seconds))
                case .absolute(let date): expected = date
                }
                guard expected >= earliest, expected <= latest else { continue }

                results.append(Departure(
                    id: "\(call.tripID)@\(serviceDate)",
                    route: timetable.routes[call.routeID]?.shortName ?? call.routeID,
                    destination: call.headsign,
                    scheduled: scheduled,
                    expected: expected,
                    isRealtime: status != .scheduledOnly && status != .cancelled,
                    isCancelled: status == .cancelled,
                    trip: TripReference(tripID: call.tripID, serviceDate: serviceDate, stopID: call.stopID, stopSequence: call.stopSequence)
                ))
            }
        }

        results += addedDepartures(stopIDs: stopIDs, timetable: timetable, realtime: realtime, earliest: earliest, latest: latest)

        return Array(results.sorted { $0.expected < $1.expected }.prefix(limit))
    }

    /// Applies GTFS-Realtime semantics to one scheduled call: use the update for this
    /// stop if there is one, otherwise propagate the delay of the nearest earlier stop.
    static func status(of update: GTFSRTripUpdate, at call: StopCall, stopIDs: Set<String>) -> RealtimeStatus {
        switch update.trip.scheduleRelationship {
        case .canceled, .deleted: return .cancelled
        default: break
        }

        let updates = update.stopTimeUpdate ?? []

        let exact = updates.first { stopUpdate in
            if let sequence = stopUpdate.stopSequence?.value { return sequence == call.stopSequence }
            return stopUpdate.stopID.map(stopIDs.contains) ?? false
        }
        if let exact {
            switch exact.scheduleRelationship {
            case .skipped: return .cancelled
            case .noData: return .scheduledOnly
            default: break
            }
            if let time = exact.arrival?.time?.value ?? exact.departure?.time?.value, time > 0 {
                return .absolute(Date(timeIntervalSince1970: TimeInterval(time)))
            }
            if let delay = exact.arrival?.delay?.value ?? exact.departure?.delay?.value {
                return .delay(delay)
            }
        }

        let sequenced = updates
            .compactMap { update in update.stopSequence.map { (sequence: $0.value, update: update) } }
            .sorted { $0.sequence < $1.sequence }

        if let previous = sequenced.last(where: { $0.sequence < call.stopSequence })?.update {
            if previous.scheduleRelationship == .noData { return .scheduledOnly }
            if let delay = previous.departure?.delay?.value ?? previous.arrival?.delay?.value {
                return .delay(delay)
            }
            return update.delay.map { .delay($0.value) } ?? .scheduledOnly
        }

        // Every update refers to a later stop: the bus has already been here.
        if exact == nil, let first = sequenced.first, first.sequence > call.stopSequence {
            return .passed
        }

        return update.delay.map { .delay($0.value) } ?? .scheduledOnly
    }

    private func addedDepartures(
        stopIDs: Set<String>,
        timetable: StaticTimetable,
        realtime: RealtimeSnapshot?,
        earliest: Date,
        latest: Date
    ) -> [Departure] {
        guard let realtime else { return [] }
        return realtime.addedTrips.compactMap { update in
            guard let stopUpdate = update.stopTimeUpdate?.first(where: { $0.stopID.map(stopIDs.contains) ?? false }),
                  stopUpdate.scheduleRelationship != .skipped,
                  let time = stopUpdate.arrival?.time?.value ?? stopUpdate.departure?.time?.value else { return nil }
            let expected = Date(timeIntervalSince1970: TimeInterval(time))
            guard expected >= earliest, expected <= latest else { return nil }
            let route = update.trip.routeID.flatMap { timetable.routes[$0] }
            return Departure(
                id: "added-\(update.trip.tripID ?? UUID().uuidString)",
                route: route?.shortName ?? "Bus",
                destination: route?.longName ?? "Additional service",
                scheduled: expected,
                expected: expected,
                isRealtime: true,
                isCancelled: false
            )
        }
    }
}
