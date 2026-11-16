import CoreLocation
import Foundation
import Testing
@testable import ARDublinBus

struct StopLinesTests {
    private func point(_ x: Double, _ y: Double) -> CLLocationCoordinate2D {
        // About 1 km per unit, around Dublin.
        CLLocationCoordinate2D(latitude: 53.35 + y * 0.009, longitude: -6.26 + x * 0.015)
    }

    @Test func cutsTheShapeAtTheStop() {
        let shape = (0...10).map { point(Double($0), 0) }
        let stops = [point(0, 0), point(4, 0.01), point(10, 0)]
        let (path, start) = StopLinePath.remainder(of: shape, stops: stops, target: 1)
        #expect(start == 4)
        #expect(path.count == 7)
    }

    @Test func followsTheEarlierStopsAroundALoop() {
        // Out along y = 0, back along y = 0.02 (20 m away): the stop at x = 2 on the way
        // back must match the return leg, not the outward one.
        let out = (0...5).map { point(Double($0), 0) }
        let back = (0...5).reversed().map { point(Double($0), 0.02) }
        let shape = out + back
        let stops = [point(0, 0), point(5, 0.01), point(2, 0.02)]
        let (path, start) = StopLinePath.remainder(of: shape, stops: stops, target: 2)
        #expect(start == 9) // back leg, x = 2
        #expect(path.count == 3)
    }

    @Test func fallsBackToTheStopsWithoutAShape() {
        let stops = [point(0, 0), nil, point(2, 0), point(3, 0)]
        let (path, start) = StopLinePath.remainder(of: [], stops: stops, target: 2)
        #expect(start == nil)
        #expect(path.count == 2)
    }

    @Test func listsEveryRouteLeavingTheStop() throws {
        let timetable = try GTFSFixture().load()
        let lines = try timetable.lines(atStopCode: "271")

        #expect(lines.map(\.route.shortName) == ["11", "27", "44"])
        let route27 = try #require(lines.first { $0.route.shortName == "27" })
        #expect(route27.headsigns == ["Clare Hall"])
        // T1 carries on to the decoy stop; its shape ends at 271, so the stops are used.
        #expect(route27.paths.count == 1)
        #expect(route27.paths.first?.count == 2)
        #expect(route27.paths.first?.first?.latitude == 53.348596)
    }

    @Test func lineColoursSplitTheHueCircle() {
        let (red, green, blue) = LineColour.rgb(hue: 0, saturation: 0.8, brightness: 0.95)
        #expect(abs(red - 0.95) < 1e-9 && abs(green - 0.19) < 1e-9 && abs(blue - 0.19) < 1e-9)
        let (_, green2, _) = LineColour.rgb(hue: 1.0 / 3, saturation: 0.8, brightness: 0.95)
        #expect(abs(green2 - 0.95) < 1e-9)
    }
}
