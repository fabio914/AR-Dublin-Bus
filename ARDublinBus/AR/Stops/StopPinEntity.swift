import RealityKit
import SwiftUI

/// A stop near the user, shown as a floating label in AR.
struct ARStop: Identifiable, Hashable, Sendable {
    let stop: GTFSStop
    let routes: [String]

    var id: String { stop.id }
}

/// A floating label over a stop: its name, number, routes and distance.
///
/// Rendered from SwiftUI into an unlit texture, like the departures panel. The label keeps
/// roughly the same size on screen whatever the distance, and turns to face the camera.
@MainActor
final class StopPinEntity: Entity, HasCollision {
    private(set) var stop: ARStop?
    private let label = ModelEntity()
    private var renderedDistance: Int?

    /// Height of the label's bottom edge above the ground, in metres.
    static let heightAboveGround: Float = 2.6
    static let pointsPerUnit: Float = 300

    required init() {
        super.init()
        addChild(label)
    }

    convenience init(stop: ARStop) {
        self.init()
        self.stop = stop
        name = "stop-pin:\(stop.stop.code)"
    }

    /// Re-renders when the distance has changed by a rounding step (with some hysteresis,
    /// so a distance hovering at a boundary doesn't re-render every frame).
    func update(distance: Double) {
        guard let stop else { return }
        let rounded = Self.roundedDistance(distance)
        if let renderedDistance {
            let step: Double = distance < 100 ? 5 : 10
            guard rounded != renderedDistance, abs(distance - Double(renderedDistance)) >= step * 0.75 else { return }
        }
        renderedDistance = rounded

        let renderer = ImageRenderer(content: StopPinView(stop: stop, distance: rounded))
        renderer.scale = 3
        renderer.isOpaque = false
        guard let image = renderer.cgImage,
              let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        // 300 points of label = 1 unit, scaled by `layout`, so text is the same size on every pin.
        // The label's bottom edge (the pointer's tip) sits at the entity's origin.
        let width = Float(image.width) / Float(renderer.scale) / Self.pointsPerUnit
        let height = Float(image.height) / Float(renderer.scale) / Self.pointsPerUnit
        label.model = ModelComponent(mesh: .generatePlane(width: width, height: height), materials: [material])
        label.position.y = height / 2
        collision = CollisionComponent(shapes: [
            .generateBox(width: width, height: height, depth: 0.01).offsetBy(translation: [0, height / 2, 0]),
        ])
    }

    /// Sizes the label for its distance and turns it to face the camera.
    func layout(cameraPosition: SIMD3<Float>) {
        let distance = simd_distance(position(relativeTo: nil), cameraPosition)
        scale = SIMD3(repeating: Self.width(atDistance: distance))
        turnToFace(cameraPosition)
    }

    /// Metres per unit (about one label width) that keep the label readable: grows with
    /// distance, so its size on screen shrinks only slowly.
    nonisolated static func width(atDistance distance: Float) -> Float {
        min(max(0.9 + distance * 0.09, 1.2), 36)
    }

    nonisolated static func roundedDistance(_ metres: Double) -> Int {
        metres < 100 ? Int((metres / 5).rounded()) * 5 : Int((metres / 10).rounded()) * 10
    }
}

/// The label's content.
struct StopPinView: View {
    let stop: ARStop
    let distance: Int
    static let maximumRoutes = 5

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "bus.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(stop.stop.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("Stop \(stop.stop.code) · \(distance) m")
                            .font(.system(size: 14, weight: .semibold))
                            .opacity(0.9)
                        ForEach(stop.routes.prefix(Self.maximumRoutes), id: \.self) { route in
                            Text(route)
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .foregroundStyle(TFIColors.ink)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(TFIColors.yellow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        if stop.routes.count > Self.maximumRoutes {
                            Text("+\(stop.routes.count - Self.maximumRoutes)")
                                .font(.system(size: 12, weight: .bold))
                                .opacity(0.9)
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(TFIColors.green, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.9), lineWidth: 2))

            // Points down at the stop.
            Triangle()
                .fill(TFIColors.green)
                .frame(width: 22, height: 12)
        }
        .fixedSize()
        .padding(4)
        .environment(\.colorScheme, .light)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}
