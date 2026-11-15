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

    func isInside(width: CGFloat, height: CGFloat) -> Bool {
        points.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x <= width && $0.y <= height }
    }
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

    /// Convenience: rectify, recognise, and parse a stop number.
    func readStopNumber(from pixelBuffer: CVPixelBuffer, quad: ImageQuad, requireKeyword: Bool) -> (number: String?, text: [String]) {
        guard let image = rectifiedImage(from: pixelBuffer, quad: quad),
              let text = try? recognizeText(in: image) else { return (nil, []) }
        return (StopNumberParser.stopNumber(in: text, requireKeyword: requireKeyword), text)
    }
}
