import ARKit
import RealityKit
import UIKit

/// Runs the AR session: finds bus stop signs, reads their stop number, and unfolds a departures
/// card under the sign. Nearby stops are shown as pins by `ARStopsController`.
///
/// A sign is found in two ways:
/// - ARKit detects the bus pictogram or the Dublin Bus logo (`BusStopSign`), and the stop number
///   under it is read.
/// - The whole camera frame is searched for a stop number label, and the sign is placed from the
///   label's position and size (`SignLayout`). This works further away, at night and at steeper
///   angles than ARKit's image detection. If ARKit finds the sign's image later, its anchor takes
///   over, keeping the stop.
///
/// When the sign's stop is recognised, that stop's pin flies to the sign as it unfolds into the
/// board (`StopCardEntity`). Walking away folds it back into the pin; coming back unfolds it again.
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
    /// Seconds between whole-frame searches for a stop number label while no sign is known.
    private let labelSearchInterval: TimeInterval = 0.7
    /// The same, once a sign has been placed from a label: watching for a different stop.
    private let labelWatchInterval: TimeInterval = 2
    private var lastLabelSearch: TimeInterval = 0
    /// A pictogram this close to a sign placed from its label is the same sign.
    private let sameSignDistance: Float = 1.5
    /// If the anchor jumps further than this, it's a different sign.
    private let newSignDistance: Float = 2.5
    /// A pin further than this from its sign (badly placed by GPS) isn't flown to or from.
    private static let handoffReach: Float = 30
    /// Seconds for the card to fly between the pin and the sign.
    private static let cardMoveDuration: TimeInterval = 0.7

    /// Where the sign's card is.
    private enum CardState {
        /// Folded by the sign: its header and lines (or the reading message).
        case folded
        /// Folded back into the stop's pin, which shows instead: the card is hidden.
        case inPin
        case unfolded
        /// Flying, and unfolding or folding.
        case moving(CardMove)
    }

    private struct CardMove {
        enum Destination { case unfolded, folded, pin }
        /// Where it started, relative to the sign's root.
        let from: Transform
        let fromProgress: Float
        /// From a compact pin, say (0 folded … 1 compact).
        let fromCompactness: Float
        let destination: Destination
        let start: TimeInterval
    }

    @MainActor
    private final class TrackedSign {
        /// The `ARImageAnchor`'s identifier, or a new one for a sign placed from its label.
        let anchorID: UUID
        /// Detected by ARKit (it follows the image), rather than placed from a "Stop" label.
        let isImageAnchored: Bool
        /// A flag's pictogram may turn out to be on a round green sign.
        var kind: SignKind
        /// Fixed in the world, so the card stays put and visible when the sign is out of view.
        /// (Content attached to an image anchor may be hidden while ARKit isn't tracking the image.)
        let anchorEntity = AnchorEntity(world: matrix_identity_float4x4)
        /// The sign's origin (`SignLayout.Geometry`), in the axes of an image anchor (x right,
        /// y out of the sign, z down the sign). Moved to follow ARKit while it tracks the image.
        let root = Entity()
        let card = StopCardEntity()
        var cardState = CardState.folded
        var stopCode: String?
        /// From the stop's pin or its board.
        var stopName: String?
        var routes: [String] = []
        var recognisedAt: SIMD3<Float>?
        /// The card folds away when the user is further than this from the sign, in metres.
        var foldDistance = NearbyUnfolding.foldDistance
        var distanceLabel = DistanceLabel()
        /// The reference image's size on this sign, in metres: ARKit's estimate, or as printed.
        var size: SIMD2<Float>
        var firstSeen = Date()

        init(anchorID: UUID, isImageAnchored: Bool, kind: SignKind, transform: simd_float4x4, size: SIMD2<Float>) {
            self.anchorID = anchorID
            self.isImageAnchored = isImageAnchored
            self.kind = kind
            self.size = size
            anchorEntity.addChild(root)
            root.addChild(card)
            place(transform)
        }

        /// Forgets the stop: back to reading the number.
        func resetStop() {
            stopCode = nil
            stopName = nil
            routes = []
            recognisedAt = nil
            cardState = .folded
            card.isEnabled = true
        }

        /// Moves the sign to `transform` (world space, in the axes of an image anchor).
        func place(_ transform: simd_float4x4) {
            root.setTransformMatrix(transform, relativeTo: nil)
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        model.onPanelContentChange = { [weak self] content in
            self?.show(content)
        }
    }

    func attach(to arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        arView.renderOptions.insert(.disableMotionBlur)

        let stopsController = ARStopsController(arView: arView, service: model.service)
        stopsController.onStatusChange = { [weak self] status in self?.model.arStopsStatus = status }
        stopsController.onGeoTrackingAvailable = { [weak self] in self?.switchToGeoTracking() }
        stopsController.onUnfold = { [weak self] code in self?.model.activate(stopCode: code) }
        stopsController.onFold = { [weak self] code in self?.model.deactivate(stopCode: code) }
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
        guard var kind = BusStopSign.kind(ofReferenceImage: anchor.referenceImage.name), let arView else { return }
        if sign?.anchorID == anchor.identifier { return }

        // The image on a sign already placed from its label: keep its stop, and its card as it is.
        let position = anchor.transform.translation
        var carried: TrackedSign?
        if let sign, !sign.isImageAnchored, sign.stopCode != nil, let at = sign.recognisedAt,
           simd_distance(at, position) < sameSignDistance {
            carried = sign
            // The label told a round green sign from a flag; the pictogram can't.
            if kind == .flag, sign.kind == .greenDisc { kind = .greenDisc }
        }
        removeSign()

        let newSign = TrackedSign(anchorID: anchor.identifier, isImageAnchored: true, kind: kind, transform: anchor.transform,
                                  size: anchor.estimatedPhysicalSize)
        arView.scene.addAnchor(newSign.anchorEntity)
        sign = newSign
        consensus.reset()
        failedReads = 0

        if let carried, let code = carried.stopCode {
            newSign.stopName = carried.stopName
            newSign.routes = carried.routes
            if let content = carried.card.content { newSign.card.setContent(content) }
            let wasInPin = if case .inPin = carried.cardState { true } else { false }
            recognised(newSign, stopCode: code, at: position, unfolding: wasInPin ? .none : .immediately)
        } else {
            model.signDetected()
            updateCardContent(newSign)
        }
    }

    private func handleUpdated(_ anchor: ARImageAnchor) {
        guard let sign, sign.anchorID == anchor.identifier else {
            handleDetected(anchor)
            return
        }

        // ARKit reuses the anchor when the same image is found elsewhere: a big jump means a new sign.
        let position = anchor.transform.translation
        if let recognisedAt = sign.recognisedAt, simd_distance(position, recognisedAt) > newSignDistance {
            stopsController?.releaseSign()
            sign.kind = BusStopSign.kind(ofReferenceImage: anchor.referenceImage.name) ?? sign.kind
            sign.resetStop()
            sign.firstSeen = Date()
            consensus.reset()
            failedReads = 0
            model.signDetected()
        }

        // Follow the image while ARKit sees it; otherwise the sign stays where it was last seen.
        if anchor.isTracked { sign.place(anchor.transform) }

        sign.size = anchor.estimatedPhysicalSize // ARKit's scale estimate
    }

    /// Places a sign found from its stop number label, already knowing its stop.
    private func placeSign(_ transform: simd_float4x4, kind: SignKind, stopCode: String) {
        guard let arView else { return }
        removeSign()

        let newSign = TrackedSign(anchorID: UUID(), isImageAnchored: false, kind: kind, transform: transform,
                                  size: SignLayout.geometry(of: kind).referenceSize)
        arView.scene.addAnchor(newSign.anchorEntity)
        sign = newSign
        consensus.reset()
        failedReads = 0

        recognised(newSign, stopCode: stopCode, at: transform.translation, unfolding: .animated)
    }

    private func setKind(_ kind: SignKind, of sign: TrackedSign) {
        sign.kind = kind // the card follows on the next frame
    }

    private func removeSign() {
        sign?.anchorEntity.removeFromParent()
        sign = nil
        isReading = false
        stopsController?.releaseSign()
    }

    // MARK: - The sign's card

    private enum Unfolding { case animated, immediately, none }

    /// The sign's stop is known: its board unfolds under the sign straight away, whatever the
    /// distance, and folds once the user walks a little further away than they are now.
    private func recognised(_ sign: TrackedSign, stopCode: String, at position: SIMD3<Float>, unfolding: Unfolding) {
        sign.stopCode = stopCode
        sign.recognisedAt = position
        stopsController?.signRecognised(stopCode: stopCode, at: position)
        stopsController?.reservedStopCode = stopCode
        if let camera = arView?.session.currentFrame?.camera.transform.translation {
            sign.foldDistance = max(NearbyUnfolding.foldDistance, horizontalDistance(camera, sign.root.position(relativeTo: nil)) + 3)
        }
        // Before unfolding, which starts the card off with the pin's own header.
        updateCardContent(sign)
        switch unfolding {
        case .animated:
            unfoldCard(sign)
        case .immediately:
            unfoldCard(sign)
            sign.cardState = .unfolded
        case .none:
            _ = stopsController?.handOff(stopCode: stopCode)
            stopsController?.takeBack(stopCode: stopCode)
            sign.card.isEnabled = false
            sign.cardState = .inPin
        }
    }

    /// Unfolds the card under the sign: from the stop's pin, flying, if there is one nearby.
    private func unfoldCard(_ sign: TrackedSign) {
        guard let code = sign.stopCode else { return }
        model.activate(stopCode: code)
        stopsController?.suppressesUnfolding = true

        var from = sign.card.transform
        var fromProgress = sign.card.progress
        var fromCompactness = sign.card.compactness
        if let handoff = stopsController?.handOff(stopCode: code),
           simd_distance(handoff.cardTransform.translation, sign.root.position(relativeTo: nil)) < Self.handoffReach {
            if sign.stopName == nil, !handoff.stop.stop.name.isEmpty { sign.stopName = handoff.stop.stop.name }
            if sign.routes.isEmpty { sign.routes = handoff.stop.routes }
            // Starts out looking exactly like the pin.
            if let header = handoff.header { sign.card.setHeader(header) }
            sign.card.setFoldedBody(StopCardEntity.FoldedBody(routes: sign.routes))
            from = relativeToRoot(handoff.cardTransform, of: sign)
            fromProgress = handoff.progress
            fromCompactness = handoff.compactness
        } else if case .inPin = sign.cardState {
            from = cardTransformOnSign(sign)
            fromProgress = 0
            fromCompactness = 0
        }
        if model.panelContent.stopCode == code { sign.card.setContent(model.panelContent) }
        sign.card.isEnabled = true
        sign.card.setCompactness(fromCompactness)
        sign.cardState = .moving(CardMove(from: from, fromProgress: fromProgress, fromCompactness: fromCompactness,
                                          destination: .unfolded, start: CACurrentMediaTime()))
    }

    /// Folds the card back into the stop's pin, or by the sign if there's no pin nearby.
    private func foldCard(_ sign: TrackedSign) {
        var destination = CardMove.Destination.folded
        if let code = sign.stopCode, let pin = stopsController?.cardTransform(stopCode: code),
           simd_distance(pin.translation, sign.root.position(relativeTo: nil)) < Self.handoffReach {
            destination = .pin
        }
        sign.cardState = .moving(CardMove(from: sign.card.transform, fromProgress: sign.card.progress,
                                          fromCompactness: sign.card.compactness, destination: destination,
                                          start: CACurrentMediaTime()))
    }

    /// Moves the card for this frame, and unfolds or folds it as the user comes and goes.
    private func updateCard(camera: SIMD3<Float>) {
        guard let sign else { return }
        let onSign = cardTransformOnSign(sign)
        let distance = horizontalDistance(camera, sign.root.position(relativeTo: nil))
        if sign.distanceLabel.update(Double(distance)) { updateCardContent(sign) }

        switch sign.cardState {
        case .folded:
            sign.card.transform = onSign
            sign.card.setProgress(0)
            sign.card.setCompactness(0)
            if sign.stopCode != nil, distance <= NearbyUnfolding.unfoldDistance { unfoldCard(sign) }
        case .inPin:
            if distance <= NearbyUnfolding.unfoldDistance { unfoldCard(sign) }
        case .unfolded:
            sign.card.transform = onSign
            sign.card.setProgress(1)
            sign.card.setCompactness(0)
            if distance > sign.foldDistance { foldCard(sign) }
        case .moving(let move):
            let t = Float(min((CACurrentMediaTime() - move.start) / Self.cardMoveDuration, 1))
            let eased = smoothstep(t)
            switch move.destination {
            case .unfolded:
                sign.card.transform = move.from.interpolated(to: onSign, eased)
                sign.card.setProgress(move.fromProgress + (1 - move.fromProgress) * eased)
                sign.card.setCompactness(move.fromCompactness * (1 - eased))
                if t >= 1 { sign.cardState = .unfolded }
            case .folded:
                sign.card.transform = move.from.interpolated(to: onSign, eased)
                sign.card.setProgress(move.fromProgress * (1 - eased))
                sign.card.setCompactness(move.fromCompactness * (1 - eased))
                if t >= 1 {
                    sign.cardState = .folded
                    stopsController?.suppressesUnfolding = false
                }
            case .pin:
                guard let code = sign.stopCode, let pin = stopsController?.cardTransform(stopCode: code) else {
                    // The pin went away (the stops were reloaded or switched off): fold here instead.
                    sign.cardState = .moving(CardMove(from: sign.card.transform, fromProgress: sign.card.progress,
                                                      fromCompactness: sign.card.compactness, destination: .folded,
                                                      start: CACurrentMediaTime()))
                    return
                }
                sign.card.transform = move.from.interpolated(to: relativeToRoot(pin, of: sign), eased)
                sign.card.setProgress(move.fromProgress * (1 - eased))
                // Ends up looking like the pin, compact if it's far enough.
                let pinCompactness = stopsController?.cardCompactness(stopCode: code) ?? 0
                sign.card.setCompactness(move.fromCompactness + (pinCompactness - move.fromCompactness) * eased)
                if t >= 1 {
                    sign.card.isEnabled = false
                    stopsController?.takeBack(stopCode: code)
                    stopsController?.suppressesUnfolding = false
                    sign.cardState = .inPin
                }
            }
        }
    }

    /// Unfolded under the sign: flat on it, 10 cm in front, its top 20 cm below the sign's bottom.
    private func cardTransformOnSign(_ sign: TrackedSign) -> Transform {
        Transform(scale: SIMD3(repeating: StopCardEntity.unfoldedScale), rotation: StopCardEntity.onSign,
                  translation: SignLayout.cardTop(kind: sign.kind, referenceSize: sign.size))
    }

    private func relativeToRoot(_ world: simd_float4x4, of sign: TrackedSign) -> Transform {
        Transform(matrix: sign.root.transformMatrix(relativeTo: nil).inverse * world)
    }

    /// The card's header and folded lines: the stop, or that its number is being read.
    private func updateCardContent(_ sign: TrackedSign) {
        let distance = sign.distanceLabel.metres
        if let code = sign.stopCode {
            sign.card.setHeader(.stop(code: code, name: sign.stopName, distance: distance))
            sign.card.setFoldedBody(StopCardEntity.FoldedBody(routes: sign.routes))
        } else {
            sign.card.setHeader(StopCardEntity.Header(title: "Bus stop", subtitle: nil, distance: distance))
            var hint: String?
            if case .reading(let readingHint) = model.panelContent { hint = readingHint }
            sign.card.setFoldedBody(StopCardEntity.FoldedBody(message: hint ?? "Reading the stop number…"))
        }
    }

    /// New board content: for the sign's card if it's about its stop, and for an unfolded pin.
    private func show(_ content: PanelContent) {
        stopsController?.showContent(content)
        guard let sign else { return }
        guard let code = sign.stopCode else {
            updateCardContent(sign)
            return
        }
        guard content.stopCode == code else { return }
        if case .board(let board) = content {
            if sign.stopName == nil, !board.stopName.isEmpty { sign.stopName = board.stopName }
            // Without a pin, the lines come from the departures.
            if sign.routes.isEmpty {
                var seen = Set<String>()
                sign.routes = board.departures.map(\.route).filter { seen.insert($0).inserted }
            }
        }
        sign.card.setContent(content)
        updateCardContent(sign)
    }

    private func horizontalDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        simd_distance(a * SIMD3(1, 0, 1), b * SIMD3(1, 0, 1))
    }

    // MARK: - Frames & OCR

    private func handleFrame(_ frame: ARFrame) {
        // Pins first: a card flying to or from a pin follows where the pin is this frame.
        stopsController?.update(frame: frame)
        updateCard(camera: frame.camera.transform.translation)
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

        // Mostly read the region under the image; every third try, search the whole frame.
        if failedReads % 3 == 2 {
            lastReadAttempt = frame.timestamp
            searchForLabels(in: frame, interval: 0)
            return
        }
        let kind = sign.kind
        guard let quad = projectedQuad(BusStopSign.stopNumberRegion(for: kind), of: anchor, in: frame) else { return }
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
                self.handleReading(result.number, text: result.text, kind: kind, anchorID: anchorID,
                                   anchorPosition: anchorPosition)
            }
        }
    }

    /// - Parameters:
    ///   - text: the lines read in the region under the image.
    ///   - kind: the kind of sign the region was chosen for.
    private func handleReading(_ number: String?, text: [String], kind: SignKind, anchorID: UUID, anchorPosition: SIMD3<Float>) {
        isReading = false
        guard let sign, sign.anchorID == anchorID, sign.stopCode == nil, sign.kind == kind else { return }

        // "Stop" on a line of its own under the bus pictogram: a round green sign, not a flag. Its
        // number is lower down than a flag's, so read again with the round sign's region.
        if kind == .flag, text.contains(where: { StopNumberParser.keywordLine($0) == .stop }) {
            setKind(.greenDisc, of: sign)
            return
        }

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
        recognised(sign, stopCode: stopCode, at: position, unfolding: .animated)
    }

    // MARK: - Whole-frame label search

    /// The camera at the moment a frame was captured, to place what's found in it later.
    private struct CameraCapture {
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
    }

    /// Looks for stop number labels anywhere in the frame, at most every `interval` seconds.
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

        // A detected image whose own region couldn't be read: the label is its stop number.
        if let sign, sign.isImageAnchored {
            guard sign.stopCode == nil else { return }
            guard let label else {
                failedReads += 1
                return
            }
            if sign.kind == .flag, label.kind == .greenDisc { setKind(.greenDisc, of: sign) }
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
        placeSign(transform, kind: label.kind, stopCode: accepted)
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
