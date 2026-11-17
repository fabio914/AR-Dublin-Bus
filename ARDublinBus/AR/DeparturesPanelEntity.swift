import RealityKit
import SwiftUI

/// A flat panel showing `DeparturesPanelView`, rendered with `ImageRenderer`
/// into an unlit texture so it stays crisp and readable in any lighting.
@MainActor
final class DeparturesPanelEntity: Entity {
    /// Width of the panel in the world, in metres: a little wider than the 50 cm sign.
    static let worldWidth: Float = 0.6

    private let plane = ModelEntity()
    private(set) var worldHeight: Float = 0

    required init() {
        super.init()
        addChild(plane)
    }

    func render(_ content: PanelContent, now: Date = .now) {
        // Always light in AR: a white card reads best over the camera image.
        let renderer = ImageRenderer(content: DeparturesPanelView(content: content, now: now).environment(\.colorScheme, .light))
        renderer.scale = 3
        renderer.isOpaque = false
        guard let image = renderer.cgImage,
              let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))

        worldHeight = Self.worldWidth * Float(image.height) / Float(image.width)
        // generatePlane(width:height:) lies in the x–y plane, facing +z.
        plane.model = ModelComponent(
            mesh: .generatePlane(width: Self.worldWidth, height: worldHeight),
            materials: [material]
        )
    }

    /// The panel's orientation lying on a sign, relative to its anchor (laid out like an image
    /// anchor: x right, y out of the sign, z down the sign). The plane faces +z and its top is +y,
    /// so a quarter turn about x makes it face out of the sign with its top up the sign.
    static let onSign = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
}

extension Entity {
    /// Rotates the entity (in world space) so its front (+z) faces `point`, keeping it upright.
    func turnToFace(_ point: SIMD3<Float>) {
        let position = position(relativeTo: nil)
        var forward = point - position
        guard simd_length(forward) > 0.001 else { return }
        forward = simd_normalize(forward)

        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(worldUp, forward)
        // Looking straight up/down: fall back to any perpendicular axis.
        if simd_length(right) < 0.001 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(forward, right)

        setOrientation(simd_quatf(simd_float3x3(columns: (right, up, forward))), relativeTo: nil)
    }
}
