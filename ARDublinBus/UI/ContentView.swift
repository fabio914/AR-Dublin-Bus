import SwiftUI

enum AppTab: Hashable {
    case map, nearby, search, settings
}

/// The app's four tabs. The AR camera view is pushed from the Map tab.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = AppTab.map

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Map", systemImage: "map.fill", value: AppTab.map) {
                StopsMapView { selectedTab = .settings }
            }
            Tab("Nearby", systemImage: "location.fill", value: AppTab.nearby) {
                NearbyStopsView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                StopLookupView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(TFIColors.green)
        .task { await model.start() }
    }
}
