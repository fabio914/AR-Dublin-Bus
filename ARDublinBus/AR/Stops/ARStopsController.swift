import ARKit
import CoreLocation
import RealityKit

/// How nearby stops are being placed in AR, for the status shown on screen.
struct ARStopsStatus: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Stops in AR are switched off.
        case off
        /// The compass or location can't be used, so stops can't be placed.
        case unavailable
        case waitingForLocation
        /// Placed from GPS and the compass (corrected by recognised signs).
        case compass
        /// Geo tracking is running but hasn't matched the surroundings yet; GPS + compass meanwhile.
        case geoLocalizing
        /// Placed with ARKit location anchors.
        case geo
    }

    var mode: Mode = .off
    var stopCount = 0
    /// Rough placement error in metres, in compass modes.
    var expectedError: Double?
    /// A recognised sign is correcting the GPS position.
    var isCorrectedBySign = false
}

/// Which nearby stop's card is unfolded: the nearest within `unfoldDistance`, kept until it's
/// further than `foldDistance`, so it doesn't flicker at the edge.
enum NearbyUnfolding {
    static let unfoldDistance: Float = 5
    static let foldDistance: Float = 8

    /// - Parameters:
    ///   - current: the stop unfolded now.
    ///   - distances: each stop that may unfold, and how far it is (horizontally), in metres.
    static func stop<ID: Hashable>(current: ID?, distances: [ID: Float]) -> ID? {
        if let current, let distance = distances[current], distance <= foldDistance { return current }
        return distances.filter { $0.value <= unfoldDistance }.min { $0.value < $1.value }?.key
    }
}

/// A stop's pin, handed over to a recognised sign's card.
struct PinHandoff {
    let stop: ARStop
    /// The pin's card in world space, where the sign's card starts from.
    let cardTransform: simd_float4x4
    /// How far the pin had unfolded (0 folded … 1 unfolded).
    let progress: Float
    let header: StopCardEntity.Header?
}

/// Shows the stops around the user as pins in the AR view.
///
/// Stops within `radius` are fetched from the timetable (R-tree) whenever the user has moved
/// `requeryDistance`. Each one is placed either:
/// - with an `ARGeoAnchor`, when the session uses geo tracking and has localised; or
/// - from GPS and the compass (`GeoAlignment`), in any session aligned with gravity and heading.
///
/// Walking up to a stop unfolds its pin into the departures board (`NearbyUnfolding`). When a sign
/// is recognised, its stop's pin is handed over to the sign's card (`handOff(stopCode:)`) until
/// the card folds back into it (`takeBack(stopCode:)`).
@MainActor
final class ARStopsController: NSObject, CLLocationManagerDelegate {
    static let radius: CLLocationDistance = 400
    static let maximumStops = 25
    static let requeryDistance: CLLocationDistance = 40
    /// Approximate height of the phone above the ground.
    static let phoneHeight: Float = 1.4

    private enum Placement: Equatable {
        case compass
        case geo
    }

    private final class Pin {
        let stop: ARStop
        let entity: StopPinEntity
        /// Geo placement: the anchor entity tied to the `ARGeoAnchor`.
        var geoAnchorEntity: AnchorEntity?
        var geoAnchor: ARGeoAnchor?
        /// Compass placement: where the pin should be (it glides there).
        var target: SIMD3<Float>?

        init(stop: ARStop, entity: StopPinEntity) {
            self.stop = stop
            self.entity = entity
        }
    }

    private weak var arView: ARView?
    private let service: DepartureService
    private let locationManager = CLLocationManager()

