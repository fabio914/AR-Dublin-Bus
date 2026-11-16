import SwiftUI

/// A live-updating departures board for one stop (same look as the AR panel).
/// Tapping a bus opens its line, so use it inside a `NavigationStack` with `tripDestination()`.
struct StopBoardView: View {
    @Environment(AppModel.self) private var model
    let stopCode: String
    @State private var content: PanelContent?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            DeparturesPanelView(content: content ?? .loading(stopCode: stopCode), now: context.date, maximumRows: 12, linksToTrips: true)
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
        .task(id: stopCode) {
            content = .loading(stopCode: stopCode)
            while !Task.isCancelled {
                do {
                    let board = try await model.service.board(forStopCode: stopCode)
                    if !Task.isCancelled { content = .board(board) }
                } catch {
                    if !Task.isCancelled { content = .failure(stopCode: stopCode, message: error.localizedDescription) }
                }
                try? await Task.sleep(for: AppModel.refreshInterval)
            }
        }
    }
}

/// A stop's board in a sheet over another screen (the map, or the AR view), with its own
/// navigation so buses can open their line.
struct StopBoardSheet: View {
    let stop: GTFSStop
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                StopBoardView(stopCode: stop.code)
                    .padding()
            }
            .background(Color(.systemGroupedBackground))
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
