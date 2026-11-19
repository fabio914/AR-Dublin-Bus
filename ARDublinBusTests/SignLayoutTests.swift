import CoreGraphics
import simd
import Testing
@testable import ARDublinBus

struct SignLayoutTests {
    /// A camera looking down -z with a 1280 px focal length, like a 1920 × 1440 ARKit frame.
    let intrinsics = simd_float3x3(columns: (SIMD3(1280, 0, 0), SIMD3(0, 1280, 0), SIMD3(960, 720, 1)))

    /// "Stop 350" as seen head-on from `depth` metres, centred on `center`.
    private func label(depth: Float, center: CGPoint = CGPoint(x: 960, y: 720)) -> StopLabel {
        let width = CGFloat(1280 * SignLayout.labelCharacterWidth * 8 / depth)
        let height = CGFloat(1280 * SignLayout.labelHeight / depth)
        return StopLabel(number: "350", text: "Stop 350", quad: Self.box(center: center, width: width, height: height), kind: .flag)
    }

    private static func box(center: CGPoint, width: CGFloat, height: CGFloat) -> ImageQuad {
        ImageQuad(
            topLeft: CGPoint(x: center.x - width / 2, y: center.y - height / 2),
            topRight: CGPoint(x: center.x + width / 2, y: center.y - height / 2),
            bottomRight: CGPoint(x: center.x + width / 2, y: center.y + height / 2),
            bottomLeft: CGPoint(x: center.x - width / 2, y: center.y + height / 2)
        )
    }

    @Test func depthFromTheLabelsSize() throws {
        let depth = try #require(SignLayout.labelDepth(text: "Stop 350", width: 135, height: 30.7, focalLength: 1280))
        #expect(abs(depth - 3) < 0.01)
        // Seen from below, the label looks shorter: its width still gives the distance.
        let fromBelow = try #require(SignLayout.labelDepth(text: "Stop 350", width: 135, height: 15, focalLength: 1280))
        #expect(abs(fromBelow - 3) < 0.01)
        #expect(SignLayout.labelDepth(text: "Stop 350", width: 0, height: 30, focalLength: 1280) == nil)
    }

    @Test func placesTheSignAboveItsLabel() throws {
        let transform = try #require(SignLayout.signTransform(label: label(depth: 3), cameraTransform: matrix_identity_float4x4,
                                                               intrinsics: intrinsics))
        let position = transform.columns.3
        #expect(abs(position.x) < 0.001)
        #expect(abs(position.y - SignLayout.labelBelowReferenceCentre) < 0.001) // the pictogram is above the label
        #expect(abs(position.z + 3) < 0.01)
        // Like an image anchor: x right, y towards the viewer, z down the sign.
        #expect(simd_distance(transform.columns.0, SIMD4(1, 0, 0, 0)) < 0.001)
        #expect(simd_distance(transform.columns.1, SIMD4(0, 0, 1, 0)) < 0.001)
        #expect(simd_distance(transform.columns.2, SIMD4(0, -1, 0, 0)) < 0.001)
    }

    @Test func signStaysUprightWhenSeenFromBelow() throws {
        // The phone tilted 40° up; the label is in the middle of the image.
        let pitch = simd_float4x4(simd_quatf(angle: 40 * .pi / 180, axis: SIMD3(1, 0, 0)))
        let transform = try #require(SignLayout.signTransform(label: label(depth: 3), cameraTransform: pitch, intrinsics: intrinsics))
        // Still upright, facing back along the horizontal direction to the camera.
        #expect(simd_distance(transform.columns.2, SIMD4(0, -1, 0, 0)) < 0.001)
        #expect(simd_distance(transform.columns.1, SIMD4(0, 0, 1, 0)) < 0.001)
        // The label is 3 m along the tilted view: up and ahead of the camera.
        let position = transform.columns.3
        #expect(abs(position.y - (3 * sin(40 * .pi / 180) + SignLayout.labelBelowReferenceCentre)) < 0.01)
        #expect(abs(position.z + 3 * cos(40 * .pi / 180)) < 0.01)
    }

    /// The departures panel lies flat on the sign: facing out of it, its top up the sign.
    @MainActor @Test func panelLiesOnTheSign() {
        let rotation = DeparturesPanelEntity.onSign
        #expect(simd_distance(rotation.act(SIMD3(0, 0, 1)), SIMD3(0, 1, 0)) < 0.0001)  // front → out of the sign
        #expect(simd_distance(rotation.act(SIMD3(0, 1, 0)), SIMD3(0, 0, -1)) < 0.0001) // top → up the sign
        #expect(simd_distance(rotation.act(SIMD3(1, 0, 0)), SIMD3(1, 0, 0)) < 0.0001)  // right stays right
    }

    @Test func cardHangsBelowTheSign() {
        let center = SignLayout.cardCenter(kind: .flag, referenceSize: SignLayout.referenceSize, cardHeight: 0.7)
        // The flag's bottom edge is 0.9 - 0.034 m below the green panel's top; the anchor is the
        // reference image's centre, half its height below that top.
        let signBottom: Float = 0.9 - 0.034 - SignLayout.referenceSize.y / 2
        #expect(abs(center.x) < 0.0001)
        #expect(abs(center.y - 0.1) < 0.0001)                       // 10 cm in front
        #expect(abs(center.z - (signBottom + 0.2 + 0.35)) < 0.0001) // top edge 20 cm below the sign

        // A sign ARKit judges 10% bigger: the sign scales, the gaps don't.
        let bigger = SignLayout.cardCenter(kind: .flag, referenceSize: SignLayout.referenceSize * 1.1, cardHeight: 0.7)
        #expect(abs(bigger.z - (signBottom * 1.1 + 0.2 + 0.35)) < 0.0001)
    }

    /// A round sign's number line, seen head-on from 3 m: its origin is the disc's centre, above
    /// the number, and the card hangs below the disc.
    @Test(arguments: [SignKind.greenDisc, .yellowDisc])
    func placesARoundSignFromItsNumber(kind: SignKind) throws {
        let metrics = SignLayout.metrics(for: kind)
        let label = StopLabel(number: "2383", text: "2383", quad: Self.box(
            center: CGPoint(x: 960, y: 720),
            width: CGFloat(1280 * metrics.characterWidth * 4 / 3),
            height: CGFloat(1280 * metrics.height / 3)
        ), kind: kind)
        let transform = try #require(SignLayout.signTransform(label: label, cameraTransform: matrix_identity_float4x4,
                                                               intrinsics: intrinsics))
        let position = transform.columns.3
        #expect(abs(position.z + 3) < 0.01)
        #expect(abs(position.y - metrics.labelBelowOrigin) < 0.001)
        #expect(metrics.labelBelowOrigin > 0.1 && metrics.labelBelowOrigin < SignLayout.discDiameter / 2)

        // ARKit's estimate of a flag's size doesn't apply to a round sign.
        let center = SignLayout.cardCenter(kind: kind, referenceSize: SignLayout.referenceSize * 1.1, cardHeight: 0.7)
        #expect(abs(center.z - (SignLayout.discDiameter / 2 + 0.2 + 0.35)) < 0.0001)
    }

    @Test func referenceImageMatchesThePanelWidth() {
        #expect(SignLayout.referenceSize.x == SignLayout.panelWidth)
        #expect(BusStopSign.physicalWidth == CGFloat(SignLayout.panelWidth))
    }
}
