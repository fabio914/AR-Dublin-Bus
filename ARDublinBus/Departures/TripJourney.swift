import CoreLocation
import Foundation

/// One run of a trip with its stops, scheduled and expected times: what the line screen shows.
struct TripJourney: Sendable {
    struct Stop: Identifiable, Sendable {
        let stop: GTFSStop
        let sequence: Int
        let scheduled: Date
        let expected: Date
        /// `expected` comes from live data.
        let isRealtime: Bool
        /// The bus won't call here (trip cancelled or stop skipped).
        let isCancelled: Bool
        /// The bus has already left this stop.
        let hasPassed: Bool

        var id: Int { sequence }
    }

    let reference: TripReference
    let route: GTFSRoute
    let headsign: String
    let stops: [Stop]
    /// The route's path. Falls back to the stops' positions when the feed has no shape.
    let shape: [CLLocationCoordinate2D]
    /// When live data is unavailable, why.
    let realtimeIssue: String?
    let generatedAt: Date

    /// The stop the user picked the bus from.
    var origin: Stop? { stops.first { $0.sequence == reference.stopSequence } }

    var isCancelled: Bool { !stops.isEmpty && stops.allSatisfy(\.isCancelled) }

    /// Applies the live feed to every stop of the trip, with the same rules as the boards.
    static func make(
        details: TripDetails,
        reference: TripReference,
        realtime: RealtimeSnapshot?,
        realtimeIssue: String?,
        now: Date,
        calendar: Calendar = Dublin.calendar
    ) -> TripJourney {
        let dayStart = reference.serviceDate.serviceDayReference(calendar: calendar)
        let update = realtime?.update(forTripID: details.tripID, serviceDate: reference.serviceDate)

        let stops = details.calls.map { entry -> Stop in
            let call = entry.call
            let scheduled = dayStart.addingTimeInterval(TimeInterval(call.arrival))
            let status = update.map { DepartureCalculator.status(of: $0, at: call, stopIDs: [call.stopID]) } ?? .scheduledOnly

            let expected: Date
            switch status {
            case .scheduledOnly, .cancelled, .passed: expected = scheduled
            case .delay(let seconds): expected = scheduled.addingTimeInterval(TimeInterval(seconds))
            case .absolute(let date): expected = date
            }

            return Stop(
                stop: entry.stop,
                sequence: call.stopSequence,
                scheduled: scheduled,
                expected: expected,
                isRealtime: status != .scheduledOnly && status != .cancelled && status != .passed,
                isCancelled: status == .cancelled,
                hasPassed: status == .passed || expected < now.addingTimeInterval(-30)
            )
        }

        let shape = details.shape.isEmpty
            ? details.calls.compactMap { entry in
                entry.stop.latitude.flatMap { latitude in
                    entry.stop.longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
                }
            }
            : details.shape

        return TripJourney(
            reference: reference,
            route: details.route,
            headsign: details.headsign,
            stops: stops,
            shape: shape,
            realtimeIssue: realtimeIssue,
            generatedAt: now
        )
    }
}
