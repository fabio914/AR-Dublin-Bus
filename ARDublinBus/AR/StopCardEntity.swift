import RealityKit
import SwiftUI

/// A bus stop as a card in AR: a green header with the stop, and under it either the lines that
/// call there with a pointer below (*folded*: the pin over a nearby stop) or the departures board
/// (*unfolded*). Further away, the folded card can also be *compact*: all green, with just the
/// stop's name and number in bigger type, at the same size as the folded card.
///
/// Each part is rendered from SwiftUI into its own texture when it changes; unfolding is animated
/// by resizing and cropping those layers, not by rendering frames. As `progress` goes from 0 to 1
/// the white card grows downwards, the lines and the pointer fade away, and the board is revealed
/// from the top as the card reaches it. As `compactness` goes from 0 to 1, the compact card
/// fades in over the folded one, and the white card and pointer turn green.
///
/// Local units are points of the SwiftUI layout (the card is `width` wide). The origin is the
/// middle of the card's top edge; x is right, y up, and the card faces +z. Scale the entity to
/// set its size in metres.
@MainActor
final class StopCardEntity: Entity {
    static let width = Float(DeparturesPanelView.width)
    static let cornerRadius = Float(PanelMetrics.cornerRadius)
    static let pointerSize = SIMD2<Float>(22, 12)
    /// Metres per point, unfolded: the card is 60 cm wide, a little wider than a 50 cm flag.
    static let unfoldedScale: Float = 0.6 / width
    /// How far the text layers are in front of the card's white background, in points.
    private static let layerOffset: Float = 0.5

