import CoreLocation
import Foundation
import Testing
import simd
@testable import ARDublinBus

struct LocalTangentPlaneTests {
    let oConnellStreet = CLLocationCoordinate2D(latitude: 53.348596, longitude: -6.259485)

    @Test func offsetsMatchCoreLocationDistances() {
        let plane = LocalTangentPlane(reference: oConnellStreet)
        let nassauStreet = CLLocationCoordinate2D(latitude: 53.3427, longitude: -6.2571)
        let offset = plane.offset(of: nassauStreet)
        let expected = CLLocation(latitude: oConnellStreet.latitude, longitude: oConnellStreet.longitude)
            .distance(from: CLLocation(latitude: nassauStreet.latitude, longitude: nassauStreet.longitude))
        #expect(abs(simd_length(offset) - expected) < expected * 0.003)
        #expect(offset.x > 0) // east
        #expect(offset.y < 0) // south
    }

    @Test func roundTrips() {
        let plane = LocalTangentPlane(reference: oConnellStreet)
        let back = plane.coordinate(at: SIMD2(-123.4, 456.7))
        let offset = plane.offset(of: back)
        #expect(abs(offset.x - -123.4) < 1e-6)
        #expect(abs(offset.y - 456.7) < 1e-6)
    }
}

struct GeoAlignmentTests {
    let here = CLLocationCoordinate2D(latitude: 53.348596, longitude: -6.259485)

    private func location(_ coordinate: CLLocationCoordinate2D, accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: .now)
    }

    private func coordinate(east: Double, north: Double) -> CLLocationCoordinate2D {
        LocalTangentPlane(reference: here).coordinate(at: SIMD2(east, north))
    }

    @Test func notReadyWithoutAFix() {
        let alignment = GeoAlignment()
        #expect(!alignment.isReady)
        #expect(alignment.position(of: here, y: 0) == nil)
    }

    @Test func placesStopsEastAndNorthAlongXAndMinusZ() throws {
        var alignment = GeoAlignment()
        alignment.addFix(location(here), cameraPosition: .zero)
        let north = try #require(alignment.position(of: coordinate(east: 0, north: 100), y: 2))
        #expect(abs(north.x) < 0.01 && abs(north.z - -100) < 0.01 && north.y == 2)
        let east = try #require(alignment.position(of: coordinate(east: 50, north: 0), y: 0))
        #expect(abs(east.x - 50) < 0.01 && abs(east.z) < 0.01)
    }

    @Test func accountsForWhereTheCameraWasAtTheFix() throws {
        var alignment = GeoAlignment()
        // The user walked 10 m east in AR space and GPS puts them at `here`: so the AR origin
        // is 10 m west of `here`, and `here` is at x = 10.
        alignment.addFix(location(here), cameraPosition: SIMD3(10, 0, 0))
        let position = try #require(alignment.position(of: here, y: 0))
        #expect(abs(position.x - 10) < 0.01)
        let back = try #require(alignment.coordinate(of: position))
        #expect(abs(back.latitude - here.latitude) < 1e-7 && abs(back.longitude - here.longitude) < 1e-7)
    }

    @Test func averagesFixesWeightedByAccuracy() throws {
        var alignment = GeoAlignment()
        alignment.addFix(location(here, accuracy: 5), cameraPosition: .zero)
        alignment.addFix(location(coordinate(east: 20, north: 0), accuracy: 10), cameraPosition: .zero)
        // Weights 1/25 and 1/100: the origin lands 4 m east of `here`.
        let position = try #require(alignment.position(of: here, y: 0))
        #expect(abs(position.x - -4) < 0.01)
        // The typical accuracy, weighted the same way: (1/5 + 1/10) / (1/25 + 1/100) = 6 m.
        #expect(abs(try #require(alignment.expectedError) - 6) < 0.001)
    }

    @Test func expectedErrorDoesNotShrinkWithRepeatedFixes() throws {
        var alignment = GeoAlignment()
        for _ in 0..<30 { alignment.addFix(location(here, accuracy: 8), cameraPosition: .zero) }
        #expect(abs(try #require(alignment.expectedError) - 8) < 0.001)
    }

    @Test func ignoresInaccurateFixes() {
        var alignment = GeoAlignment()
        alignment.addFix(location(here, accuracy: 120), cameraPosition: .zero)
        alignment.addFix(location(here, accuracy: -1), cameraPosition: .zero)
        #expect(!alignment.isReady)
    }

    @Test func recognisedSignTakesOverFromGPS() throws {
        var alignment = GeoAlignment()
        alignment.addFix(location(coordinate(east: 15, north: -8), accuracy: 12), cameraPosition: .zero)
        let stop = coordinate(east: 30, north: 40)
        let signPosition = SIMD3<Float>(25, 1.5, -45)
        alignment.addSign(at: signPosition, coordinate: stop)

        #expect(alignment.isCorrectedBySign)
        #expect(alignment.expectedError == 2)
        let position = try #require(alignment.position(of: stop, y: 1.5))
        #expect(simd_distance(position, signPosition) < 0.01)

        // Far from the sign, AR drift adds up: GPS takes over again.
        alignment.addFix(location(here), cameraPosition: SIMD3(400, 0, 0))
        #expect(!alignment.isCorrectedBySign)
    }
}

struct StopPinTests {
    @Test func distancesAreRounded() {
        #expect(StopPinEntity.roundedDistance(42) == 40)
        #expect(StopPinEntity.roundedDistance(43) == 45)
        #expect(StopPinEntity.roundedDistance(123) == 120)
        #expect(StopPinEntity.roundedDistance(386) == 390)
    }

    @Test func labelsGrowWithDistanceWithinLimits() {
        #expect(StopPinEntity.width(atDistance: 0) == 1.2)
        #expect(StopPinEntity.width(atDistance: 100) > StopPinEntity.width(atDistance: 50))
        #expect(StopPinEntity.width(atDistance: 10_000) == 36)
    }

    @Test func serviceFindsStopsAroundTheUserNearestFirst() async throws {
        let fixture = try GTFSFixture()
        _ = try fixture.load()
        try ISO8601DateFormatter().string(from: .now)
            .write(to: fixture.directory.appendingPathComponent("downloaded-at.txt"), atomically: true, encoding: .utf8)
        let service = DepartureService(
            timetableStore: TimetableStore(directory: fixture.directory),
            realtimeClient: RealtimeClient(apiKey: { nil })
        )
        // 100 m north of stop 271.
        let user = CLLocationCoordinate2D(latitude: 53.3495, longitude: -6.259485)

        let near = try await service.arStops(around: user, radius: 400, limit: 25)
        #expect(near.map(\.stop.code) == ["271"])
        #expect(near.first?.routes == ["11", "27", "44"])

        // Ballymun Rd is about 4 km north.
        let wide = try await service.arStops(around: user, radius: 5000, limit: 25)
        #expect(wide.map(\.stop.code) == ["271", "115"])
        #expect(try await service.arStops(around: user, radius: 5000, limit: 1).count == 1)
    }
}
