import ARKit
import UIKit

/// Geometry of the TFI bus stop flag, relative to the detected bus pictogram.
///
/// The reference image (`BusStopIcon.png`) is the top of the green panel on the
/// flag: the white bus pictogram, edge to edge across the panel. It was cut from
/// a photo of a Dublin stop flag and perspective-corrected, since the NTA does not publish
/// the artwork. The "Stop 1234" line sits directly underneath it.
enum BusStopSign {
    static let referenceImageName = "BusStopIcon"

    /// Approximate printed width of the green panel, in metres. ARKit uses this to
    /// judge distance; `automaticImageScaleEstimationEnabled` corrects it at runtime,
    /// but measuring a real sign and updating this improves the initial placement.
    static let physicalWidth: CGFloat = 0.35

    /// A region of the sign below (positive) or above (negative) the reference image,
    /// in multiples of the reference image's height, centred horizontally.
    struct Region {
        /// Distance of the region's top edge below the reference image's bottom edge.
        let top: Float
        /// Distance of the region's bottom edge below the reference image's bottom edge.
        let bottom: Float
        /// Region width as a multiple of the reference image width.
        let widthFactor: Float
    }

    /// The "Stop 271" line, with some margin for scale errors.
    static let stopNumberRegion = Region(top: -0.02, bottom: 0.42, widthFactor: 1.1)

    /// A generous fallback region (includes the stop name and route numbers, so
    /// only text preceded by "Stop" is accepted from it).
    static let widerRegion = Region(top: -0.1, bottom: 1.1, widthFactor: 1.5)

    static func makeReferenceImages() -> Set<ARReferenceImage> {
        guard let image = UIImage(named: referenceImageName)?.cgImage else {
            assertionFailure("Missing \(referenceImageName).png")
            return []
        }
        let reference = ARReferenceImage(image, orientation: .up, physicalWidth: physicalWidth)
        reference.name = referenceImageName
        return [reference]
    }
}

extension ARImageAnchor {
    /// The detected image's real size, taking ARKit's scale estimate into account.
    var estimatedPhysicalSize: SIMD2<Float> {
        let size = referenceImage.physicalSize
        let scale = Float(estimatedScaleFactor)
        return SIMD2(Float(size.width) * scale, Float(size.height) * scale)
    }

    /// Corners of `region` in the anchor's local space.
    ///
    /// In an image anchor's space the image lies in the x–z plane, +x pointing to the
    /// image's right and +z towards its bottom edge; +y is the image normal.
    func localCorners(of region: BusStopSign.Region) -> [SIMD3<Float>] {
        let size = estimatedPhysicalSize
        let halfWidth = size.x / 2 * region.widthFactor
        let top = size.y / 2 + region.top * size.y
        let bottom = size.y / 2 + region.bottom * size.y
        return [
            SIMD3(-halfWidth, 0, top),    // top-left
            SIMD3(halfWidth, 0, top),     // top-right
            SIMD3(halfWidth, 0, bottom),  // bottom-right
            SIMD3(-halfWidth, 0, bottom), // bottom-left
        ]
    }
}
