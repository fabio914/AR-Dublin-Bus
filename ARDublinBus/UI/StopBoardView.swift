import SwiftUI

/// A live-updating departures board for one stop (same look as the AR panel).
/// Tapping a bus opens its line, so use it inside a `NavigationStack` with `tripDestination()`.
struct StopBoardView: View {
    @Environment(AppModel.self) private var model
    let stopCode: String
    /// The most departures to load (only the first 12 are shown), when more are needed by `onBoard`.
    var departureLimit: Int?
    /// Called with each board as it loads.
    var onBoard: ((StopBoard) -> Void)?
    @State private var content: PanelContent?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            DeparturesPanelView(
                content: content ?? .loading(stopCode: stopCode),
                now: context.date,
                maximumRows: 12,
                linksToTrips: true,
                favourite: favourite
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .task(id: stopCode) {
            content = .loading(stopCode: stopCode)
            while !Task.isCancelled {
                do {
                    let board = try await model.service.board(forStopCode: stopCode, limit: departureLimit)
                    if !Task.isCancelled {
                        content = .board(board)
                        onBoard?(board)
                    }
                } catch {
                    if !Task.isCancelled { content = .failure(stopCode: stopCode, message: error.localizedDescription) }
                }
                try? await Task.sleep(for: AppModel.refreshInterval)
            }
        }
    }

    private var favourite: PanelHeader.Favourite {
        var name = ""
        if case .board(let board) = content { name = board.stopName }
        let favourites = model.favourites
        return .init(isOn: favourites.contains(stopCode)) { [stopCode] in
            withAnimation { favourites.toggle(code: stopCode, name: name) }
        }
    }
}

/// A stop's board followed by all its lines, with a map of where each one goes. Loads both and
/// keeps the board fresh. Use inside a `NavigationStack` that uses `tripDestination()`.
struct StopDetailsView: View {
    @Environment(AppModel.self) private var model
    let stopCode: String
    @State private var overview: StopLines?
    @State private var linesError: String?
    @State private var board: StopBoard?
    @State private var selectedLineID: String?

    /// Enough departures that most lines' next bus is found, not just the first 12.
    static let departureLimit = 200

    var body: some View {
        VStack(spacing: 16) {
            StopBoardView(stopCode: stopCode, departureLimit: Self.departureLimit) { board = $0 }
            TimelineView(.periodic(from: .now, by: 20)) { context in
                StopLinesCard(
                    overview: overview,
                    error: linesError,
                    board: board,
                    now: context.date,
                    selectedLineID: $selectedLineID
                )
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
}

/// A stop as a screen pushed onto a `NavigationStack` that uses `tripDestination()`.
struct StopBoardScreen: View {
    let stopCode: String

    var body: some View {
        ScrollView {
            StopDetailsView(stopCode: stopCode)
                .padding()
        }
        .background(Color.appBackground)
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
            ScrollView {
                StopDetailsView(stopCode: stop.code)
                    .padding()
            }
            .background(Color.appBackground)
            .navigationTitle(stop.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
            .tripDestination()
        }
        .presentationDetents([.medium, .large])
        // Keep the screen behind usable while the board is at half height.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }
}