    /// The card's orientation lying on a sign, relative to the sign (laid out like an image
    /// anchor: x right, y out of the sign, z down the sign). The card faces +z and its top is +y,
    /// so a quarter turn about x makes it face out of the sign with its top up the sign.
    static let onSign = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))

    struct Header: Equatable {
        var title: String
        var subtitle: String?
        /// Walking distance in metres, shown on the right.
        var distance: Int?

        /// A stop: its name on top and its number below, or just the number when there's no name.
        static func stop(code: String, name: String?, distance: Int?) -> Header {
            guard let name, !name.isEmpty else { return Header(title: "Stop \(code)", distance: distance) }
            return Header(title: name, subtitle: "Stop \(code)", distance: distance)
        }
    }

    /// What the folded card shows under the header.
    struct FoldedBody: Equatable {
        var routes: [String] = []
        /// Shown instead of the routes, such as "Reading the stop number…".
        var message: String?
    }

    private let background = ModelEntity()
    private let headerLayer = ModelEntity()
    private let foldedLayer = ModelEntity()
    private let boardLayer = ModelEntity()
    private let compactLayer = ModelEntity()
    private let pointer = ModelEntity()

    private(set) var header: Header?
    private(set) var foldedBody: FoldedBody?
    private(set) var content: PanelContent?
    private var boardTexture: TextureResource?

    private(set) var headerHeight: Float = 0
    private(set) var foldedHeight: Float = 0
    private(set) var boardHeight: Float = 0
    /// 0 folded … 1 unfolded.
    private(set) var progress: Float = 0
    /// 0 folded, with the lines … 1 compact.
    private(set) var compactness: Float = 0
    /// What the compact layer was last rendered for: the header's text and the card's height.
    private var builtCompact: CompactView?
    private var builtTint: Float = -1
    /// What the meshes were last built for, so they're only rebuilt when they change.
    private var builtCardHeight: Float = -1
    private var builtBoardCrop: Float = -1

    required init() {
        super.init()
        for layer in [background, pointer, headerLayer, foldedLayer, boardLayer, compactLayer] { addChild(layer) }
        // Opaque, so the transparent text layers always draw over it.
        let white = UnlitMaterial(color: .white)
        background.model = ModelComponent(mesh: .generatePlane(width: 1, height: 1), materials: [white])
        pointer.model = ModelComponent(mesh: Self.pointerMesh(), materials: [white])
        for layer in [headerLayer, foldedLayer, boardLayer] { layer.position.z = Self.layerOffset }
        // In front of the others, which it covers.
        compactLayer.position.z = Self.layerOffset * 2
        foldedLayer.components.set(OpacityComponent(opacity: 1))
        boardLayer.components.set(OpacityComponent(opacity: 0))
        compactLayer.components.set(OpacityComponent(opacity: 0))
        compactLayer.isEnabled = false
        setFoldedBody(FoldedBody())
    }

    // MARK: Content

    func setHeader(_ header: Header) {
        guard header != self.header else { return }
        self.header = header
        let view = HeaderView(header: header)
        guard let (texture, height) = Self.render(view) else { return }
        headerHeight = height
        headerLayer.model = ModelComponent(mesh: .generatePlane(width: Self.width, height: height),
                                           materials: [Self.material(texture)])
        headerLayer.position.y = -height / 2
        rebuild()
    }

    func setFoldedBody(_ body: FoldedBody) {
        guard body != foldedBody else { return }
        foldedBody = body
        guard let (texture, height) = Self.render(FoldedBodyView(folded: body)) else { return }
        foldedHeight = height
        foldedLayer.model = ModelComponent(mesh: .generatePlane(width: Self.width, height: height),
                                           materials: [Self.material(texture)])
        rebuild()
    }

    /// Shows `content` as the board. A board stays up while the same stop's departures reload.
    func setContent(_ content: PanelContent, now: Date = .now) {
        if case .loading(let code) = content, case .board(let board)? = self.content, board.stopCode == code { return }
        guard content != self.content else { return }
        self.content = content
        guard let (texture, height) = Self.render(BoardView(content: content, now: now)) else { return }
        boardTexture = texture
        boardHeight = height
        builtBoardCrop = -1
        rebuild()
    }

    // MARK: Unfolding

    func setProgress(_ progress: Float) {
        let progress = min(max(progress, 0), 1)
        guard progress != self.progress else { return }
        self.progress = progress
        rebuild()
    }

    /// 0 shows the folded card with its lines, 1 the compact one.
    func setCompactness(_ compactness: Float) {
        let compactness = min(max(compactness, 0), 1)
        guard compactness != self.compactness else { return }
        self.compactness = compactness
        rebuild()
    }

    /// Height of the white part under the header at `progress`.
    func bodyHeight(at progress: Float) -> Float {
        foldedHeight + (max(boardHeight, foldedHeight) - foldedHeight) * progress
    }

    /// The card's height at `progress`, header to pointer tip.
    func height(at progress: Float) -> Float {
        headerHeight + bodyHeight(at: progress) + Self.pointerSize.y * Self.pointerScale(at: progress)
    }

    /// The folded lines fade out over the first third of the unfolding.
    nonisolated static func foldedOpacity(at progress: Float) -> Float { 1 - smoothstep(progress / 0.35) }
    /// The board fades in once the lines have gone.
    nonisolated static func boardOpacity(at progress: Float) -> Float { smoothstep((progress - 0.3) / 0.5) }
    /// The pointer shrinks away first.
    nonisolated static func pointerScale(at progress: Float) -> Float { 1 - smoothstep(progress / 0.25) }
    /// The compact card shows as much as it's compact, and goes with the lines as the card unfolds.
    nonisolated static func compactOpacity(compactness: Float, progress: Float) -> Float {
        compactness * foldedOpacity(at: progress)
    }

    private func rebuild() {
        let body = bodyHeight(at: progress)
        let cardHeight = headerHeight + body
        if abs(cardHeight - builtCardHeight) > 0.25 {
            builtCardHeight = cardHeight
            background.model?.mesh = .generatePlane(width: Self.width, height: max(cardHeight, 1),
                                                    cornerRadius: min(Self.cornerRadius, cardHeight / 2))
        }
        background.position.y = -cardHeight / 2

        foldedLayer.position.y = -headerHeight - foldedHeight / 2
        foldedLayer.components.set(OpacityComponent(opacity: Self.foldedOpacity(at: progress)))
        foldedLayer.isEnabled = progress < 0.35

        let pointerScale = Self.pointerScale(at: progress)
        pointer.position.y = -cardHeight + 0.5 // tucked under the card's edge
        pointer.scale = SIMD3(1, pointerScale, 1)
        pointer.isEnabled = pointerScale > 0.01

        // The board, cropped to the part of the card that has opened so far.
        let visible = min(body, boardHeight)
        boardLayer.isEnabled = visible > 1 && Self.boardOpacity(at: progress) > 0.001
        boardLayer.components.set(OpacityComponent(opacity: Self.boardOpacity(at: progress)))
        boardLayer.position.y = -headerHeight
        if boardLayer.isEnabled, let boardTexture, abs(visible - builtBoardCrop) > 0.25,
           let mesh = Self.topOfPlane(width: Self.width, height: boardHeight, visibleHeight: visible) {
            builtBoardCrop = visible
            boardLayer.model = ModelComponent(mesh: mesh, materials: [Self.material(boardTexture)])
        }

        // The compact card covers the folded one (the header and the lines).
        let compactOpacity = Self.compactOpacity(compactness: compactness, progress: progress)
        compactLayer.isEnabled = compactOpacity > 0.001
        if compactLayer.isEnabled { buildCompactLayer() }
        compactLayer.components.set(OpacityComponent(opacity: compactOpacity))
        setTint(compactOpacity)
    }

    /// Renders the compact card when its text or size has changed (only once it's needed).
    private func buildCompactLayer() {
        guard let header else { return }
        let view = CompactView(title: header.title, subtitle: header.subtitle,
                               height: CGFloat(headerHeight + foldedHeight))
        guard view != builtCompact, let (texture, height) = Self.render(view) else { return }
        builtCompact = view
        compactLayer.model = ModelComponent(mesh: .generatePlane(width: Self.width, height: height),
                                            materials: [Self.material(texture)])
        compactLayer.position.y = -height / 2
    }

    /// Turns the white card and pointer green as the compact card shows, so no white shows at
    /// its edges.
    private func setTint(_ amount: Float) {
        // Only for a visible change, but always for the ends.
        guard amount != builtTint, abs(amount - builtTint) > 0.01 || amount == 0 || amount == 1 else { return }
        builtTint = amount
        let green = UIColor(TFIColors.green).cgColor.components ?? [0, 0.4, 0.33]
        let mix = { (channel: Int) in CGFloat(1 + (Float(green[channel]) - 1) * amount) }
        let material = UnlitMaterial(color: UIColor(red: mix(0), green: mix(1), blue: mix(2), alpha: 1))
        background.model?.materials = [material]
        pointer.model?.materials = [material]
    }

    // MARK: Meshes & textures

    /// The top `visibleHeight` of a `width` × `height` plane hanging down from the origin, with
    /// texture coordinates for that part of its texture (v = 1 is the image's top).
    nonisolated static func topOfPlane(width: Float, height: Float, visibleHeight: Float) -> MeshResource? {
        guard height > 0 else { return nil }
        let fraction = min(max(visibleHeight / height, 0), 1)
        var descriptor = MeshDescriptor(name: "cropped-board")
        let bottom = -height * fraction
        descriptor.positions = MeshBuffers.Positions([
            [-width / 2, 0, 0], [width / 2, 0, 0], [width / 2, bottom, 0], [-width / 2, bottom, 0],
        ])
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([
            [0, 1], [1, 1], [1, 1 - fraction], [0, 1 - fraction],
        ])
        descriptor.primitives = .triangles([0, 3, 2, 0, 2, 1]) // counter-clockwise, facing +z
        return try? MeshResource.generate(from: [descriptor])
    }

    /// A triangle pointing down from the origin.
    private static func pointerMesh() -> MeshResource {
        var descriptor = MeshDescriptor(name: "pointer")
        let (w, h) = (pointerSize.x, pointerSize.y)
        descriptor.positions = MeshBuffers.Positions([[-w / 2, 0, 0], [0, -h, 0], [w / 2, 0, 0]])
        descriptor.primitives = .triangles([0, 1, 2])
        return (try? MeshResource.generate(from: [descriptor])) ?? .generatePlane(width: w, height: h)
    }

    private static func material(_ texture: TextureResource) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return material
    }

    /// Renders `view` (`width` points wide) and returns its texture and height in points.
    private static func render(_ view: some View) -> (TextureResource, Float)? {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width)).environment(\.colorScheme, .light))
        renderer.scale = 3
        renderer.isOpaque = false
        guard let image = renderer.cgImage,
              let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else { return nil }
        return (texture, Float(image.height) / Float(renderer.scale))
    }
}

