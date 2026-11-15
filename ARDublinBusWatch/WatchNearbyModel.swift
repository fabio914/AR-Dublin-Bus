import Foundation
import Observation

@MainActor
@Observable
final class WatchNearbyModel {
    enum Phase: Equatable {
        case idle
        case locating
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The latest answer from the phone (kept on disk so the app opens with something to show).
    private(set) var response: WatchNearbyResponse?

    @ObservationIgnored private let location = LocationProvider()
    @ObservationIgnored private let phone = PhoneConnection()
    @ObservationIgnored private var isRefreshing = false

    static let refreshInterval: Duration = .seconds(30)
    private static let cacheKey = "lastNearbyResponse"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? WatchMessageCoding.decode(WatchNearbyResponse.self, from: data),
           Date.now.timeIntervalSince(cached.generatedAt) < 15 * 60 {
            response = cached
        }
    }

    /// Refreshes now, then every 30 s until the task is cancelled (e.g. the app goes to the background).
    func keepFresh() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            phase = .locating
            let here = try await location.currentLocation()
            phase = .loading
            let reply = try await phone.nearby(WatchNearbyRequest(
                latitude: here.coordinate.latitude,
                longitude: here.coordinate.longitude
            ))
            if let error = reply.error {
                phase = .failed(error)
                return
            }
            response = reply
            phase = .loaded
            if let data = try? WatchMessageCoding.encode(reply) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
            }
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
