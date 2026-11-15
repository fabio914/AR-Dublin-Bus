import CoreLocation

enum LocationError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied: "Location access is off. Allow it in Settings to find stops near you."
        case .unavailable: "Your location couldn't be determined."
        }
    }
}

/// One-shot "where am I?" built on `CLLocationManager`, asking for permission when needed.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var locationContinuations: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        manager.delegate = self
        // Stop-level precision is plenty and arrives much faster than "best".
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func currentLocation() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorizationContinuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: throw LocationError.denied
        }

        return try await withCheckedThrowingContinuation { continuation in
            locationContinuations.append(continuation)
            if locationContinuations.count == 1 { manager.requestLocation() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined, let continuation = authorizationContinuation else { return }
            authorizationContinuation = nil
            continuation.resume()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { finish(.success(location)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        MainActor.assumeIsolated { finish(.failure(denied ? LocationError.denied : LocationError.unavailable)) }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        let continuations = locationContinuations
        locationContinuations.removeAll()
        continuations.forEach { $0.resume(with: result) }
    }
}
