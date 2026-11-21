import RealityKit
import SwiftUI

/// A stop near the user, shown as a floating label in AR.
struct ARStop: Identifiable, Hashable, Sendable {
    let stop: GTFSStop
    let routes: [String]

    var id: String { stop.id }
}

/// The pin over a stop near the user: a `StopCardEntity` pointing down at the stop. It shows the
/// stop in three steps as the user walks up to it:
/// - further than `NearbyUnfolding.routesDistance`, compact: just the stop's name and number;
/// - closer, folded: the stop, its distance and its lines;
/// - next to the stop (`NearbyUnfolding.unfoldDistance`), unfolded: the departures board.
///
/// Compact or folded, the card keeps roughly the same size on screen whatever the distance, and
/// turns to face the camera. Unfolded, it's at a readable real size around eye level, still
/// facing the camera.
@MainActor
final class StopPinEntity: Entity, HasCollision {
    private(set) var stop: ARStop?
    let card = StopCardEntity()
    private var distanceLabel = DistanceLabel()

    /// Unfolded, or unfolding.
    private(set) var isUnfolded = false
    /// 0 folded … 1 unfolded, moving towards `isUnfolded`.
    private(set) var unfolding: Float = 0
    /// Far enough that the card is compact; `nil` until the first distance.
    private(set) var isCompact: Bool?
    /// 0 folded … 1 compact, moving towards `isCompact`.
    private var compacting: Float = 0
    private var builtCollision: (progress: Float, height: Float)?

    /// Height of the pointer's tip above the ground, in metres. The entity's origin is the tip.
    static let heightAboveGround: Float = 2.6
    /// Unfolded, the card's top edge is this high above the ground, in metres: around eye level.
    static let unfoldedTopAboveGround: Float = 1.9
    /// Seconds to unfold or fold.
    static let unfoldDuration: Float = 0.6
    /// Seconds to go between compact and folded.
    static let compactDuration: Float = 0.4
    /// Compact or folded, how much bigger the card is than it was at first (with `width(atDistance:)`).
    static let foldedSizeFactor: Float = 1.25

    required init() {
        super.init()
        addChild(card)
    }

    convenience init(stop: ARStop) {
        self.init()
        self.stop = stop
        name = "stop-pin:\(stop.stop.code)"
        card.setHeader(Self.header(for: stop, distance: nil))
        card.setFoldedBody(StopCardEntity.FoldedBody(routes: stop.routes))
    }

    static func header(for stop: ARStop, distance: Int?) -> StopCardEntity.Header {
        .stop(code: stop.stop.code, name: stop.stop.name, distance: distance)
    }

    /// Shows the walking distance, re-rendering only when the rounded value changes, and makes
    /// the card compact or not for it.
    func update(distance: Double) {
        let compact = NearbyUnfolding.isCompact(current: isCompact, distance: Float(distance))
        if isCompact == nil { compacting = compact ? 1 : 0 } // no animation for a new pin
        isCompact = compact
        guard let stop, distanceLabel.update(distance) else { return }
        card.setHeader(Self.header(for: stop, distance: distanceLabel.metres))
    }

    /// How compact the card is now (0 folded … 1 compact), for a sign's card taking over from it.
    var compactness: Float { card.compactness }

    func setUnfolded(_ unfolded: Bool) {
        isUnfolded = unfolded
    }

    /// Folds at once (the card was handed over to a sign, say).
    func fold() {
        isUnfolded = false
        unfolding = 0
        card.setProgress(0)
    }

    func showContent(_ content: PanelContent) {
        card.setContent(content)
    }

    /// Advances the unfolding, then sizes, places and turns the card for the camera.
    func layout(cameraPosition: SIMD3<Float>, deltaTime: Float) {
        let step = deltaTime / Self.unfoldDuration
        unfolding = isUnfolded ? min(unfolding + step, 1) : max(unfolding - step, 0)
        let progress = smoothstep(unfolding)
        let compactStep = deltaTime / Self.compactDuration
        compacting = isCompact == true ? min(compacting + compactStep, 1) : max(compacting - compactStep, 0)
        card.setCompactness(smoothstep(compacting))

        // Metres per point: folded it depends on the distance; unfolded it's the card's real size.
        let distance = simd_distance(position(relativeTo: nil), cameraPosition)
        let foldedScale = Self.width(atDistance: distance) * Self.foldedSizeFactor / StopCardEntity.width
        let scale = foldedScale + (StopCardEntity.unfoldedScale - foldedScale) * progress
        self.scale = SIMD3(repeating: scale)

        // Where the card's top edge is, in metres above the pointer's tip.
        let foldedTop = card.height(at: 0) * foldedScale
        let unfoldedTop = Self.unfoldedTopAboveGround - Self.heightAboveGround
        card.position = SIMD3(0, (foldedTop + (unfoldedTop - foldedTop) * progress) / scale, 0)
        card.setProgress(progress)
        turnToFace(cameraPosition)
        updateCollision()
    }

    /// Taps hit the card wherever it is: rebuilt as it unfolds or changes size.
    private func updateCollision() {
        let progress = card.progress
        let height = card.height(at: progress)
        if let built = builtCollision, built.progress == progress, abs(built.height - height) < 0.5 { return }
        builtCollision = (progress, height)
        let top = card.position.y
        collision = CollisionComponent(shapes: [
            .generateBox(width: StopCardEntity.width, height: height, depth: 1).offsetBy(translation: [0, top - height / 2, 0]),
        ])
    }

    /// Metres per card width (folded) that keep the card readable: grows with distance, so its
    /// size on screen shrinks only slowly.
    nonisolated static func width(atDistance distance: Float) -> Float {
        min(max(0.9 + distance * 0.09, 1.2), 36)
    }
}
