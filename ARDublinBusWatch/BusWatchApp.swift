import SwiftUI

@main
struct BusWatchApp: App {
    @State private var model = WatchNearbyModel()

    var body: some Scene {
        WindowGroup {
            NearbyPagesView()
                .environment(model)
        }
    }
}
