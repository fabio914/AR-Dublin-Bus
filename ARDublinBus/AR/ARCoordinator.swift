import ARKit
import RealityKit
import UIKit

/// Runs the AR session: detects the bus pictogram, reads the stop number under it,
/// and keeps a departures panel anchored to the sign. Nearby stops are shown as floating
/// labels by `ARStopsController`.
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

    /// Seconds between OCR attempts while the stop number is unknown.
    private let readInterval: TimeInterval = 0.35
    /// If the anchor jumps further than this, it's a different sign.
    private let newSignDistance: Float = 2.5

    private final class TrackedSign {
        let anchorID: UUID
        let anchorEntity: AnchorEntity
        let panel: DeparturesPanelEntity
        let highlight: ModelEntity
        var stopCode: String?
        var recognisedAt: SIMD3<Float>?
        var highlightSize: SIMD2<Float> = .zero
        var firstSeen = Date()

        init(anchorID: UUID, anchorEntity: AnchorEntity, panel: DeparturesPanelEntity, highlight: ModelEntity) {
            self.anchorID = anchorID
            self.anchorEntity = anchorEntity
            self.panel = panel
            self.highlight = highlight
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
        model.onShowsARStopsChange = { [weak stopsController] enabled in stopsController?.setEnabled(enabled) }
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
            self.startSession()
        }
    }

    // MARK: - Anchors

    private func handleDetected(_ anchor: ARImageAnchor) {
        guard anchor.referenceImage.name == BusStopSign.referenceImageName, let arView else { return }
        if sign?.anchorID == anchor.identifier { return }
        removeSign()

        let anchorEntity = AnchorEntity(anchor: anchor)

        // A translucent overlay on the pictogram confirms the detection.
        let size = anchor.estimatedPhysicalSize
        var highlightMaterial = UnlitMaterial(color: UIColor(red: 1, green: 0.82, blue: 0, alpha: 1))
        highlightMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.25))
        let highlight = ModelEntity(
            mesh: .generatePlane(width: size.x, depth: size.y, cornerRadius: size.x * 0.04),
            materials: [highlightMaterial]
        )
        highlight.position.y = 0.002
        anchorEntity.addChild(highlight)

        let panel = DeparturesPanelEntity()
        anchorEntity.addChild(panel)
        arView.scene.addAnchor(anchorEntity)

        sign = TrackedSign(anchorID: anchor.identifier, anchorEntity: anchorEntity, panel: panel, highlight: highlight)
        sign?.highlightSize = size
        consensus.reset()
        failedReads = 0
        model.signDetected()
        panel.render(model.panelContent)
        layoutPanel(for: anchor)
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

        // Follow ARKit's scale estimate, without rebuilding the mesh on every tiny change.
        let size = anchor.estimatedPhysicalSize
        if abs(size.x - sign.highlightSize.x) > sign.highlightSize.x * 0.02 {
            sign.highlightSize = size
            sign.highlight.model?.mesh = .generatePlane(width: size.x, depth: size.y, cornerRadius: size.x * 0.04)
        }
        layoutPanel(for: anchor)
    }

    private func layoutPanel(for anchor: ARImageAnchor? = nil) {
        guard let sign else { return }
        let imageAnchor = anchor ?? arView?.session.currentFrame?.anchors
            .first { $0.identifier == sign.anchorID } as? ARImageAnchor
        guard let imageAnchor else { return }

        // Hang the panel just in front of the sign, below the pictogram, over the route list.
        let size = imageAnchor.estimatedPhysicalSize
        let gap: Float = 0.03
        sign.panel.position = SIMD3(0, 0.06, size.y / 2 + gap + sign.panel.worldHeight / 2)
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

        guard let sign else { return }
        sign.panel.face(cameraPosition: frame.camera.transform.translation)

        guard sign.stopCode == nil,
              let anchor = frame.anchors.first(where: { $0.identifier == sign.anchorID }) as? ARImageAnchor,
              anchor.isTracked,
              !isReading,
              frame.timestamp - lastReadAttempt >= readInterval else { return }

        if Date().timeIntervalSince(sign.firstSeen) > 6 { model.readingIsSlow() }

        // Mostly read the tight region under the pictogram; every third try, a wider one.
        let useWideRegion = failedReads % 3 == 2
        let region = useWideRegion ? BusStopSign.widerRegion : BusStopSign.stopNumberRegion
        guard let quad = projectedQuad(region, of: anchor, in: frame) else { return }
        // Too small to read reliably.
        guard quad.height >= 18 else { return }

        lastReadAttempt = frame.timestamp
        isReading = true

        let anchorID = sign.anchorID
        let anchorPosition = anchor.transform.translation
        let pixelBuffer = PixelBufferBox(frame.capturedImage)
        let reader = self.reader

        Task.detached(priority: .userInitiated) {
            let result = reader.readStopNumber(from: pixelBuffer.buffer, quad: quad, requireKeyword: useWideRegion)
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

        // Before the timetable is loaded readings can't be validated, so require more agreement.
        consensus.required = model.knownStopCodes == nil ? 3 : 2
        guard let accepted = consensus.record(number) else { return }

        sign.stopCode = accepted
        sign.recognisedAt = anchorPosition
        model.activate(stopCode: accepted)
        stopsController?.signRecognised(stopCode: accepted, at: anchorPosition)
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
