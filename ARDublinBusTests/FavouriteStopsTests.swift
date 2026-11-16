import Foundation
import Testing
@testable import ARDublinBus

@MainActor
struct FavouriteStopsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "FavouriteStopsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func togglesInTheOrderAdded() {
        let favourites = FavouriteStops(defaults: makeDefaults())
        #expect(favourites.stops.isEmpty)

        favourites.toggle(code: "271", name: "O'Connell St Lower")
        favourites.toggle(code: "1358", name: "Dame Street")
        #expect(favourites.stops.map(\.code) == ["271", "1358"])
        #expect(favourites.contains("271"))

        favourites.toggle(code: "271", name: "")
        #expect(favourites.stops.map(\.code) == ["1358"])
        #expect(!favourites.contains("271"))
    }

    @Test func persistsAcrossLaunches() {
        let defaults = makeDefaults()
        FavouriteStops(defaults: defaults).toggle(code: "271", name: "O'Connell St Lower")

        let reloaded = FavouriteStops(defaults: defaults)
        #expect(reloaded.stops == [FavouriteStop(code: "271", name: "O'Connell St Lower")])
    }
}
