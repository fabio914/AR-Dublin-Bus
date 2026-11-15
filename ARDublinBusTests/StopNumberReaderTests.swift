import CoreImage
import CoreVideo
import Foundation
import Testing
import UIKit
@testable import ARDublinBus

/// Exercises perspective correction + Vision on real sign photos.
struct StopNumberReaderTests {
    /// Renders a CGImage into a BGRA pixel buffer, like an ARKit camera frame.
    static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer)
        let pixelBuffer = try #require(buffer)
        CIContext().render(CIImage(cgImage: image), to: pixelBuffer)
        return pixelBuffer
    }

    /// Synthetic sign: white "Stop 271" on green, drawn in perspective.
    @Test func readsSyntheticSkewedSign() throws {
        let size = CGSize(width: 1200, height: 900)
        let flat = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 120)).image { context in
            UIColor(red: 0, green: 0.4, blue: 0.33, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 120))
            ("Stop 271" as NSString).draw(at: CGPoint(x: 70, y: 10), withAttributes: [
                .font: UIFont.systemFont(ofSize: 88, weight: .bold), .foregroundColor: UIColor.white,
            ])
        }
        // Place it skewed into a larger grey frame.
        let quad = ImageQuad(topLeft: CGPoint(x: 300, y: 300), topRight: CGPoint(x: 900, y: 380),
                             bottomRight: CGPoint(x: 880, y: 520), bottomLeft: CGPoint(x: 320, y: 430))
        let skewed = CIImage(cgImage: try #require(flat.cgImage)).applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: CGPoint(x: quad.topLeft.x, y: size.height - quad.topLeft.y)),
            "inputTopRight": CIVector(cgPoint: CGPoint(x: quad.topRight.x, y: size.height - quad.topRight.y)),
            "inputBottomRight": CIVector(cgPoint: CGPoint(x: quad.bottomRight.x, y: size.height - quad.bottomRight.y)),
            "inputBottomLeft": CIVector(cgPoint: CGPoint(x: quad.bottomLeft.x, y: size.height - quad.bottomLeft.y)),
        ])
        let frame = skewed.composited(over: CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size)))
        let cgFrame = try #require(CIContext().createCGImage(frame, from: CGRect(origin: .zero, size: size)))

        let result = StopNumberReader().readStopNumber(from: try Self.pixelBuffer(from: cgFrame), quad: quad, requireKeyword: false)
        #expect(result.number == "271", "Recognised: \(result.text)")
    }

    /// OCR on a real photo of a stop flag. Set `TEST_RUNNER_SIGN_PHOTO` to the photo,
    /// `TEST_RUNNER_SIGN_QUAD` to the corners of the "Stop 1234" line in pixels
    /// ("tlx,tly,trx,try,brx,bry,blx,bly", top-left origin) and `TEST_RUNNER_SIGN_STOP`
    /// to the expected stop number.
    @Test(.enabled(if: ["SIGN_PHOTO", "SIGN_QUAD", "SIGN_STOP"].allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }))
    func readsRealPhoto() throws {
        let environment = ProcessInfo.processInfo.environment
        let image = try #require(UIImage(contentsOfFile: environment["SIGN_PHOTO"]!)?.cgImage)
        let values = environment["SIGN_QUAD"]!.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        try #require(values.count == 8, "SIGN_QUAD needs 8 numbers")
        let point = { (index: Int) in CGPoint(x: values[index], y: values[index + 1]) }
        let quad = ImageQuad(topLeft: point(0), topRight: point(2), bottomRight: point(4), bottomLeft: point(6))
        let result = StopNumberReader().readStopNumber(from: try Self.pixelBuffer(from: image), quad: quad, requireKeyword: false)
        print("Real photo OCR:", result.text)
        #expect(result.number == environment["SIGN_STOP"])
    }
}
