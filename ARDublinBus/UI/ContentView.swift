import SwiftUI

enum AppTab: Hashable {
    case map, nearby, search, settings
}

/// Shows the intro screen until the timetable is on the device and the API key is dealt with,
/// then the app's tabs.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Latched, so clearing the key in Settings later doesn't bring the intro back.
    @State private var isSetUp = false

    var body: some View {
        Group {
            if isSetUp {
                MainTabs()
                    .transition(.opacity)
            } else {
                IntroView { withAnimation { isSetUp = true } }
                    .transition(.opacity)
            }
        }
        .task { await model.start() }
    }
}

/// The app's four tabs. The AR camera view is pushed from the Map tab.
private struct MainTabs: View {
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
    }
}
