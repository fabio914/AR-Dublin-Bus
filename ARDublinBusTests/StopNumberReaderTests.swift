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

    /// Vision's upright, normalised corners map back to the buffer's own pixels.
    @Test func mapsUprightPointsToBufferPixels() {
        let landscape = CGSize(width: 1920, height: 1440)
        // `.right`: the buffer is the upright image turned 90° anticlockwise, so the upright
        // image's top-left (normalised (0, 1)) is the buffer's bottom-left.
        func right(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            StopNumberReader.bufferPoint(fromNormalized: CGPoint(x: x, y: y), orientation: .right, bufferSize: landscape)
        }
        #expect(right(0, 1) == CGPoint(x: 0, y: 1440))     // upright top-left
        #expect(right(1, 1) == CGPoint(x: 0, y: 0))        // upright top-right
        #expect(right(1, 0) == CGPoint(x: 1920, y: 0))     // upright bottom-right
        #expect(right(0.5, 0.5) == CGPoint(x: 960, y: 720))

        let upright = CGSize(width: 1440, height: 1920)
        #expect(StopNumberReader.bufferPoint(fromNormalized: CGPoint(x: 0, y: 1), orientation: .up, bufferSize: upright) == .zero)
        #expect(StopNumberReader.bufferPoint(fromNormalized: CGPoint(x: 1, y: 0), orientation: .up, bufferSize: upright)
                == CGPoint(x: 1440, y: 1920))
        // `.left` and `.down` undo the opposite turns.
        #expect(StopNumberReader.bufferPoint(fromNormalized: CGPoint(x: 0, y: 1), orientation: .left, bufferSize: landscape)
                == CGPoint(x: 1920, y: 0))
        #expect(StopNumberReader.bufferPoint(fromNormalized: CGPoint(x: 0, y: 1), orientation: .down, bufferSize: upright)
                == CGPoint(x: 1440, y: 1920))
    }

    /// The whole-frame search in a sideways buffer, like ARKit's camera image with the phone upright.
    @Test func findsStopLabelInSidewaysFrame() throws {
        // Upright 1440 × 1920 frame with a sign in the upper middle.
        let upright = UIGraphicsImageRenderer(size: CGSize(width: 1440, height: 1920), format: .init(for: .init(displayScale: 1))).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1440, height: 1920))
            UIColor(red: 0, green: 0.4, blue: 0.33, alpha: 1).setFill()
            context.fill(CGRect(x: 520, y: 600, width: 400, height: 300))
            ("Stop 271" as NSString).draw(at: CGPoint(x: 560, y: 800), withAttributes: [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: UIColor.white,
            ])
            ("15a | 44 | 122" as NSString).draw(at: CGPoint(x: 560, y: 960), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48, weight: .bold), .foregroundColor: UIColor.black,
            ])
        }
        // Stored turned 90° anticlockwise: 1920 × 1440.
        let sideways = CIImage(cgImage: try #require(upright.cgImage)).oriented(.left)
        let moved = sideways.transformed(by: CGAffineTransform(translationX: -sideways.extent.minX, y: -sideways.extent.minY))
        let image = try #require(CIContext().createCGImage(moved, from: moved.extent))
        #expect(image.width == 1920)

        let labels = try StopNumberReader().findStopLabels(in: try Self.pixelBuffer(from: image), orientation: .right)
        let label = try #require(labels.first)
        #expect(labels.count == 1) // route numbers aren't labels
        #expect(label.number == "271")
        #expect(label.text == "Stop 271")
        // The label's centre, around (670, 835) upright, is at (835, 1440 - 670) in the buffer.
        #expect(abs(label.quad.center.x - 835) < 25)
        #expect(abs(label.quad.center.y - 770) < 40)
        // Read along the text, it's wider than tall, whichever way the buffer is stored.
        #expect(label.quad.width > label.quad.height * 3)
    }

    /// Round signs: the number on its own line under "Stop" or "STOP NO.", in a sideways frame.
    @Test(arguments: [("Stop", SignKind.greenDisc), ("STOP NO.", .yellowDisc)])
    func findsTwoLineLabels(keyword: String, kind: SignKind) throws {
        let upright = UIGraphicsImageRenderer(size: CGSize(width: 1440, height: 1920), format: .init(for: .init(displayScale: 1))).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1440, height: 1920))
            UIColor(red: 0.4, green: 0.75, blue: 0.4, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 470, y: 500, width: 500, height: 500))
            UIColor(white: 0.97, alpha: 1).setFill()
            context.fill(CGRect(x: 640, y: 560, width: 160, height: 150)) // a stand-in for the pictogram
            let font = UIFont.systemFont(ofSize: 80, weight: .bold)
            for (text, top) in [(keyword, 720.0), ("2383", 810.0)] {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
                let width = (text as NSString).size(withAttributes: attributes).width
                (text as NSString).draw(at: CGPoint(x: 720 - width / 2, y: top), withAttributes: attributes)
            }
            // Route numbers well below the sign aren't its number.
            ("46a" as NSString).draw(at: CGPoint(x: 660, y: 1300), withAttributes: [
                .font: font, .foregroundColor: UIColor.black,
            ])
        }
        let sideways = CIImage(cgImage: try #require(upright.cgImage)).oriented(.left)
        let moved = sideways.transformed(by: CGAffineTransform(translationX: -sideways.extent.minX, y: -sideways.extent.minY))
        let image = try #require(CIContext().createCGImage(moved, from: moved.extent))

        let labels = try StopNumberReader().findStopLabels(in: try Self.pixelBuffer(from: image), orientation: .right)
        let label = try #require(labels.first, "Found: \(labels.map(\.text))")
        #expect(labels.count == 1)
        #expect(label.number == "2383")
        #expect(label.text == "2383")
        #expect(label.kind == kind)
        // The number line's centre, around (720, 860) upright, is at (860, 1440 - 720) in the buffer.
        #expect(abs(label.quad.center.x - 860) < 30)
        #expect(abs(label.quad.center.y - 720) < 40)
        #expect(label.quad.width > label.quad.height * 1.5)
    }

    @Test func pairsANumberOnlyWithTheLineAboveIt() {
        let keyword = CGRect(x: 0.40, y: 0.50, width: 0.10, height: 0.05)
        #expect(StopNumberReader.isNumberLine(CGRect(x: 0.39, y: 0.46, width: 0.12, height: 0.05), below: keyword))
        #expect(!StopNumberReader.isNumberLine(CGRect(x: 0.39, y: 0.30, width: 0.12, height: 0.05), below: keyword)) // far below
        #expect(!StopNumberReader.isNumberLine(CGRect(x: 0.52, y: 0.50, width: 0.06, height: 0.05), below: keyword)) // beside it
        #expect(!StopNumberReader.isNumberLine(CGRect(x: 0.39, y: 0.54, width: 0.12, height: 0.05), below: keyword)) // above
    }

    /// The whole-frame search on a real photo: set `TEST_RUNNER_SIGN_PHOTO` and `TEST_RUNNER_SIGN_STOP`.
    @Test(.enabled(if: ["SIGN_PHOTO", "SIGN_STOP"].allSatisfy { ProcessInfo.processInfo.environment[$0] != nil }))
    func findsStopLabelInRealPhoto() throws {
        let environment = ProcessInfo.processInfo.environment
        let image = try #require(UIImage(contentsOfFile: environment["SIGN_PHOTO"]!)?.cgImage)
        let labels = try StopNumberReader().findStopLabels(in: try Self.pixelBuffer(from: image), orientation: .up)
        print("Real photo labels:", labels.map { "\($0.text) (\($0.kind))" })
        #expect(labels.map(\.number).contains(environment["SIGN_STOP"]!))
    }
}
