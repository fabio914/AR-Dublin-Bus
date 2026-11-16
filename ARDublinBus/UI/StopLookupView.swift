import SwiftUI

/// The Search tab: look up a stop by number or name without the camera — handy when a sign
/// can't be read, and for trying the app in the Simulator. Matching stops are listed as you type,
/// and tapping one opens its screen. Before a search, it shows the starred stops with their next buses.
struct StopLookupView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var results: [StopSearchResult] = []
    /// The query `results` are for (`nil` before the first search finishes).
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
                            TextField("Stop number or name", text: $input)
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
            .background(Color.appBackground)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FavouriteStop.self) { StopBoardScreen(stopCode: $0.code) }
            .navigationDestination(for: StopSearchResult.self) { StopBoardScreen(stopCode: $0.stop.code) }
            .tripDestination()
        }
        .task(id: query) {
            guard !query.isEmpty else {
                results = []
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
        } else if results.isEmpty {
            Text("No stops match “\(searchedQuery ?? query)”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            StopResultsCard(results: results) { result in
                isInputFocused = false
                path.append(result)
            }
        }
    }

    private func search(_ query: String) async {
        do {
            let found = try await model.service.searchStops(query)
            guard query == self.query else { return } // the text changed meanwhile
            results = found
            searchedQuery = query
            searchError = nil
        } catch {
            searchError = error.localizedDescription
        }
    }

    /// Searches without waiting for a pause in typing, and hides the keyboard so the results
    /// can be seen. Opening a stop is left to the user, even when the number matches exactly.
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
        VStack(spacing: 16) {
            if favourites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Type a stop number, like 271, or part of a stop's name, like O'Connell.")
                    Label("Star a stop to see its next buses here.", systemImage: "star")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Label("Favourites", systemImage: "star.fill")
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
                ForEach(favourites) { favourite in
                    let board = boards[favourite.code]
                    StopSummaryCard(
                        code: favourite.code,
                        name: board?.stopName ?? favourite.name,
                        board: board,
                        unavailable: isKnown(favourite.code) ? nil : "This stop isn't in the current timetable.",
                        destination: favourite
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .light)
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
                    .foregroundStyle(TFIColors.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Stop \(result.stop.code)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TFIColors.secondaryInk)
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
                .foregroundStyle(TFIColors.secondaryInk.opacity(0.7))
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
                    .foregroundStyle(TFIColors.secondaryInk)
            }
        }
        .fixedSize()
    }
}
