import ARKit
import UIKit

/// The images ARKit looks for on bus stop signs, and where the stop number is relative to them.
///
/// Neither the NTA nor Dublin Bus publishes the artwork, so both images were cut from photos and
/// perspective-corrected:
/// - `BusStopIcon.png`: the top of the green panel on a TFI flag, the white bus pictogram edge
///   to edge across the panel. The round green signs show the same pictogram, so it finds them
///   too; which of the two it is, is told from the text under it.
/// - `DublinBusLogo.png`: the Dublin Bus logo and "BUS" on the older round yellow sign,
///   cleaned up to two colours. "STOP NO." and the number are below it.
enum BusStopSign {
    static let flagImageName = "BusStopIcon"
    static let dublinBusImageName = "DublinBusLogo"

    /// The kind of sign a reference image is first taken to be on. A flag's pictogram may turn
    /// out to be on a round green sign.
    static func kind(ofReferenceImage name: String?) -> SignKind? {
        switch name {
        case flagImageName: .flag
        case dublinBusImageName: .yellowDisc
        default: nil
        }
    }

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

    /// The stop number's lines, with some margin for scale errors.
    static func stopNumberRegion(for kind: SignKind) -> Region {
        switch kind {
        // "Stop 271": about 0.01–0.25 of the reference image's height below it.
        case .flag: Region(top: -0.02, bottom: 0.42, widthFactor: 1.1)
        // "Stop" and the number: -0.02–0.56, in the middle 40% of the (wide) flag image.
        case .greenDisc: Region(top: -0.1, bottom: 0.65, widthFactor: 0.6)
        // "STOP NO." and the number: -0.01–0.34, in the middle 70% of the logo image.
        case .yellowDisc: Region(top: -0.05, bottom: 0.45, widthFactor: 0.9)
        }
    }

    static func makeReferenceImages() -> Set<ARReferenceImage> {
        let images: [(name: String, kind: SignKind)] = [(flagImageName, .flag), (dublinBusImageName, .yellowDisc)]
        return Set(images.compactMap { name, kind in
            guard let image = UIImage(named: name)?.cgImage else {
                assertionFailure("Missing \(name).png")
                return nil
            }
            // ARKit uses the printed width to judge distance; `automaticImageScaleEstimationEnabled`
            // refines it at runtime.
            let width = CGFloat(SignLayout.geometry(of: kind).referenceSize.x)
            let reference = ARReferenceImage(image, orientation: .up, physicalWidth: width)
            reference.name = name
            return reference
        })
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
