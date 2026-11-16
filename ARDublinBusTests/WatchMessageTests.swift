import Foundation
import Testing
@testable import ARDublinBus

struct WatchMessageTests {
    @Test func requestAndResponseRoundTrip() throws {
        let request = WatchNearbyRequest(latitude: 53.348596, longitude: -6.259485, stopLimit: 5)
        #expect(try WatchMessageCoding.decode(WatchNearbyRequest.self, from: WatchMessageCoding.encode(request)) == request)

        let response = WatchNearbyResponse(
            stops: [.init(code: "271", name: "O'Connell St Lwr", distance: 78, departures: [
                .init(id: "T1@20261116", route: "11", destination: "Sandyford",
                      expected: Date(timeIntervalSince1970: 1_794_767_593), isRealtime: true, isCancelled: false),
            ])],
            realtimeIssue: nil,
            generatedAt: Date(timeIntervalSince1970: 1_794_767_500),
            error: nil
        )
        #expect(try WatchMessageCoding.decode(WatchNearbyResponse.self, from: WatchMessageCoding.encode(response)) == response)
    }

    @Test func departedBusesDropOffTheList() {
        let now = Date.dublin(2026, 11, 16, 8, 0)
        func departure(_ id: String, in seconds: TimeInterval) -> WatchNearbyResponse.Departure {
            .init(id: id, route: "27", destination: "Clare Hall", expected: now.addingTimeInterval(seconds),
                  isRealtime: true, isCancelled: false)
        }
        let stop = WatchNearbyResponse.Stop(code: "271", name: "O'Connell St Lwr", distance: 40, departures: [
            departure("gone", in: -300), departure("due", in: -30), departure("soon", in: 240),
        ])
        #expect(stop.upcomingDepartures(at: now).map(\.id) == ["due", "soon"])
        #expect(stop.upcomingDepartures(at: now.addingTimeInterval(600)).isEmpty)
    }

    @Test func etaText() {
        let now = Date.dublin(2026, 11, 16, 8, 0)
        func eta(_ minutes: Double) -> String {
            WatchNearbyResponse.Departure(id: "x", route: "27", destination: "", expected: now.addingTimeInterval(minutes * 60),
                                          isRealtime: true, isCancelled: false).eta(from: now)
        }
        #expect(eta(0.4) == "Due")
        #expect(eta(-2) == "Due")
        #expect(eta(12.7) == "12 min")
        #expect(eta(90) == Date.dublin(2026, 11, 16, 9, 30).formatted(WatchNearbyResponse.Departure.clockFormat))
    }

    @Test func packsBoardsForTheWatch() {
        let now = Date.dublin(2026, 11, 16, 8, 0)
        let departures = (0..<8).map { index in
            Departure(id: "T\(index)", route: "27", destination: "Clare Hall", scheduled: now, expected: now.addingTimeInterval(Double(index) * 60),
                      isRealtime: index.isMultiple(of: 2), isCancelled: index == 3)
        }
        let stop = NearbyStop(stop: GTFSStop(id: GTFSFixture.stopID, code: "271", name: "O'Connell St Lwr", latitude: nil, longitude: nil),
                              stopIDs: [GTFSFixture.stopID], distance: 78)
        let board = StopBoard(stopCode: "271", stopName: "O'Connell St Lwr", departures: departures,
                              realtimeIssue: "No key", realtimeTimestamp: nil, generatedAt: now)

        let response = WatchNearbyResponse(nearby: [(stop, board)], generatedAt: now, departuresPerStop: 5)
        #expect(response.stops.count == 1)
        #expect(response.stops[0].departures.map(\.id) == ["T0", "T1", "T2", "T3", "T4"])
        #expect(response.stops[0].departures[3].isCancelled)
        #expect(response.stops[0].distance == 78)
        #expect(response.realtimeIssue == "No key")
        #expect(response.error == nil)
    }

    /// The full phone-side path, from a watch request to its reply, against the fixture timetable.
    @Test func responderAnswersFromTheTimetable() async throws {
        let fixture = try GTFSFixture()
        _ = try fixture.load()
        // Mark the fixture as already downloaded so the store doesn't fetch the real feed.
        try ISO8601DateFormatter().string(from: .now)
            .write(to: fixture.directory.appendingPathComponent("downloaded-at.txt"), atomically: true, encoding: .utf8)
        let service = DepartureService(
            timetableStore: TimetableStore(directory: fixture.directory),
            realtimeClient: RealtimeClient(apiKey: { nil })
        )

        let request = WatchNearbyRequest(latitude: 53.3495, longitude: -6.259485)
        let response = try await WatchResponder.respond(to: request, service: service, now: .dublin(2026, 11, 16, 8, 0))

        #expect(response.stops.map(\.code) == ["271"])
        #expect(response.stops[0].departures.first?.route == "27")
        #expect(response.stops[0].departures.count == 5)
        #expect(response.realtimeIssue == RealtimeError.missingAPIKey.errorDescription)
    }
}
