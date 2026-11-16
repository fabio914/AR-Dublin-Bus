import CoreLocation
import Foundation
import simd

/// Metres east and north of a reference coordinate, on a plane tangent to the Earth there.
/// Accurate to centimetres over the few hundred metres the AR view covers.
struct LocalTangentPlane: Sendable {
    let reference: CLLocationCoordinate2D

    /// WGS84 radii of curvature at the reference latitude.
    private let metresPerRadianNorth: Double
    private let metresPerRadianEast: Double

    init(reference: CLLocationCoordinate2D) {
        self.reference = reference
        let a = 6_378_137.0, e2 = 0.006_694_379_990_14
        let sinLatitude = sin(reference.latitude * .pi / 180)
        let w = sqrt(1 - e2 * sinLatitude * sinLatitude)
        metresPerRadianNorth = a * (1 - e2) / (w * w * w)
        metresPerRadianEast = a / w * cos(reference.latitude * .pi / 180)
    }

    /// (east, north) in metres.
    func offset(of coordinate: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2(
            (coordinate.longitude - reference.longitude) * .pi / 180 * metresPerRadianEast,
            (coordinate.latitude - reference.latitude) * .pi / 180 * metresPerRadianNorth
        )
    }

    func coordinate(at offset: SIMD2<Double>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: reference.latitude + offset.y / metresPerRadianNorth * 180 / .pi,
            longitude: reference.longitude + offset.x / metresPerRadianEast * 180 / .pi
        )
    }
}

/// Where the AR session's origin is on the map, so stops (latitude/longitude) can be placed
/// in AR space (metres).
///
/// Requires a session with `worldAlignment = .gravityAndHeading`: ARKit's x axis then points
/// east, y up and z south. Each GPS fix, together with where the camera was in AR space at that
/// moment, gives an estimate of the origin; they're averaged, weighted by GPS accuracy. A
/// recognised stop sign gives a much better estimate (the stop's mapped position) and takes over.
struct GeoAlignment: Sendable {
    private struct Estimate: Sendable {
        /// The AR origin, in metres east/north of `plane.reference`.
        let origin: SIMD2<Double>
        let accuracy: Double
    }

    private(set) var plane: LocalTangentPlane?
    private var gpsEstimates: [Estimate] = []
    private var signEstimate: Estimate?
    /// Where the sign was, in AR space: tracking drifts with distance, so the sign estimate
    /// is dropped once the camera is far from it.
    private var signPosition: SIMD3<Float>?
    /// Camera height in AR space at the last fix, for guessing where the ground is.
    private(set) var lastCameraHeight: Float?

    /// GPS fixes worse than this are ignored.
    static let maximumAccuracy: CLLocationAccuracy = 65
    /// How many recent fixes are averaged.
    static let maximumEstimates = 30
    /// Beyond this distance from the recognised sign, GPS takes over again.
    static let signRange: Float = 250

    var isReady: Bool { plane != nil && (signEstimate != nil || !gpsEstimates.isEmpty) }

    /// A recognised sign, rather than GPS, is setting the position.
    var isCorrectedBySign: Bool { signEstimate != nil }

    /// How far off placements may be, in metres (roughly).
    ///
    /// The typical accuracy of the recent fixes, weighted like the average. It deliberately
    /// doesn't shrink as fixes accumulate: fixes taken in one place share most of their error
    /// (the same buildings blocking the same satellites), so averaging them barely helps.
    var expectedError: Double? {
        if let signEstimate { return signEstimate.accuracy }
        guard !gpsEstimates.isEmpty else { return nil }
        let weights = gpsEstimates.map { 1 / ($0.accuracy * $0.accuracy) }
        let weightedAccuracy = zip(gpsEstimates, weights).map { $0.accuracy * $1 }.reduce(0, +)
        return weightedAccuracy / weights.reduce(0, +)
    }

    /// Records a GPS fix taken while the camera was at `cameraPosition` (AR space).
    mutating func addFix(_ location: CLLocation, cameraPosition: SIMD3<Float>) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.maximumAccuracy else { return }
        let plane = self.plane ?? LocalTangentPlane(reference: location.coordinate)
        self.plane = plane
        lastCameraHeight = cameraPosition.y
        if let signPosition, simd_distance(signPosition, cameraPosition) > Self.signRange {
            signEstimate = nil
            self.signPosition = nil
        }

        let fix = plane.offset(of: location.coordinate)
        gpsEstimates.append(Estimate(origin: fix - Self.eastNorth(of: cameraPosition),
                                     accuracy: max(location.horizontalAccuracy, 3)))
        if gpsEstimates.count > Self.maximumEstimates { gpsEstimates.removeFirst() }
    }

    /// A sign for the stop at `coordinate` was recognised at `position` (AR space).
    mutating func addSign(at position: SIMD3<Float>, coordinate: CLLocationCoordinate2D) {
        let plane = self.plane ?? LocalTangentPlane(reference: coordinate)
        self.plane = plane
        signEstimate = Estimate(origin: plane.offset(of: coordinate) - Self.eastNorth(of: position), accuracy: 2)
        signPosition = position
    }

    /// The AR origin in metres east/north of the reference.
    private var origin: SIMD2<Double>? {
        if let signEstimate { return signEstimate.origin }
        guard !gpsEstimates.isEmpty else { return nil }
        var sum = SIMD2<Double>.zero, totalWeight = 0.0
        for estimate in gpsEstimates {
            let weight = 1 / (estimate.accuracy * estimate.accuracy)
            sum += estimate.origin * weight
            totalWeight += weight
        }
        return sum / totalWeight
    }

    /// Where `coordinate` is in AR space, at height `y`.
    func position(of coordinate: CLLocationCoordinate2D, y: Float) -> SIMD3<Float>? {
        guard let plane, let origin else { return nil }
        let eastNorth = plane.offset(of: coordinate) - origin
        return SIMD3(Float(eastNorth.x), y, Float(-eastNorth.y))
    }

    /// Where an AR position is on the map.
    func coordinate(of position: SIMD3<Float>) -> CLLocationCoordinate2D? {
        guard let plane, let origin else { return nil }
        return plane.coordinate(at: origin + Self.eastNorth(of: position))
    }

    /// AR x is east and z is south.
    private static func eastNorth(of position: SIMD3<Float>) -> SIMD2<Double> {
        SIMD2(Double(position.x), Double(-position.z))
    }
}
