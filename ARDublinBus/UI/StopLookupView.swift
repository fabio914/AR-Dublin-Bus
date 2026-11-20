import SwiftUI

/// The Search tab: look up a stop or a route by number or name without the camera — handy when
/// a sign can't be read, and for trying the app in the Simulator. Matching routes and stops are
/// listed as you type, and tapping one opens its screen (a route from its start). Before a
/// search, it shows the starred stops with their next buses.
struct StopLookupView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var results: [StopSearchResult] = []
    @State private var routeResults: [GTFSRoute] = []
    /// The query `results` and `routeResults` are for (`nil` before the first search finishes).
    @State private var searchedQuery: String?
    @State private var searchError: String?
    @State private var path = NavigationPath()
    @FocusState private var isInputFocused: Bool

    private var query: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Stop or route, by number or name", text: $input)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .focused($isInputFocused)
                                .onSubmit(searchNow)
                            if !input.isEmpty {
                                Button {
                                    // Back to the favourites, with the keyboard down.
                                    input = ""
                                    isInputFocused = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        // Only while typing; the keyboard's own search key does the same.
                        if isInputFocused {
                            Button("Search", action: searchNow)
                                .buttonStyle(.borderedProminent)
                                .tint(TFIColors.green)
                                .disabled(query.isEmpty)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.default, value: isInputFocused)
                    content
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .panelCardScrollView()
            .background(Color.appBackground)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FavouriteStop.self) { StopBoardScreen(stopCode: $0.code) }
            .navigationDestination(for: StopSearchResult.self) { StopBoardScreen(stopCode: $0.stop.code) }
            .routeDestinations()
        }
        .task(id: query) {
            guard !query.isEmpty else {
                results = []
                routeResults = []
                searchedQuery = nil
                return
            }
            // Wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    @ViewBuilder
    private var content: some View {
        if query.isEmpty {
            FavouriteStopsSection()
        } else if let searchError {
            Label(searchError, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if searchedQuery == nil {
            ProgressView()
                .padding(.top, 24)
        } else if results.isEmpty && routeResults.isEmpty {
            Text("No stops or routes match “\(searchedQuery ?? query)”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            if !routeResults.isEmpty {
                ResultsHeading(title: "Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                RouteResultsCard(routes: routeResults) { route in
                    isInputFocused = false
                    // A route on its own, from where its trips start.
                    path.append(LineReference(routeID: route.id, stopCode: nil))
                }
            }
            if !results.isEmpty {
                ResultsHeading(title: "Stops", systemImage: "bus.fill")
                StopResultsCard(results: results) { result in
                    isInputFocused = false
                    path.append(result)
                }
            }
        }
    }

    private func search(_ query: String) async {
        do {
            async let stops = model.service.searchStops(query)
            async let routes = model.service.searchRoutes(query)
            let (foundStops, foundRoutes) = try await (stops, routes)
            guard query == self.query else { return } // the text changed meanwhile
            results = foundStops
            routeResults = foundRoutes
            searchedQuery = query
            searchError = nil
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// Searches without waiting for a pause in typing, and hides the keyboard so the results
    /// can be seen. Opening a result is left to the user, even when the number matches exactly.
    private func searchNow() {
        let query = self.query
        guard !query.isEmpty else { return }
        isInputFocused = false
        Task { await search(query) }
    }
}

/// The starred stops, each with its next buses, kept up to date while shown.
private struct FavouriteStopsSection: View {
    @Environment(AppModel.self) private var model
    @State private var boards: [String: StopBoard] = [:]
    @State private var updatedAt: Date?
    @State private var loadError: String?

    private var favourites: [FavouriteStop] { model.favourites.stops }

    var body: some View {
        VStack(spacing: 0) {
            if favourites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Type a stop's number or name, like 271 or O'Connell, or a route's, like 27 or Clare Hall.")
                    Label("Star a stop to see its next buses here.", systemImage: "star")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Label("Favourite stops", systemImage: "star.fill")
                            .font(.headline)
                        Spacer(minLength: 0)
                    }
                    if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let updatedAt {
                        HStack(spacing: 6) {
                            RealtimeStatusLabel(issue: boards.values.first?.realtimeIssue, updatedAt: updatedAt)
                            Spacer(minLength: 0)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                // Each card brings the space above it.
                PanelCardStack {
                    ForEach(favourites) { favourite in
                        let board = boards[favourite.code]
                        StopSummaryCard(
                            code: favourite.code,
                            name: board?.stopName ?? favourite.name,
                            board: board,
                            unavailable: isKnown(favourite.code) ? nil : "This stop isn't in the current timetable.",
                            destination: favourite
                        )
                    }
                }
            }
        }
        .task(id: [model.isTimetableLoaded.description] + favourites.map(\.code)) {
            await refresh()
        }
    }

    /// A stop dropped from a newer timetable has no board.
    private func isKnown(_ code: String) -> Bool {
        model.knownStopCodes?.contains(code) ?? true
    }

    private func refresh() async {
        let codes = favourites.map(\.code).filter(isKnown)
        guard !codes.isEmpty else { return }
        while !Task.isCancelled {
            do {
                let found = try await model.service.boards(forStopCodes: codes)
                guard !Task.isCancelled else { return }
                boards = Dictionary(uniqueKeysWithValues: zip(codes, found))
                updatedAt = found.first?.updatedAt ?? .now
                loadError = nil
            } catch {
                if !Task.isCancelled { loadError = error.localizedDescription }
            }
            try? await Task.sleep(for: AppModel.refreshInterval)
        }
    }
}

/// A label above a group of search results.
private struct ResultsHeading: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Matching routes, each with its number and where it runs between.
private struct RouteResultsCard: View {
    let routes: [GTFSRoute]
    let select: (GTFSRoute) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                if index > 0 { PanelSeparator() }
                Button { select(route) } label: {
                    RouteResultRow(route: route)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .shadow(color: PanelMetrics.shadowColor, radius: PanelMetrics.shadowRadius, y: PanelMetrics.shadowOffset)
    }
}

private struct RouteResultRow: View {
    let route: GTFSRoute

    var body: some View {
        HStack(spacing: 12) {
            Text(route.shortName)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(TFIColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 56, height: 34)
                .background(TFIColors.yellow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(route.longName.isEmpty ? "Route \(route.shortName)" : route.longName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.cardInk)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cardSecondaryInk.opacity(0.7))
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Route \(route.shortName), \(route.longName)")
    }
}

/// Matching stops, each with the routes that call there.
private struct StopResultsCard: View {
    let results: [StopSearchResult]
    let select: (StopSearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { PanelSeparator() }
                Button { select(result) } label: {
                    StopResultRow(result: result)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

private struct StopResultRow: View {
    let result: StopSearchResult
    static let maximumRoutes = 8

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bus.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(TFIColors.green, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.stop.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.cardInk)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Stop \(result.stop.code)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.cardSecondaryInk)
                        .fixedSize()
                    // As many route badges as fit, then "+N" for the rest.
                    ViewThatFits(in: .horizontal) {
                        ForEach(Array(stride(from: min(result.routes.count, Self.maximumRoutes), through: 0, by: -1)), id: \.self) { count in
                            routeBadges(count)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.cardSecondaryInk.opacity(0.7))
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    private func routeBadges(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(result.routes.prefix(count), id: \.self) { route in
                Text(route)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(TFIColors.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(TFIColors.yellow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if result.routes.count > count {
                Text("+\(result.routes.count - count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.cardSecondaryInk)
            }
        }
        .fixedSize()
    }
}
