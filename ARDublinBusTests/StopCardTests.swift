import RealityKit
import simd
import Testing
@testable import ARDublinBus

struct NearbyUnfoldingTests {
    @Test func unfoldsTheNearestStopWithinFiveMetres() {
        #expect(NearbyUnfolding.stop(current: nil, distances: ["a": 12, "b": 6]) == nil)
        #expect(NearbyUnfolding.stop(current: nil, distances: ["a": 4.5, "b": 3]) == "b")
        #expect(NearbyUnfolding.stop(current: nil, distances: [String: Float]()) == nil)
    }

    @Test func staysUnfoldedUntilEightMetres() {
        // Walking away: still unfolded at 7 m, folded past 8 m.
        #expect(NearbyUnfolding.stop(current: "a", distances: ["a": 7]) == "a")
        #expect(NearbyUnfolding.stop(current: "a", distances: ["a": 8.5]) == nil)
        // Another stop coming within 5 m doesn't take over while the first is still close.
        #expect(NearbyUnfolding.stop(current: "a", distances: ["a": 6, "b": 2]) == "a")
        // The unfolded stop is gone (its sign took it over, say): the next nearest within 5 m.
        #expect(NearbyUnfolding.stop(current: "a", distances: ["b": 4]) == "b")
    }
}

struct DistanceLabelTests {
    @Test func roundsAndIgnoresJitter() {
        var label = DistanceLabel()
        let first = label.update(42)
        #expect(first && label.metres == 40)
        let jitter = label.update(43.5) // 45 when rounded, but only 3.5 m from what's shown
        #expect(!jitter && label.metres == 40)
        let moved = label.update(44.5)
        #expect(moved && label.metres == 45)
        let far = label.update(140)
        #expect(far && label.metres == 140)
        #expect(DistanceLabel.rounded(146) == 150)
    }
}

@MainActor
struct StopCardEntityTests {
    private func card() -> StopCardEntity {
        let card = StopCardEntity()
        card.setHeader(.init(title: "Stop 271", subtitle: "O'Connell St Lwr", distance: 40))
        card.setFoldedBody(.init(routes: ["1", "11", "44"]))
        card.setContent(.failure(stopCode: "271", message: "Stop 271 isn't in the Dublin Bus timetable. It may be new."))
        return card
    }

    @Test func unfoldingGrowsTheCardFromTheLinesToTheBoard() {
        let card = card()
        #expect(card.headerHeight > 50)
        #expect(card.foldedHeight > 20)
        #expect(card.boardHeight > card.foldedHeight)

        #expect(card.bodyHeight(at: 0) == card.foldedHeight)
        #expect(card.bodyHeight(at: 1) == card.boardHeight)
        #expect(card.bodyHeight(at: 0.5) > card.foldedHeight && card.bodyHeight(at: 0.5) < card.boardHeight)
        // Folded, the pointer hangs under the lines; unfolded, it's gone.
        #expect(card.height(at: 0) == card.headerHeight + card.foldedHeight + StopCardEntity.pointerSize.y)
        #expect(card.height(at: 1) == card.headerHeight + card.boardHeight)
    }

    @Test func linesFadeOutBeforeTheBoardFadesIn() {
        #expect(StopCardEntity.foldedOpacity(at: 0) == 1)
        #expect(StopCardEntity.boardOpacity(at: 0) == 0)
        #expect(StopCardEntity.foldedOpacity(at: 0.35) == 0)
        #expect(StopCardEntity.boardOpacity(at: 0.3) == 0)
        #expect(StopCardEntity.boardOpacity(at: 1) == 1)
        #expect(StopCardEntity.pointerScale(at: 0.25) == 0)
        for step in 0...20 {
            let progress = Float(step) / 20
            // Never both clearly visible at once.
            #expect(min(StopCardEntity.foldedOpacity(at: progress), StopCardEntity.boardOpacity(at: progress)) == 0)
        }
    }

    @Test func keepsTheBoardWhileTheSameStopReloads() {
        let card = card()
        let board = StopBoard(stopCode: "271", stopName: "O'Connell St Lwr", departures: [], realtimeIssue: nil,
                              realtimeTimestamp: nil, generatedAt: .now)
        card.setContent(.board(board))
        card.setContent(.loading(stopCode: "271"))
        #expect(card.content == .board(board))
        card.setContent(.loading(stopCode: "44"))
        #expect(card.content == .loading(stopCode: "44"))
    }

    @Test func cropsTheBoardFromTheTop() throws {
        let mesh = try #require(StopCardEntity.topOfPlane(width: 360, height: 400, visibleHeight: 100))
        let bounds = mesh.bounds
        #expect(abs(bounds.max.y - 0) < 0.001)
        #expect(abs(bounds.min.y + 100) < 0.001)
        #expect(abs(bounds.extents.x - 360) < 0.001)
        // Asking for more than there is shows the whole plane.
        let whole = try #require(StopCardEntity.topOfPlane(width: 360, height: 400, visibleHeight: 900))
        #expect(abs(whole.bounds.min.y + 400) < 0.001)
    }

    @Test func blendsTransformsForTheFlight() {
        let pin = Transform(scale: SIMD3(repeating: 0.004), rotation: simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)),
                            translation: SIMD3(10, 2.6, -4))
        let sign = Transform(scale: SIMD3(repeating: StopCardEntity.unfoldedScale), rotation: StopCardEntity.onSign,
                             translation: SIMD3(0, 0.1, 1))
        let start = pin.interpolated(to: sign, 0)
        let end = pin.interpolated(to: sign, 1)
        #expect(simd_distance(start.translation, pin.translation) < 0.0001)
        #expect(simd_distance(end.translation, sign.translation) < 0.0001)
        #expect(abs(end.scale.x - StopCardEntity.unfoldedScale) < 0.000001)
        let middle = pin.interpolated(to: sign, 0.5)
        #expect(simd_distance(middle.translation, (pin.translation + sign.translation) / 2) < 0.0001)
    }
}