    private var alignment = GeoAlignment()
    private var lastLocation: CLLocation?
    private var lastQueryLocation: CLLocation?
    private var queryTask: Task<Void, Never>?
    private var pins: [String: Pin] = [:]
    /// Parent of compass-placed pins, at the AR origin.
    private var compassRoot: AnchorEntity?
    private var placement = Placement.compass
    private var sessionUsesGeoTracking = false
    /// The session knows where north is (compass-aligned, or geo tracking).
    private var hasHeading = true
    private var geoState: ARGeoTrackingStatus.State = .notAvailable
    private var hasCheckedGeoAvailability = false
    private var isEnabled = false
    /// The stop whose pin has been handed over to a sign's card: it's hidden.
    private var handedOffStopCode: String?
    /// The pin unfolded because the user is next to its stop.
    private var unfoldedPinID: String?
    /// The latest departures board, shown on the unfolded pin when it's for its stop.
    private var latestContent: PanelContent?
    private var lastFrameTime: TimeInterval?
    private var status = ARStopsStatus() {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    var onStatusChange: ((ARStopsStatus) -> Void)?
    /// Geo tracking is available here: the owner should restart the session with it.
    var onGeoTrackingAvailable: (() -> Void)?
    /// A pin unfolded next to its stop: its departures are needed.
    var onUnfold: ((_ stopCode: String) -> Void)?
    /// The unfolded pin folded again.
    var onFold: ((_ stopCode: String) -> Void)?
    /// The stop of the sign being tracked: its card unfolds by the sign instead.
    var reservedStopCode: String?
    /// No pin unfolds while a sign's card is open.
    var suppressesUnfolding = false

    init(arView: ARView, service: DepartureService) {
        self.arView = arView
        self.service = service
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .otherNavigation
    }

    // MARK: Lifecycle

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            status.mode = hasHeading ? .waitingForLocation : .unavailable
            if locationManager.authorizationStatus == .notDetermined {
                locationManager.requestWhenInUseAuthorization()
            }
            locationManager.startUpdatingLocation()
        } else {
            locationManager.stopUpdatingLocation()
            queryTask?.cancel()
            removeAllPins()
            lastQueryLocation = nil
            status = ARStopsStatus()
        }
    }

    /// The AR session was (re)started: its coordinate space and anchors are gone.
    func sessionDidRestart(usesGeoTracking: Bool, hasHeading: Bool) {
        sessionUsesGeoTracking = usesGeoTracking
        self.hasHeading = hasHeading
        geoState = usesGeoTracking ? .initializing : .notAvailable
        alignment = GeoAlignment()
        removeAllPins()
        placement = .compass
        if isEnabled {
            status.mode = hasHeading ? .waitingForLocation : .unavailable
            lastQueryLocation = nil
            if let lastLocation { handle(lastLocation) }
        }
    }

    func geoTrackingStatusChanged(_ status: ARGeoTrackingStatus) {
        geoState = status.state
        let wanted: Placement = sessionUsesGeoTracking && status.state == .localized ? .geo : .compass
        if wanted != placement {
            placement = wanted
            rebuildPins()
        }
        updateStatus()
    }

    /// A sign was recognised: it pins down where that stop is in AR space.
    func signRecognised(stopCode: String, at position: SIMD3<Float>) {
        guard let coordinate = pins.values.first(where: { $0.stop.stop.code == stopCode })?.stop.stop.coordinate else {
            // Not among the pins (yet): look the stop up.
            Task {
                guard let stop = try? await service.searchStops(stopCode, limit: 1).first?.stop,
                      stop.code == stopCode, let coordinate = stop.coordinate else { return }
                applySign(at: position, coordinate: coordinate)
            }
            return
        }
        applySign(at: position, coordinate: coordinate)
    }

    /// The sign is gone: every pin shows again.
    func releaseSign() {
        handedOffStopCode = nil
        reservedStopCode = nil
        suppressesUnfolding = false
        pins.values.forEach { $0.entity.isEnabled = true }
    }

    /// Hides the stop's pin and returns where its card is, for the sign's card to take over from.
    func handOff(stopCode: String) -> PinHandoff? {
        handedOffStopCode = stopCode
        guard let pin = pin(forStopCode: stopCode) else { return nil }
        let handoff = PinHandoff(stop: pin.stop, cardTransform: pin.entity.card.transformMatrix(relativeTo: nil),
                                 progress: pin.entity.card.progress, header: pin.entity.card.header)
        // The sign's card shows this stop's board from now on.
        if unfoldedPinID == pin.stop.id { unfoldedPinID = nil }
        pin.entity.fold()
        pin.entity.isEnabled = false
        return handoff
    }

    /// Where the stop's (hidden) pin card is in world space, for folding the sign's card back into it.
    func cardTransform(stopCode: String) -> simd_float4x4? {
        guard let pin = pin(forStopCode: stopCode), pin.entity.parent != nil else { return nil }
        return pin.entity.card.transformMatrix(relativeTo: nil)
    }

    /// The sign's card folded back into the stop's pin: show the pin again.
    func takeBack(stopCode: String) {
        if handedOffStopCode == stopCode { handedOffStopCode = nil }
        pin(forStopCode: stopCode)?.entity.isEnabled = true
    }

    /// The latest board: shown on the unfolded pin if it's for its stop.
    func showContent(_ content: PanelContent) {
        latestContent = content
        guard let id = unfoldedPinID, let pin = pins[id], content.stopCode == pin.stop.stop.code else { return }
        pin.entity.showContent(content)
    }

    private func pin(forStopCode code: String) -> Pin? {
        pins.values.first { $0.stop.stop.code == code }
    }

    private func applySign(at position: SIMD3<Float>, coordinate: CLLocationCoordinate2D) {
        alignment.addSign(at: position, coordinate: coordinate)
        updateCompassTargets(snap: false)
        updateStatus()
    }

    /// The stop whose pin contains `entity`, if any (for taps).
    func stop(for entity: Entity) -> GTFSStop? {
        var current: Entity? = entity
        while let candidate = current {
            if let pin = candidate as? StopPinEntity { return pin.stop?.stop }
            current = candidate.parent
        }
        return nil
    }

    // MARK: Frames

    /// Called for every camera frame: glides compass pins to their targets, unfolds the pin of a
    /// stop the user is next to, and sizes and turns the cards.
    func update(frame: ARFrame) {
        let deltaTime = Float(min(frame.timestamp - (lastFrameTime ?? frame.timestamp), 0.1))
        lastFrameTime = frame.timestamp
        guard isEnabled, !pins.isEmpty else { return }
        let camera = frame.camera.transform.translation
        var distances: [String: Float] = [:]
        for pin in pins.values {
            if placement == .compass, let target = pin.target {
                let current = pin.entity.position
                pin.entity.position = simd_distance(current, target) > 30 ? target : current + (target - current) * 0.1
            }
            let distance = simd_distance(pin.entity.position(relativeTo: nil) * SIMD3(1, 0, 1), camera * SIMD3(1, 0, 1))
            pin.entity.update(distance: Double(distance))
            if pin.entity.isEnabled, pin.stop.stop.code != reservedStopCode { distances[pin.stop.id] = distance }
        }
        setUnfoldedPin(suppressesUnfolding ? nil : NearbyUnfolding.stop(current: unfoldedPinID, distances: distances))
        for pin in pins.values {
            pin.entity.layout(cameraPosition: camera, deltaTime: deltaTime)
        }
    }

    private func setUnfoldedPin(_ id: String?) {
        guard id != unfoldedPinID else { return }
        if let old = unfoldedPinID.flatMap({ pins[$0] }) {
            old.entity.setUnfolded(false)
            onFold?(old.stop.stop.code)
        }
        unfoldedPinID = id
        guard let pin = id.flatMap({ pins[$0] }) else { return }
        if let latestContent, latestContent.stopCode == pin.stop.stop.code { pin.entity.showContent(latestContent) }
        pin.entity.setUnfolded(true)
        onUnfold?(pin.stop.stop.code)
    }

    // MARK: Location

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated { handle(location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard isEnabled else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.startUpdatingLocation()
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func handle(_ location: CLLocation) {
        guard isEnabled, hasHeading,
              let frame = arView?.session.currentFrame, case .normal = frame.camera.trackingState else { return }
        lastLocation = location
        alignment.addFix(location, cameraPosition: frame.camera.transform.translation)
        updateCompassTargets(snap: false)

        if !hasCheckedGeoAvailability, location.horizontalAccuracy <= GeoAlignment.maximumAccuracy {
            hasCheckedGeoAvailability = true
            checkGeoAvailability(at: location.coordinate)
        }

        if lastQueryLocation.map({ $0.distance(from: location) >= Self.requeryDistance }) ?? true {
            lastQueryLocation = location
            loadStops(around: location.coordinate)
        }
        updateStatus()
    }

    private func checkGeoAvailability(at coordinate: CLLocationCoordinate2D) {
        guard ARGeoTrackingConfiguration.isSupported else { return }
        ARGeoTrackingConfiguration.checkAvailability(at: coordinate) { available, _ in
            guard available else { return }
            Task { @MainActor [weak self] in self?.onGeoTrackingAvailable?() }
        }
    }

    // MARK: Pins

    private func loadStops(around coordinate: CLLocationCoordinate2D) {
        queryTask?.cancel()
        queryTask = Task {
            guard let stops = try? await service.arStops(around: coordinate, radius: Self.radius, limit: Self.maximumStops),
                  !Task.isCancelled, isEnabled else { return }
            show(stops)
        }
    }

    private func show(_ stops: [ARStop]) {
        let wanted = Set(stops.map(\.id))
        if let id = unfoldedPinID, !wanted.contains(id) { setUnfoldedPin(nil) }
        for (id, pin) in pins where !wanted.contains(id) {
            remove(pin)
            pins[id] = nil
        }
        for stop in stops where pins[stop.id] == nil {
            let pin = Pin(stop: stop, entity: StopPinEntity(stop: stop))
            pin.entity.isEnabled = stop.stop.code != handedOffStopCode
            pins[stop.id] = pin
            place(pin)
        }
        updateStatus()
    }

    private func place(_ pin: Pin) {
        guard let arView, let coordinate = pin.stop.stop.coordinate else { return }
        switch placement {
        case .geo:
            // ARKit puts geo anchors at ground level when no altitude is given.
            let anchor = ARGeoAnchor(name: "stop:\(pin.stop.id)", coordinate: coordinate)
            arView.session.add(anchor: anchor)
            let anchorEntity = AnchorEntity(anchor: anchor)
            pin.entity.position = SIMD3(0, StopPinEntity.heightAboveGround, 0)
            anchorEntity.addChild(pin.entity)
            arView.scene.addAnchor(anchorEntity)
            pin.geoAnchor = anchor
            pin.geoAnchorEntity = anchorEntity
        case .compass:
            let root = compassRoot ?? {
                let root = AnchorEntity(world: matrix_identity_float4x4)
                arView.scene.addAnchor(root)
                compassRoot = root
                return root
            }()
            root.addChild(pin.entity)
            pin.target = compassTarget(for: coordinate)
            if let target = pin.target { pin.entity.position = target }
        }
    }

    private func remove(_ pin: Pin) {
        pin.entity.removeFromParent()
        pin.geoAnchorEntity?.removeFromParent()
        if let anchor = pin.geoAnchor { arView?.session.remove(anchor: anchor) }
        pin.geoAnchor = nil
        pin.geoAnchorEntity = nil
        pin.target = nil
    }

    private func removeAllPins() {
        setUnfoldedPin(nil)
        pins.values.forEach(remove)
        pins.removeAll()
        compassRoot?.removeFromParent()
        compassRoot = nil
    }

    /// Re-places every pin, after switching between compass and geo placement.
    private func rebuildPins() {
        for pin in pins.values {
            remove(pin)
            place(pin)
        }
    }

    private func compassTarget(for coordinate: CLLocationCoordinate2D) -> SIMD3<Float>? {
        let cameraHeight = arView?.session.currentFrame?.camera.transform.translation.y ?? alignment.lastCameraHeight ?? 0
        return alignment.position(of: coordinate, y: cameraHeight - Self.phoneHeight + StopPinEntity.heightAboveGround)
    }

    private func updateCompassTargets(snap: Bool) {
        guard placement == .compass else { return }
        for pin in pins.values {
            guard let coordinate = pin.stop.stop.coordinate, let target = compassTarget(for: coordinate) else { continue }
            pin.target = target
            if snap { pin.entity.position = target }
        }
    }

    private func updateStatus() {
        guard isEnabled else { status = ARStopsStatus(); return }
        var status = ARStopsStatus()
        guard hasHeading else {
            status.mode = .unavailable
            self.status = status
            return
        }
        status.stopCount = pins.count
        switch placement {
        case .geo:
            status.mode = .geo
        case .compass:
            if !alignment.isReady {
                status.mode = .waitingForLocation
            } else {
                status.mode = sessionUsesGeoTracking ? .geoLocalizing : .compass
                status.expectedError = alignment.expectedError
                status.isCorrectedBySign = alignment.isCorrectedBySign
            }
        }
        self.status = status
    }
}
