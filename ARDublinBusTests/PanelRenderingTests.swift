import Foundation
import SwiftUI
import Testing
@testable import ARDublinBus

/// Renders the AR panel exactly as the texture is produced (via `ImageRenderer`).
/// Set `TEST_RUNNER_RENDER_DIR` to also write PNGs for visual inspection.
@MainActor
struct PanelRenderingTests {
    private func render(_ content: PanelContent, now: Date, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: DeparturesPanelView(content: content, now: now).frame(width: DeparturesPanelView.width).environment(\.colorScheme, .light))
        renderer.scale = 3
        renderer.isOpaque = false
        let image = try #require(renderer.cgImage)
        if let directory = ProcessInfo.processInfo.environment["RENDER_DIR"] {
            let data = try #require(UIImage(cgImage: image).pngData())
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return image
    }

    @Test func rendersEveryState() throws {
        let now = Date.dublin(2026, 11, 16, 8, 0)
        let timetable = try GTFSFixture().load()
        let calls = try timetable.calls(atStopIDs: [GTFSFixture.stopID])
        let departures = DepartureCalculator().departures(
            calls: calls, stopIDs: [GTFSFixture.stopID], timetable: timetable, realtime: nil, now: now
        )
        let board = StopBoard(stopCode: "271", stopName: "O'Connell St Lwr", departures: departures,
                              realtimeIssue: RealtimeError.missingAPIKey.errorDescription, realtimeTimestamp: nil, generatedAt: now)

        let states: [(String, PanelContent)] = [
            ("reading", .reading(hint: "Move closer so the stop number is in view")),
            ("loading", .loading(stopCode: "271")),
            ("failure", .failure(stopCode: "9999", message: "Stop 9999 isn't in the Dublin Bus timetable.")),
            ("board-fixture", .board(board)),
        ]
        for (name, content) in states {
            let image = try render(content, now: now, name: name)
            #expect(image.width == Int(DeparturesPanelView.width * 3))
            #expect(image.height > 100)
        }
    }

    /// The AR stop card's parts, each rendered as its own texture.
    @Test func rendersStopCardParts() throws {
        let now = Date.dublin(2026, 11, 16, 8, 0)
        let timetable = try GTFSFixture().load()
        let departures = DepartureCalculator().departures(
            calls: try timetable.calls(atStopIDs: [GTFSFixture.stopID]), stopIDs: [GTFSFixture.stopID],
            timetable: timetable, realtime: nil, now: now
        )
        let board = StopBoard(stopCode: "271", stopName: "O'Connell St Lwr", departures: departures,
                              realtimeIssue: nil, realtimeTimestamp: now, generatedAt: now)
        let parts: [(String, AnyView)] = [
            ("card-header", AnyView(StopCardEntity.HeaderView(title: "O'Connell St Lwr", subtitle: "Stop 271"))),
            ("card-lines", AnyView(StopCardEntity.FoldedBodyView(folded: .init(routes: ["1", "11", "11B", "44", "44D", "53", "122", "C1", "C2"])))),
            ("card-reading", AnyView(StopCardEntity.FoldedBodyView(folded: .init(message: "Reading the stop number…")))),
            ("card-board", AnyView(StopCardEntity.BoardView(content: .board(board), now: now))),
        ]
        for (name, view) in parts {
            let renderer = ImageRenderer(content: view.frame(width: DeparturesPanelView.width).environment(\.colorScheme, .light))
            renderer.scale = 3
            renderer.isOpaque = false
            let image = try #require(renderer.cgImage)
            #expect(image.width == Int(DeparturesPanelView.width * 3))
            if let directory = ProcessInfo.processInfo.environment["RENDER_DIR"] {
                let data = try #require(UIImage(cgImage: image).pngData())
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
    }

    @Test(.enabled(if: RealGTFS.directory != nil))
    func rendersRealStop271() throws {
        let timetable = try RealGTFS.timetable()
        let stops = try #require(timetable.stopsByCode["271"])
        let ids = Set(stops.map(\.id))
        let now = Date.dublin(2026, 11, 16, 8, 0) // a Monday morning
        let departures = DepartureCalculator().departures(
            calls: try timetable.calls(atStopIDs: ids), stopIDs: ids, timetable: timetable, realtime: nil, now: now
        )
        #expect(!departures.isEmpty)

        // Pretend the first two are live, to preview both row styles.
        let mixed = departures.enumerated().map { index, d in
            Departure(id: d.id, route: d.route, destination: d.destination, scheduled: d.scheduled,
                      expected: index < 3 ? d.expected.addingTimeInterval(90) : d.expected,
                      isRealtime: index < 3, isCancelled: index == 4)
        }
        let board = StopBoard(stopCode: "271", stopName: stops[0].name, departures: mixed,
                              realtimeIssue: nil, realtimeTimestamp: now, generatedAt: now)
        print("Stop 271 at 08:00 Monday:", departures.prefix(6).map { "\($0.route) \($0.destination) \(ETAText.clock($0.expected))" })
        _ = try render(.board(board), now: now, name: "board-real-271")
    }
}
