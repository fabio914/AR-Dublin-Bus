import CoreGraphics
import simd

/// The kinds of bus stop sign found from their stop number label.
enum SignKind: Sendable, Equatable {
    /// The TFI flag: a green panel with the bus pictogram over "Stop 1234", on one line.
    case flag
    /// The round green sign: a bus pictogram, then "Stop" and the number on separate lines.
    case greenDisc
    /// The older round yellow Dublin Bus sign: the logo, "BUS", "STOP NO." and the number on
    /// separate lines.
    case yellowDisc
}

/// Measurements of the bus stop signs, in metres.
///
/// Mostly the TFI flag's. Measured on photos of real flags (stops 350 and 400, 16 November 2026), scaled to the flag's
/// size of about 50 × 90 cm. The "Stop 1234" label's position and size were found by projecting
/// Vision's text boxes onto each sign's plane; they agreed within a couple of centimetres across
/// daytime, night, straight-on and steep views.
enum SignLayout {
    /// The flag's height.
    static let signHeight: Float = 0.9

    /// The green panel at the top of the flag: 86% of the flag's width.
    static let panelWidth: Float = 0.43

    /// How far the green panel's top is below the flag's top edge.
    static let panelTopBelowSignTop: Float = 0.034

    /// `BusStopIcon.png`, the reference image ARKit looks for: the top of the green panel, edge to
    /// edge, from its top down to just below the bus pictogram (1000 × 683 px).
    static let referenceSize = SIMD2<Float>(panelWidth, panelWidth * 683 / 1000)

    /// How far the centre of the "Stop 1234" label is below the top of the green panel.
    static let labelCentreBelowPanelTop: Float = 0.333

    /// Width of each character of the label as Vision boxes it ("Stop 350" is about 0.316 m).
    static let labelCharacterWidth: Float = 0.0395

    /// Height of the label as Vision boxes it.
    static let labelHeight: Float = 0.072

    /// From the centre of the reference image down to the centre of the label.
    static var labelBelowReferenceCentre: Float { labelCentreBelowPanelTop - referenceSize.y / 2 }

    /// Diameter of the round signs, including their rim. An estimate: the photos (stops 2002 and
    /// 2383, 19 November 2026) compared with the poles they're on put both at 45–50 cm.
    static let discDiameter: Float = 0.45

    /// What the label search measures on a sign, and where that is on it.
    struct LabelMetrics: Equatable {
        /// Width of each character of the measured text, as Vision boxes it.
        let characterWidth: Float
        /// Height of the measured text, as Vision boxes it.
        let height: Float
        /// From the sign's origin down to the centre of the measured text. The origin is the
        /// reference image's centre on a flag, and the centre of a round sign.
        let labelBelowOrigin: Float
    }

    /// The flag's label is the whole "Stop 1234" line; on the round signs it's the number line on
    /// its own. The round signs' figures are from Vision's boxes on the photos, as fractions of
    /// the sign's diameter.
    static func metrics(for kind: SignKind) -> LabelMetrics {
        switch kind {
        case .flag:
            LabelMetrics(characterWidth: labelCharacterWidth, height: labelHeight,
                         labelBelowOrigin: labelBelowReferenceCentre)
        case .greenDisc:
            LabelMetrics(characterWidth: 0.108 * discDiameter, height: 0.195 * discDiameter,
                         labelBelowOrigin: 0.284 * discDiameter)
        case .yellowDisc:
            LabelMetrics(characterWidth: 0.101 * discDiameter, height: 0.162 * discDiameter,
                         labelBelowOrigin: 0.268 * discDiameter)
        }
    }

    /// From the sign's origin down to its bottom edge.
    ///
    /// A flag's measurements scale with `referenceSize`, ARKit's estimate of its size.
    static func signBottom(kind: SignKind, referenceSize: SIMD2<Float>) -> Float {
        switch kind {
        case .flag:
            (signHeight - panelTopBelowSignTop - Self.referenceSize.y / 2) * referenceSize.x / Self.referenceSize.x
        case .greenDisc, .yellowDisc:
            discDiameter / 2
        }
    }