func smoothstep(_ x: Float) -> Float {
    let t = min(max(x, 0), 1)
    return t * t * (3 - 2 * t)
}

// MARK: - The card's parts

extension StopCardEntity {
    /// The green header, with rounded top corners (the white card shows below it).
    struct HeaderView: View {
        let header: Header

        var body: some View {
            PanelHeader(
                title: header.title,
                subtitle: header.subtitle,
                accessory: header.distance.map { PanelHeader.Accessory(systemImage: "figure.walk", text: "\($0) m") }
            )
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: PanelMetrics.cornerRadius,
                                               topTrailingRadius: PanelMetrics.cornerRadius, style: .continuous))
        }
    }

    /// The card from further away: the stop's name and number in bigger type, all on green, as
    /// tall as the folded card (header and lines) so the card keeps its size as it changes.
    struct CompactView: View, Equatable {
        let title: String
        let subtitle: String?
        let height: CGFloat

        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: "bus.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .frame(width: 60, height: 60)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 20, weight: .semibold))
                            .opacity(0.85)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, PanelMetrics.horizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(TFIColors.green)
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        }
    }

    /// The lines calling at the stop, or a message, on the folded card.
    struct FoldedBodyView: View {
        let folded: FoldedBody
        static let maximumRoutes = 12

        var body: some View {
            HStack(spacing: 0) {
                if let message = folded.message {
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.cardSecondaryInk)
                        .lineLimit(1)
                } else if folded.routes.isEmpty {
                    Color.clear.frame(height: 4)
                } else {
                    // As many whole chips as fit, then "+3" for the rest.
                    ViewThatFits(in: .horizontal) {
                        ForEach(Array(stride(from: min(folded.routes.count, Self.maximumRoutes), through: 1, by: -1)), id: \.self) {
                            chips($0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PanelMetrics.horizontalPadding)
            .padding(.vertical, 10)
        }

        private func chips(_ count: Int) -> some View {
            HStack(spacing: 6) {
                ForEach(folded.routes.prefix(count), id: \.self) { route in
                    Text(route)
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(TFIColors.ink)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 34, minHeight: 26)
                        .background(TFIColors.yellow, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if folded.routes.count > count {
                    Text("+\(folded.routes.count - count)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.cardSecondaryInk)
                }
            }
            .fixedSize()
        }
    }

    /// The departures, with the card's rounded bottom corners (for the footer's grey).
    struct BoardView: View {
        let content: PanelContent
        let now: Date

        var body: some View {
            DeparturesPanelBody(content: content, now: now)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: PanelMetrics.cornerRadius,
                                                   bottomTrailingRadius: PanelMetrics.cornerRadius, style: .continuous))
        }
    }
}

// MARK: - Helpers

/// A walking distance as shown on a card: rounded to 5 m (10 m from 100 m), and only changed when
/// it has really moved, so a distance hovering at a boundary doesn't re-render every frame.
struct DistanceLabel {
    private(set) var metres: Int?

    /// Returns true when the shown value changed.
    mutating func update(_ distance: Double) -> Bool {
        let rounded = Self.rounded(distance)
        if let metres {
            let step: Double = distance < 100 ? 5 : 10
            guard rounded != metres, abs(distance - Double(metres)) >= step * 0.75 else { return false }
        }
        metres = rounded
        return true
    }

    static func rounded(_ metres: Double) -> Int {
        metres < 100 ? Int((metres / 5).rounded()) * 5 : Int((metres / 10).rounded()) * 10
    }
}

extension Transform {
    /// Part way from `self` to `other`: positions and scales blend linearly, rotations along the
    /// shortest arc.
    func interpolated(to other: Transform, _ t: Float) -> Transform {
        Transform(scale: scale + (other.scale - scale) * t,
                  rotation: simd_slerp(rotation, other.rotation, t),
                  translation: translation + (other.translation - translation) * t)
    }
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
