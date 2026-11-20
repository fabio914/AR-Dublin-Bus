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
    @State private var launchedAt = Date.now

    /// The intro stays up at least this long, so it doesn't flash by when nothing needs setting up.
    static let minimumIntroTime: TimeInterval = 1

    var body: some View {
        ZStack {
            if isSetUp {
                MainTabs()
                    .transition(.opacity)
            } else {
                IntroView(finish: showApp)
                    .transition(.opacity)
            }
        }
        .tint(Color.appTint)
        .task { await model.start() }
    }

    /// Fades from the intro to the tabs.
    private func showApp() {
        Task {
            let remaining = Self.minimumIntroTime - Date.now.timeIntervalSince(launchedAt)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            withAnimation(.easeInOut(duration: 0.5)) { isSetUp = true }
        }
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
        .minimizesTabBarOnScroll()
        .environment(\.isAboveTabBar, true)
    }
}

private extension View {
    /// The tab bar shrinks while scrolling down, and comes back when scrolling up.
    @ViewBuilder
    func minimizesTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
