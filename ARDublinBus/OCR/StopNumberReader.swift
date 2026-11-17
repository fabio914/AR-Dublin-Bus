import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// Four corners of a region in image pixel coordinates (origin top-left),
/// named after the sign's own orientation.
struct ImageQuad: Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// Approximate height in pixels (average of the left and right edges).
    var height: CGFloat {
        (hypot(bottomLeft.x - topLeft.x, bottomLeft.y - topLeft.y)
            + hypot(bottomRight.x - topRight.x, bottomRight.y - topRight.y)) / 2
    }

    /// Approximate width in pixels (average of the top and bottom edges).
    var width: CGFloat {
        (hypot(topRight.x - topLeft.x, topRight.y - topLeft.y)
            + hypot(bottomRight.x - bottomLeft.x, bottomRight.y - bottomLeft.y)) / 2
    }

    var center: CGPoint {
        CGPoint(x: points.map(\.x).reduce(0, +) / 4, y: points.map(\.y).reduce(0, +) / 4)
    }

    func isInside(width: CGFloat, height: CGFloat) -> Bool {
        points.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x <= width && $0.y <= height }
    }
}

/// A "Stop 1234" label found anywhere in a camera frame by `StopNumberReader.findStopLabels`.
struct StopLabel: Sendable {
    let number: String
    /// The label as recognised, such as "Stop 350".
    let text: String
    /// The label's corners in the buffer's pixels (top-left origin), named as the text reads.
    let quad: ImageQuad
}

/// Reads text from a region of a camera frame: the region is first rectified
/// (perspective-corrected) so the text is upright and flat whatever the angle.
final class StopNumberReader: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])

    /// Crops and rectifies `quad` (pixel coordinates, top-left origin) out of `pixelBuffer`.
    func rectifiedImage(from pixelBuffer: CVPixelBuffer, quad: ImageQuad) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let height = image.extent.height

        // Core Image uses a bottom-left origin.
        func flip(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = flip(quad.topLeft)
        filter.topRight = flip(quad.topRight)
        filter.bottomRight = flip(quad.bottomRight)
        filter.bottomLeft = flip(quad.bottomLeft)

        guard var output = filter.outputImage, output.extent.width >= 8, output.extent.height >= 8 else { return nil }

        // Small crops are upscaled; Vision is more reliable with text at least ~30 px tall.
        let minimumHeight: CGFloat = 160
        if output.extent.height < minimumHeight {
            let scale = minimumHeight / output.extent.height
            output = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.createCGImage(output, from: output.extent.integral)
    }

    /// Recognised text lines (up to three candidates each) in `image`.
    func recognizeText(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-GB", "en-US"]

        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).flatMap { observation in
            observation.topCandidates(3).map(\.string)
        }
    }

    /// Finds "Stop 1234" labels anywhere in `pixelBuffer`, without knowing where the sign is.
    ///
    /// - Parameter orientation: how the buffer is turned relative to upright, so Vision can read
    ///   the text (ARKit's camera image is `.right` while the phone is held upright).
    func findStopLabels(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) throws -> [StopLabel] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate // the fast level misses labels at night
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-GB", "en-US"]
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation).perform([request])

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return (request.results ?? []).compactMap { observation in
            for candidate in observation.topCandidates(3) {
                guard let label = StopNumberParser.label(in: candidate.string),
                      let box = try? candidate.boundingBox(for: label.range) else { continue }
                let point = { Self.bufferPoint(fromNormalized: $0, orientation: orientation, bufferSize: size) }
                return StopLabel(
                    number: label.number,
                    text: String(candidate.string[label.range]),
                    quad: ImageQuad(topLeft: point(box.topLeft), topRight: point(box.topRight),
                                    bottomRight: point(box.bottomRight), bottomLeft: point(box.bottomLeft))
                )
            }
            return nil
        }
    }

    /// Converts a point from Vision's normalised coordinates (of the upright image, bottom-left
    /// origin) to pixels of the buffer as stored (top-left origin).
    static func bufferPoint(fromNormalized point: CGPoint, orientation: CGImagePropertyOrientation, bufferSize size: CGSize) -> CGPoint {
        let (x, y) = (point.x, point.y)
        return switch orientation {
        // Stored turned 90° anticlockwise: upright = buffer turned clockwise.
        case .right: CGPoint(x: (1 - y) * size.width, y: (1 - x) * size.height)
        // Stored turned 90° clockwise.
        case .left: CGPoint(x: y * size.width, y: x * size.height)
        case .down: CGPoint(x: (1 - x) * size.width, y: y * size.height)
        default: CGPoint(x: x * size.width, y: (1 - y) * size.height)
        }
    }

    /// Convenience: rectify, recognise, and parse a stop number.
    func readStopNumber(from pixelBuffer: CVPixelBuffer, quad: ImageQuad, requireKeyword: Bool) -> (number: String?, text: [String]) {
        guard let image = rectifiedImage(from: pixelBuffer, quad: quad),
              let text = try? recognizeText(in: image) else { return (nil, []) }
        return (StopNumberParser.stopNumber(in: text, requireKeyword: requireKeyword), text)
    }
}
