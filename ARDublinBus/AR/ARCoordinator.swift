import ARKit
import RealityKit
import UIKit

/// Runs the AR session: finds bus stop signs, reads their stop number, and keeps a departures
/// panel anchored to the sign. Nearby stops are shown as floating labels by `ARStopsController`.
///
/// A sign is found in two ways:
/// - ARKit detects the bus pictogram (`BusStopSign`), and the "Stop 1234" line under it is read.
/// - The whole camera frame is searched for a "Stop 1234" label, and the sign is placed from the
///   label's position and size (`SignLayout`). This works further away, at night and at steeper
///   angles than ARKit's image detection. If ARKit finds the pictogram later, its anchor takes
///   over, keeping the stop.
///
/// The session uses geo tracking (`ARGeoTrackingConfiguration`) where Apple supports it,
/// and world tracking aligned with gravity and the compass everywhere else.
@MainActor
final class ARCoordinator: NSObject, ARSessionDelegate {
    private let model: AppModel
    private weak var arView: ARView?
    private let reader = StopNumberReader()

    private var sign: TrackedSign?
    private var consensus = ReadingConsensus(required: 2)
    private var isReading = false
    private var lastReadAttempt: TimeInterval = 0
    private var failedReads = 0

    private var stopsController: ARStopsController?
    /// The session runs `ARGeoTrackingConfiguration`.
    private var usesGeoTracking = false
    /// Geo tracking failed this run: stay on world tracking.
    private var geoTrackingFailed = false
    /// Geo tracking became available while a sign was tracked; switch once it's gone.
    private var pendingGeoSwitch = false
    /// The compass or location can't be used (location access denied, say): the session is
    /// aligned with gravity only. Signs still work; nearby stops can't be placed.
    private var headingUnavailable = false
    /// A sheet covers the camera view: the session, OCR and location updates are stopped.
    private var isPaused = false

    /// Seconds between OCR attempts while the stop number is unknown.
    private let readInterval: TimeInterval = 0.35
    /// Seconds between whole-frame searches for a "Stop 1234" label while no sign is known.
    private let labelSearchInterval: TimeInterval = 0.7
    /// The same, once a sign has been placed from a label: watching for a different stop.
    private let labelWatchInterval: TimeInterval = 2
    private var lastLabelSearch: TimeInterval = 0
    /// A pictogram this close to a sign placed from its label is the same sign.
    private let sameSignDistance: Float = 1.5
    /// If the anchor jumps further than this, it's a different sign.
    private let newSignDistance: Float = 2.5

    @MainActor
    private final class TrackedSign {
        /// The `ARImageAnchor`'s identifier, or a new one for a sign placed from its label.
        let anchorID: UUID
        /// Detected by ARKit (it follows the image), rather than placed from a "Stop" label.
        let isImageAnchored: Bool
        /// Fixed in the world, so the card stays put and visible when the sign is out of view.
        /// (Content attached to an image anchor may be hidden while ARKit isn't tracking the image.)
        let anchorEntity = AnchorEntity(world: matrix_identity_float4x4)
        /// The sign's reference image, in the axes of an image anchor (x right, y out of the
        /// sign, z down the sign). Moved to follow ARKit while it tracks the image.
        let root = Entity()
        let panel: DeparturesPanelEntity
        let highlight: ModelEntity
        var stopCode: String?
        var recognisedAt: SIMD3<Float>?
        /// The reference image's size on this sign, in metres.
        var size: SIMD2<Float>
        var firstSeen = Date()

        init(anchorID: UUID, isImageAnchored: Bool, transform: simd_float4x4, size: SIMD2<Float>) {
            self.anchorID = anchorID
            self.isImageAnchored = isImageAnchored
            self.size = size
            anchorEntity.addChild(root)

            // A translucent overlay on the pictogram confirms the detection.
            var material = UnlitMaterial(color: UIColor(red: 1, green: 0.82, blue: 0, alpha: 1))
            material.blending = .transparent(opacity: .init(floatLiteral: 0.25))
            highlight = ModelEntity(mesh: Self.highlightMesh(size), materials: [material])
            highlight.position.y = 0.002
            root.addChild(highlight)

            panel = DeparturesPanelEntity()
            root.addChild(panel)
            place(transform)
        }