    /// How far the departures card's top edge hangs below the flag's bottom edge.
    static let cardBelowSign: Float = 0.2

    /// How far in front of the flag the departures card is.
    static let cardInFront: Float = 0.1

    /// The centre of the departures card, relative to the sign's origin in the axes of an image
    /// anchor (x right, y out of the sign, z down the sign), for a card `cardHeight` tall lying
    /// flat on the sign. The card's gaps stay in metres whatever the sign's size.
    static func cardCenter(kind: SignKind, referenceSize: SIMD2<Float>, cardHeight: Float) -> SIMD3<Float> {
        SIMD3(0, cardInFront, signBottom(kind: kind, referenceSize: referenceSize) + cardBelowSign + cardHeight / 2)
    }

    /// The label's distance from the camera along its optical axis, from its size in the image.
    ///
    /// Seen from below, the label is foreshortened vertically; seen from the side, horizontally.
    /// Foreshortening only makes it look smaller (further away), so the nearer of the two
    /// estimates is used.
    ///
    /// - Parameters:
    ///   - text: the label as printed, such as "Stop 350" (or "2383" on a round sign).
    ///   - width: its length along the baseline, in pixels.
    ///   - height: its height, in pixels.
    ///   - focalLength: the camera's focal length, in pixels.
    static func labelDepth(text: String, width: CGFloat, height: CGFloat, focalLength: Float,
                           kind: SignKind = .flag) -> Float? {
        guard width > 0, height > 0, focalLength > 0, !text.isEmpty else { return nil }
        let metrics = metrics(for: kind)
        let fromWidth = focalLength * metrics.characterWidth * Float(text.count) / Float(width)
        let fromHeight = focalLength * metrics.height / Float(height)
        return min(fromWidth, fromHeight)
    }

    /// Where a sign's origin (`LabelMetrics`) is, given its stop number label in a camera frame,
    /// in the axes of an `ARImageAnchor`: x to the sign's right, y out of the sign towards the
    /// viewer, z down the sign. The sign is taken to be upright and facing the camera.
    ///
    /// - Parameters:
    ///   - label: the label, in the pixels of the camera image `intrinsics` describe.
    ///   - cameraTransform: the camera's pose when the frame was captured (ARKit's camera space:
    ///     x right, y up, looking down -z, for the camera image as stored). World y is up.
    static func signTransform(label: StopLabel, cameraTransform: simd_float4x4, intrinsics: simd_float3x3) -> simd_float4x4? {
        let (fx, fy) = (intrinsics[0][0], intrinsics[1][1])
        let (cx, cy) = (intrinsics[2][0], intrinsics[2][1])
        guard let depth = labelDepth(text: label.text, width: label.quad.width, height: label.quad.height,
                                     focalLength: fx, kind: label.kind) else {
            return nil
        }

        let center = label.quad.center
        let local = SIMD4<Float>((Float(center.x) - cx) / fx * depth, -(Float(center.y) - cy) / fy * depth, -depth, 1)
        let world = cameraTransform * local
        let labelPosition = SIMD3(world.x, world.y, world.z)

        let camera = cameraTransform.columns.3
        var towardsCamera = SIMD3(camera.x, camera.y, camera.z) - labelPosition
        towardsCamera.y = 0
        guard simd_length(towardsCamera) > 0.01 else { return nil }
        towardsCamera = simd_normalize(towardsCamera)
        let up = SIMD3<Float>(0, 1, 0)
        let right = simd_cross(towardsCamera, -up)
        let origin = labelPosition + up * metrics(for: label.kind).labelBelowOrigin
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(towardsCamera, 0), SIMD4(-up, 0), SIMD4(origin, 1)))
    }
}
