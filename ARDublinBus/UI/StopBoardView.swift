import SwiftUI

/// A live-updating departures board for one stop (same look as the AR panel).
struct StopBoardView: View {
    @Environment(AppModel.self) private var model
    let stopCode: String
    @State private var content: PanelContent?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            DeparturesPanelView(content: content ?? .loading(stopCode: stopCode), now: context.date, maximumRows: 12)
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
