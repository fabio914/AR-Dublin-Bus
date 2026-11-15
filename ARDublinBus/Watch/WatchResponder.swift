import CoreLocation
import Foundation
import UIKit
import WatchConnectivity

/// Answers the watch app's "what's near me?" requests.
///
/// The watch sends its location; this looks up nearby stops and their boards
/// with the same `DepartureService` the phone UI uses. A message from the watch
/// launches the iPhone app in the background if it isn't running.
final class WatchResponder: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let service: DepartureService

    init(service: DepartureService) {
        self.service = service
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data, replyHandler: @escaping (Data) -> Void) {
        let service = self.service
        Task { @MainActor in
            // A watch message may have launched us in the background: ask for time to finish
            // loading the timetable and the realtime feed before iOS suspends the app.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Watch nearby request")
            defer { UIApplication.shared.endBackgroundTask(backgroundTask) }

            let response: WatchNearbyResponse
            do {
                let request = try WatchMessageCoding.decode(WatchNearbyRequest.self, from: messageData)
                response = try await Self.respond(to: request, service: service)
            } catch {
                response = .failure((error as? LocalizedError)?.errorDescription ?? "The iPhone couldn't load nearby stops.")
            }
            replyHandler((try? WatchMessageCoding.encode(response)) ?? Data())
        }
    }

    static func respond(to request: WatchNearbyRequest, service: DepartureService, now: Date = .now) async throws -> WatchNearbyResponse {
        let coordinate = CLLocationCoordinate2D(latitude: request.latitude, longitude: request.longitude)
        let nearby = try await service.nearbyStops(around: coordinate, limit: request.stopLimit)
        let boards = try await service.boards(forStopCodes: nearby.map(\.stop.code), now: now)
        return WatchNearbyResponse(nearby: Array(zip(nearby, boards)), generatedAt: now)
    }

    // MARK: Session lifecycle

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Happens when the user switches watches; start talking to the new one.
        session.activate()
    }
}

extension WatchNearbyResponse {
    /// Packs boards for the watch: only what it displays, a handful of buses per stop.
    init(nearby: [(NearbyStop, StopBoard)], generatedAt: Date, departuresPerStop: Int = 5) {
        self.init(
            stops: nearby.map { stop, board in
                Stop(
                    code: stop.stop.code,
                    name: stop.stop.name,
                    distance: stop.distance,
                    departures: board.departures.prefix(departuresPerStop).map { departure in
                        Departure(
                            id: departure.id,
                            route: departure.route,
                            destination: departure.destination,
                            expected: departure.expected,
                            isRealtime: departure.isRealtime,
                            isCancelled: departure.isCancelled
                        )
                    }
                )
            },
            realtimeIssue: nearby.first?.1.realtimeIssue,
            generatedAt: generatedAt,
            error: nil
        )
    }
}
