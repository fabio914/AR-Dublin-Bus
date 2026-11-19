import CoreGraphics
import simd

/// The kinds of bus stop sign the app finds.
enum SignKind: Sendable, Equatable {
    /// The TFI flag: a green panel with the bus pictogram over "Stop 1234", on one line.
    case flag
    /// The round green sign: the flag's bus pictogram, then "Stop" and the number on separate lines.
    case greenDisc
    /// The older round yellow Dublin Bus sign: the logo, "BUS", "STOP NO." and the number on
    /// separate lines.
    case yellowDisc
}

/// Measurements of the bus stop signs, in metres.
///
/// The flag's were measured on photos of real flags (stops 350 and 400, 16 November 2026), scaled
/// to the flag's size of about 50 × 90 cm. The "Stop 1234" label's position and size were found by
/// projecting Vision's text boxes onto each sign's plane; they agreed within a couple of
/// centimetres across daytime, night, straight-on and steep views.
///
/// The round signs' were measured on perspective-corrected photos (stops 2002 and 2383,
/// 19 November 2026), as fractions of the sign's diameter.
enum SignLayout {
    /// The flag's height.
    static let signHeight: Float = 0.9

    /// The green panel at the top of the flag: 86% of the flag's width.
    static let panelWidth: Float = 0.43

    /// How far the green panel's top is below the flag's top edge.
    static let panelTopBelowSignTop: Float = 0.034

    /// `BusStopIcon.png`, the reference image ARKit looks for on a flag: the top of the green
    /// panel, edge to edge, from its top down to just below the bus pictogram (1000 × 683 px).
    static let referenceSize = SIMD2<Float>(panelWidth, panelWidth * 683 / 1000)

    /// How far the centre of the "Stop 1234" label is below the top of the green panel.
    static let labelCentreBelowPanelTop: Float = 0.333

    /// Width of each character of the label as Vision boxes it ("Stop 350" is about 0.316 m).
    static let labelCharacterWidth: Float = 0.0395

    /// Height of the label as Vision boxes it.
    static let labelHeight: Float = 0.072

    /// From the centre of the reference image down to the centre of the label.
    static var labelBelowReferenceCentre: Float { labelCentreBelowPanelTop - referenceSize.y / 2 }

    /// Diameter of the round signs, to the outside of their rim. An estimate: the photos compared
    /// with the poles the signs are on put both at 45–50 cm.
    static let discDiameter: Float = 0.45

    /// Where things are on one kind of sign, measured from its origin: the centre of the
    /// reference image ARKit looks for on it (`BusStopSign`).
    struct Geometry: Equatable {
        /// The reference image's size as printed on this kind of sign.
        let referenceSize: SIMD2<Float>
        /// From the origin down to the centre of the label the whole-frame search measures: the
        /// "Stop 1234" line on a flag, the number line on its own on a round sign.
        let labelBelowOrigin: Float
        /// From the origin down to the sign's bottom edge.
        let bottomBelowOrigin: Float
        /// Width of each character of that label, as Vision boxes it.
        let labelCharacterWidth: Float
        /// Height of that label, as Vision boxes it.
        let labelHeight: Float
    }

    static func geometry(of kind: SignKind) -> Geometry {
        let d = discDiameter
        return switch kind {
        case .flag:
            Geometry(referenceSize: referenceSize, labelBelowOrigin: labelBelowReferenceCentre,
                     bottomBelowOrigin: signHeight - panelTopBelowSignTop - referenceSize.y / 2,
                     labelCharacterWidth: labelCharacterWidth, labelHeight: labelHeight)
        case .greenDisc:
            // `BusStopIcon.png` matched to the disc's (smaller) bus pictogram.
            Geometry(referenceSize: SIMD2(0.787 * d, 0.5375 * d), labelBelowOrigin: 0.503 * d,
                     bottomBelowOrigin: 0.716 * d, labelCharacterWidth: 0.108 * d, labelHeight: 0.195 * d)
        case .yellowDisc:
            // `DublinBusLogo.png`: the logo and "BUS", a square 0.519 of the diameter across.
            Geometry(referenceSize: SIMD2(0.519 * d, 0.519 * d), labelBelowOrigin: 0.3875 * d,
                     bottomBelowOrigin: 0.5995 * d, labelCharacterWidth: 0.101 * d, labelHeight: 0.162 * d)
        }
    }

    /// How far the departures card's top edge hangs below the sign's bottom edge.
    static let cardBelowSign: Float = 0.2

    /// How far in front of the sign the departures card is.
    static let cardInFront: Float = 0.1

    /// The centre of the departures card, relative to the sign's origin in the axes of an image
    /// anchor (x right, y out of the sign, z down the sign), for a card `cardHeight` tall lying
    /// flat on the sign.
    ///
    /// The sign's measurements scale with `referenceSize`, ARKit's estimate of its reference
    /// image's size; the card's gaps stay in metres.
    static func cardCenter(kind: SignKind, referenceSize: SIMD2<Float>, cardHeight: Float) -> SIMD3<Float> {
        let geometry = geometry(of: kind)
        let scale = referenceSize.x / geometry.referenceSize.x
        return SIMD3(0, cardInFront, geometry.bottomBelowOrigin * scale + cardBelowSign + cardHeight / 2)
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
        let geometry = geometry(of: kind)
        let fromWidth = focalLength * geometry.labelCharacterWidth * Float(text.count) / Float(width)
        let fromHeight = focalLength * geometry.labelHeight / Float(height)
        return min(fromWidth, fromHeight)
    }

    /// Where a sign's origin (`Geometry`) is, given its stop number label in a camera frame, in
    /// the axes of an `ARImageAnchor`: x to the sign's right, y out of the sign towards the
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
        let origin = labelPosition + up * geometry(of: label.kind).labelBelowOrigin
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(towardsCamera, 0), SIMD4(-up, 0), SIMD4(origin, 1)))
    }
}
