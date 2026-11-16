import Foundation
import Testing
@testable import ARDublinBus

@Suite(.serialized)
struct RealtimeClientTests {
    static let feed = Data(#"{"header":{"timestamp":"1700000000"},"entity":[]}"#.utf8)
    let start = Date.dublin(2026, 11, 16, 8, 0)

    private func makeClient() -> RealtimeClient {
        StubURLProtocol.requests = 0
        StubURLProtocol.response = .success((200, Self.feed))
        return RealtimeClient(session: StubURLProtocol.makeSession(), minimumInterval: 60, apiKey: { "key" })
    }

    @Test func fetchesAtMostOncePerInterval() async throws {
        let client = makeClient()
        _ = try await client.snapshot(now: start)
        _ = try await client.snapshot(now: start.addingTimeInterval(30))
        #expect(StubURLProtocol.requests == 1)
        _ = try await client.snapshot(now: start.addingTimeInterval(61))
        #expect(StubURLProtocol.requests == 2)
    }

    @Test func recentSnapshotSurvivesAFailedRefetch() async throws {
        let client = makeClient()
        let first = try await client.snapshot(now: start)
        StubURLProtocol.response = .failure(URLError(.notConnectedToInternet))
        let second = try await client.snapshot(now: start.addingTimeInterval(120))
        #expect(second.fetchedAt == first.fetchedAt)
    }

    @Test func oldSnapshotIsNotReturnedAfterAFailedRefetch() async throws {
        let client = makeClient()
        _ = try await client.snapshot(now: start)
        StubURLProtocol.response = .failure(URLError(.notConnectedToInternet))

        // The refetch fails and the snapshot is too old to stand in.
        let later = start.addingTimeInterval(RealtimeClient.maximumAge + 60)
        await #expect(throws: (any Error).self) { try await client.snapshot(now: later) }
        // Within the throttle window, the old snapshot must not come back either.
        await #expect(throws: (any Error).self) { try await client.snapshot(now: later.addingTimeInterval(10)) }
        #expect(StubURLProtocol.requests == 2)
    }

    @Test func missingKeyDoesNotHitTheNetwork() async {
        StubURLProtocol.requests = 0
        let client = RealtimeClient(session: StubURLProtocol.makeSession(), apiKey: { nil })
        await #expect(throws: RealtimeError.missingAPIKey) { try await client.snapshot() }
        #expect(StubURLProtocol.requests == 0)
    }
}