        /// Moves the sign to `transform` (world space, in the axes of an image anchor).
        func place(_ transform: simd_float4x4) {
            root.setTransformMatrix(transform, relativeTo: nil)
        }

        static func highlightMesh(_ size: SIMD2<Float>) -> MeshResource {
            .generatePlane(width: size.x, depth: size.y, cornerRadius: size.x * 0.04)
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        model.onPanelContentChange = { [weak self] content in
            self?.sign?.panel.render(content)
            self?.layoutPanel()
        }
    }

    func attach(to arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        arView.renderOptions.insert(.disableMotionBlur)

        let stopsController = ARStopsController(arView: arView, service: model.service)
        stopsController.onStatusChange = { [weak self] status in self?.model.arStopsStatus = status }
        stopsController.onGeoTrackingAvailable = { [weak self] in self?.switchToGeoTracking() }
        self.stopsController = stopsController
        model.onShowsARStopsChange = { [weak self] enabled in
            // While paused, the setting is applied when the session resumes.
            guard let self, !self.isPaused else { return }
            self.stopsController?.setEnabled(enabled)
        }
        arView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))

        startSession()
        stopsController.setEnabled(model.showsARStops)
    }

    func startSession() {
        guard ARWorldTrackingConfiguration.isSupported else {
            model.trackingStatus = .unsupported
            return
        }
        let configuration: ARConfiguration
        if usesGeoTracking {
            let geo = ARGeoTrackingConfiguration()
            geo.detectionImages = BusStopSign.makeReferenceImages()
            geo.maximumNumberOfTrackedImages = 1
            geo.automaticImageScaleEstimationEnabled = true
            configuration = geo
        } else {
            let world = ARWorldTrackingConfiguration()
            // x east, y up, z south: lets stops be placed from GPS and the compass.
            world.worldAlignment = headingUnavailable ? .gravity : .gravityAndHeading
            world.detectionImages = BusStopSign.makeReferenceImages()
            world.maximumNumberOfTrackedImages = 1
            world.automaticImageScaleEstimationEnabled = true
            configuration = world
        }

        removeSign()
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        stopsController?.sessionDidRestart(usesGeoTracking: usesGeoTracking, hasHeading: usesGeoTracking || !headingUnavailable)
        model.signLost() // back to searching
    }

    /// Restarts the session with geo tracking, unless a sign is being tracked right now.
    private func switchToGeoTracking() {
        guard !usesGeoTracking, !geoTrackingFailed else { return }
        guard sign == nil else {
            pendingGeoSwitch = true
            return
        }
        pendingGeoSwitch = false
        usesGeoTracking = true
        startSession()
    }

    private func fallBackToWorldTracking() {
        guard usesGeoTracking else { return }
        geoTrackingFailed = true
        usesGeoTracking = false
        startSession()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let arView, let stopsController else { return }
        let point = recognizer.location(in: arView)
        for entity in arView.entities(at: point) {
            if let stop = stopsController.stop(for: entity) {
                model.selectedARStop = stop
                return
            }
        }
    }

    func stop() {
        arView?.session.pause()
    }

    /// Stops the camera, tracking and location updates while the AR view is covered, and
    /// starts them again afterwards.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            arView?.session.pause()
            removeSign()
            model.signLost()
            stopsController?.setEnabled(false)
        } else {
            startSession()
            stopsController?.setEnabled(model.showsARStops)
        }
    }

    // MARK: - ARSessionDelegate (delivered on the main queue)

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        let imageAnchors = anchors.compactMap { $0 as? ARImageAnchor }
        guard !imageAnchors.isEmpty else { return }
        MainActor.assumeIsolated {
            imageAnchors.forEach(self.handleDetected)
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        let imageAnchors = anchors.compactMap { $0 as? ARImageAnchor }
        guard !imageAnchors.isEmpty else { return }
        MainActor.assumeIsolated {
            imageAnchors.forEach(self.handleUpdated)
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        let ids = anchors.map(\.identifier)
        MainActor.assumeIsolated {
            if let sign = self.sign, ids.contains(sign.anchorID) {
                self.removeSign()
                self.model.signLost()
            }
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated {
            self.handleFrame(frame)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        let code = (error as? ARError)?.code
        // What ARKit reports when it can't get the compass heading or the user's location.
        let isHeadingFailure = code == .sensorFailed || code == .sensorUnavailable || code == .locationUnauthorized
        MainActor.assumeIsolated {
            if self.usesGeoTracking {
                self.fallBackToWorldTracking()
            } else if isHeadingFailure, !self.headingUnavailable {
                // Reading signs doesn't need the compass: carry on without it.
                self.headingUnavailable = true
                self.startSession()
            } else {
                self.model.trackingStatus = .failed(message)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didChange geoTrackingStatus: ARGeoTrackingStatus) {
        MainActor.assumeIsolated {
            guard self.usesGeoTracking else { return }
            switch (geoTrackingStatus.state, geoTrackingStatus.stateReason) {
            case (.notAvailable, .notAvailableAtLocation), (.notAvailable, .needLocationPermissions):
                self.fallBackToWorldTracking()
            default:
                self.stopsController?.geoTrackingStatusChanged(geoTrackingStatus)
            }
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated {
            guard !self.isPaused else { return }
            self.startSession()
        }
    }

    // MARK: - Anchors

    private func handleDetected(_ anchor: ARImageAnchor) {
        guard anchor.referenceImage.name == BusStopSign.referenceImageName, let arView else { return }
        if sign?.anchorID == anchor.identifier { return }

        // The pictogram of a sign already placed from its label: keep its stop.
        let position = anchor.transform.translation
        var carriedStopCode: String?
        if let sign, !sign.isImageAnchored, let code = sign.stopCode, let at = sign.recognisedAt,
           simd_distance(at, position) < sameSignDistance {
            carriedStopCode = code
        }
        removeSign()

        let newSign = TrackedSign(anchorID: anchor.identifier, isImageAnchored: true, transform: anchor.transform,
                                  size: anchor.estimatedPhysicalSize)
        arView.scene.addAnchor(newSign.anchorEntity)
        sign = newSign
        consensus.reset()
        failedReads = 0

        if let carriedStopCode {
            newSign.stopCode = carriedStopCode
            newSign.recognisedAt = position
            stopsController?.signRecognised(stopCode: carriedStopCode, at: position)
        } else {
            model.signDetected()
        }
        newSign.panel.render(model.panelContent)
        layoutPanel()
    }

    private func handleUpdated(_ anchor: ARImageAnchor) {
        guard let sign, sign.anchorID == anchor.identifier else {
            handleDetected(anchor)
            return
        }

        // ARKit reuses the anchor when the same pictogram is found elsewhere: a big jump means a new sign.
        let position = anchor.transform.translation
        if let recognisedAt = sign.recognisedAt, simd_distance(position, recognisedAt) > newSignDistance {
            stopsController?.signLost()
            sign.stopCode = nil
            sign.recognisedAt = nil
            sign.firstSeen = Date()
            consensus.reset()
            failedReads = 0
            model.signDetected()
        }

        // Follow the image while ARKit sees it; otherwise the sign stays where it was last seen.
        if anchor.isTracked { sign.place(anchor.transform) }

        // Follow ARKit's scale estimate, without rebuilding the mesh on every tiny change.
        let size = anchor.estimatedPhysicalSize
        if abs(size.x - sign.size.x) > sign.size.x * 0.02 {
            sign.size = size
            sign.highlight.model?.mesh = TrackedSign.highlightMesh(size)
        }
        layoutPanel()
    }

    /// Places a sign found from its "Stop 1234" label, already knowing its stop.
    private func placeSign(_ transform: simd_float4x4, stopCode: String) {
        guard let arView else { return }
        removeSign()

        let newSign = TrackedSign(anchorID: UUID(), isImageAnchored: false, transform: transform,
                                  size: SignLayout.referenceSize)
        arView.scene.addAnchor(newSign.anchorEntity)
        sign = newSign
        consensus.reset()
        failedReads = 0

        let position = transform.translation
        newSign.stopCode = stopCode
        newSign.recognisedAt = position
        model.activate(stopCode: stopCode)
        newSign.panel.render(model.panelContent)
        layoutPanel()
        stopsController?.signRecognised(stopCode: stopCode, at: position)
    }

    /// Hangs the card below the sign, slightly in front of it (`SignLayout.cardCenter`). It lies
    /// in the sign's plane, so it's seen at an angle like the sign itself.
    private func layoutPanel() {
        guard let sign else { return }
        sign.panel.position = SignLayout.cardCenter(referenceSize: sign.size, cardHeight: sign.panel.worldHeight)
        sign.panel.orientation = DeparturesPanelEntity.onSign
    }

    private func removeSign() {
        sign?.anchorEntity.removeFromParent()
        sign = nil
        isReading = false
        stopsController?.signLost()
    }

    // MARK: - Frames & OCR

    private func handleFrame(_ frame: ARFrame) {
        stopsController?.update(frame: frame)
        if pendingGeoSwitch, sign == nil { switchToGeoTracking() }

        guard let sign else {
            searchForLabels(in: frame, interval: labelSearchInterval)
            return
        }

        // Placed from a label: ARKit isn't following it, so keep an eye out for a different stop.
        guard sign.isImageAnchored else {
            searchForLabels(in: frame, interval: labelWatchInterval)
            return
        }

        guard sign.stopCode == nil,
              let anchor = frame.anchors.first(where: { $0.identifier == sign.anchorID }) as? ARImageAnchor,
              anchor.isTracked,
              !isReading,
              frame.timestamp - lastReadAttempt >= readInterval else { return }

        if Date().timeIntervalSince(sign.firstSeen) > 6 { model.readingIsSlow() }

        // Mostly read the region under the pictogram; every third try, search the whole frame.
        if failedReads % 3 == 2 {
            lastReadAttempt = frame.timestamp
            searchForLabels(in: frame, interval: 0)
            return
        }
        guard let quad = projectedQuad(BusStopSign.stopNumberRegion, of: anchor, in: frame) else { return }
        // Too small to read reliably.
        guard quad.height >= 18 else { return }

        lastReadAttempt = frame.timestamp
        isReading = true

        let anchorID = sign.anchorID
        let anchorPosition = anchor.transform.translation
        let pixelBuffer = PixelBufferBox(frame.capturedImage)
        let reader = self.reader

        Task.detached(priority: .userInitiated) {
            let result = reader.readStopNumber(from: pixelBuffer.buffer, quad: quad, requireKeyword: false)
            await MainActor.run {
                self.handleReading(result.number, anchorID: anchorID, anchorPosition: anchorPosition)
            }
        }
    }

    private func handleReading(_ number: String?, anchorID: UUID, anchorPosition: SIMD3<Float>) {
        isReading = false
        guard let sign, sign.anchorID == anchorID, sign.stopCode == nil else { return }

        guard let number, model.knownStopCodes?.contains(number) ?? true else {
            failedReads += 1
            return
        }
        guard let accepted = recordReading(number) else { return }
        accept(accepted, for: sign, at: anchorPosition)
    }

    /// Counts a reading; returns it once it has been seen often enough to trust.
    private func recordReading(_ number: String) -> String? {
        // Before the timetable is loaded readings can't be validated, so require more agreement.
        consensus.required = model.knownStopCodes == nil ? 3 : 2
        return consensus.record(number)
    }

    private func accept(_ stopCode: String, for sign: TrackedSign, at position: SIMD3<Float>) {
        sign.stopCode = stopCode
        sign.recognisedAt = position
        model.activate(stopCode: stopCode)
        stopsController?.signRecognised(stopCode: stopCode, at: position)
    }

    // MARK: - Whole-frame label search

    /// The camera at the moment a frame was captured, to place what's found in it later.
    private struct CameraCapture {
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
    }

    /// Looks for "Stop 1234" labels anywhere in the frame, at most every `interval` seconds.
    private func searchForLabels(in frame: ARFrame, interval: TimeInterval) {
        guard !isReading, frame.timestamp - lastLabelSearch >= interval else { return }
        // Placing a sign needs a reliable camera pose.
        guard case .normal = frame.camera.trackingState else { return }
        lastLabelSearch = frame.timestamp
        isReading = true

        let capture = CameraCapture(transform: frame.camera.transform, intrinsics: frame.camera.intrinsics)
        let pixelBuffer = PixelBufferBox(frame.capturedImage)
        let reader = self.reader
        Task.detached(priority: .userInitiated) {
            // The camera image is landscape; the phone is held upright.
            let labels = (try? reader.findStopLabels(in: pixelBuffer.buffer, orientation: .right)) ?? []
            await MainActor.run {
                self.handleLabels(labels, capture: capture)
            }
        }
    }

    private func handleLabels(_ labels: [StopLabel], capture: CameraCapture) {
        isReading = false
        // Known stops only, nearest (largest) first.
        let label = labels
            .filter { model.knownStopCodes?.contains($0.number) ?? true }
            .max { $0.quad.width < $1.quad.width }

        // A detected pictogram whose own region couldn't be read: the label is its stop number.
        if let sign, sign.isImageAnchored {
            guard sign.stopCode == nil else { return }
            guard let label else {
                failedReads += 1
                return
            }
            if let accepted = recordReading(label.number) {
                accept(accepted, for: sign, at: sign.root.position(relativeTo: nil))
            }
            return
        }

        guard let label,
              let transform = SignLayout.signTransform(label: label, cameraTransform: capture.transform,
                                                       intrinsics: capture.intrinsics) else { return }
        // The sign already placed from this label, or a misreading of it.
        if let sign, let at = sign.recognisedAt, simd_distance(at, transform.translation) < newSignDistance { return }
        guard let accepted = recordReading(label.number) else { return }
        placeSign(transform, stopCode: accepted)
    }

    /// Projects a sign region into the camera image (pixel coordinates of `capturedImage`).
    private func projectedQuad(_ region: BusStopSign.Region, of anchor: ARImageAnchor, in frame: ARFrame) -> ImageQuad? {
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(frame.capturedImage),
            height: CVPixelBufferGetHeight(frame.capturedImage)
        )
        let viewMatrix = frame.camera.transform.inverse

        var points: [CGPoint] = []
        for local in anchor.localCorners(of: region) {
            let world = anchor.transform * SIMD4(local, 1)
            // Must be in front of the camera (camera looks down -z).
            guard (viewMatrix * world).z < 0 else { return nil }
            // `capturedImage` is in the sensor's native landscape-right orientation.
            points.append(frame.camera.projectPoint(
                SIMD3(world.x, world.y, world.z),
                orientation: .landscapeRight,
                viewportSize: imageSize
            ))
        }

        let quad = ImageQuad(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
        return quad.isInside(width: imageSize.width, height: imageSize.height) ? quad : nil
    }
}

/// Lets a camera pixel buffer cross into the OCR task. ARKit hands out a new buffer
/// per frame and never mutates a delivered one, so sharing it read-only is safe.
private struct PixelBufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

extension simd_float4x4 {
    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}
