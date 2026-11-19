import SwiftUI

/// A stop's departures board (same look as the AR panel) followed by all its lines, with a map
/// of where each one goes, in a scroll view. Loads both and keeps the board fresh. Tapping a bus
/// or a line opens it, so use inside a `NavigationStack` that uses `routeDestinations()`.
struct StopDetailsView: View {
    @Environment(AppModel.self) private var model
    let stopCode: String
    @State private var content: PanelContent?
    @State private var overview: StopLines?
    @State private var linesError: String?

    /// Enough departures that most lines' next bus is found, not just the first 12 shown.
    static let departureLimit = 200

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                PanelCardStack {
                    DeparturesPanelView(
                        content: content ?? .loading(stopCode: stopCode),
                        now: context.date,
                        maximumRows: 12,
                        linksToTrips: true,
                        favourite: favourite
                    )
                    StopLinesCard(overview: overview, error: linesError, board: board, now: context.date)
                }
                .padding([.horizontal, .bottom])
            }
        }
        .background(Color.appBackground)
        .task(id: stopCode) {
            content = .loading(stopCode: stopCode)
            while !Task.isCancelled {
                do {
                    let board = try await model.service.board(forStopCode: stopCode, limit: Self.departureLimit)
                    if !Task.isCancelled { content = .board(board) }
                } catch {
                    if !Task.isCancelled { content = .failure(stopCode: stopCode, message: error.localizedDescription) }
                }
                try? await Task.sleep(for: AppModel.refreshInterval)
            }
        }
        .task(id: stopCode) {
            do {
                overview = try await model.service.lines(atStopCode: stopCode)
            } catch {
                linesError = error.localizedDescription
            }
        }
    }

    private var board: StopBoard? {
        if case .board(let board) = content { board } else { nil }
    }

    private var favourite: PanelHeader.Favourite {
        let name = board?.stopName ?? ""
        let favourites = model.favourites
        return .init(isOn: favourites.contains(stopCode)) { [stopCode] in
            withAnimation { favourites.toggle(code: stopCode, name: name) }
        }
    }
}

/// A stop as a screen pushed onto a `NavigationStack` that uses `routeDestinations()`.
struct StopBoardScreen: View {
    let stopCode: String

    var body: some View {
        StopDetailsView(stopCode: stopCode)
            .navigationTitle("Stop \(stopCode)")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// A stop's board and lines in a sheet over another screen (the map, or the AR view), with its
/// own navigation so buses can open their line.
struct StopBoardSheet: View {
    let stop: GTFSStop
    let done: () -> Void

    var body: some View {
        NavigationStack {
            StopDetailsView(stopCode: stop.code)
                .navigationTitle(stop.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: done)
                    }
                }
                .routeDestinations()
        }
        .presentationDetents([.medium, .large])
        // Keep the screen behind usable while the board is at half height.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
