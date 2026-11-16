import Foundation
import Observation

/// A stop the user starred.
struct FavouriteStop: Codable, Hashable, Identifiable, Sendable {
    let code: String
    /// The stop's name when it was starred, shown until its board loads (may be empty).
    var name: String
    var id: String { code }
}

/// The user's starred stops, in the order they were added, kept in `UserDefaults`.
@MainActor
@Observable
final class FavouriteStops {
    private(set) var stops: [FavouriteStop]

    @ObservationIgnored private let defaults: UserDefaults
    static let defaultsKey = "favouriteStops"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([FavouriteStop].self, from: data) {
            stops = saved
        } else {
            stops = []
        }
    }

    func contains(_ code: String) -> Bool {
        stops.contains { $0.code == code }
    }

    /// Stars the stop, or unstars it if it's already a favourite.
    func toggle(code: String, name: String) {
        if contains(code) {
            stops.removeAll { $0.code == code }
        } else {
            stops.append(FavouriteStop(code: code, name: name))
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stops) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
