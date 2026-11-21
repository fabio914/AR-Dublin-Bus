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
            // Set apart from the other tabs, at the end of the tab bar.
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: Self.searchRole) {
                StopLookupView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .keepsTabBarOnScroll()
        .environment(\.isAboveTabBar, true)
    }

    /// iOS 27 sets a tab apart in the tab bar when it's `.prominent`; `.search` no longer does.
    private static var searchRole: TabRole {
        if #available(iOS 27.0, *) { .prominent } else { .search }
    }
}

private extension View {
    /// The tab bar stays at full size while scrolling.
    @ViewBuilder
    func keepsTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }
}
