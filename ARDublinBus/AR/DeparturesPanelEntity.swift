import RealityKit
import SwiftUI

/// A flat panel showing `DeparturesPanelView`, rendered with `ImageRenderer`
/// into an unlit texture so it stays crisp and readable in any lighting.
@MainActor
final class DeparturesPanelEntity: Entity {
    /// Width of the panel in the world, in metres.
    static let worldWidth: Float = 0.42

    private let plane = ModelEntity()
    private(set) var worldHeight: Float = 0

    required init() {
        super.init()
        addChild(plane)
    }

    func render(_ content: PanelContent, now: Date = .now) {
        let renderer = ImageRenderer(content: DeparturesPanelView(content: content, now: now))
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

    /// Rotates the panel (in world space) so its front faces `cameraPosition`, keeping it upright.
    func face(cameraPosition: SIMD3<Float>) {
        let position = position(relativeTo: nil)
        var forward = cameraPosition - position
        guard simd_length(forward) > 0.001 else { return }
        forward = simd_normalize(forward)

        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(worldUp, forward)
        // Looking straight up/down: fall back to any perpendicular axis.
        if simd_length(right) < 0.001 { right = SIMD3(1, 0, 0) }
        right = simd_normalize(right)
        let up = simd_cross(forward, right)

        let rotation = simd_quatf(simd_float3x3(columns: (right, up, forward)))
        setOrientation(rotation, relativeTo: nil)
    }
}
