import Foundation
import Testing
@testable import ARDublinBus

/// The line screen: a route's stops and timetable as seen from one stop.
struct LineDetailsTests {
    let monday = GTFSDate(year: 2026, month: 11, day: 16)
    let saturday = GTFSDate(year: 2026, month: 11, day: 21)

    /// Route 27 from stop 271: three full trips and a shorter one to Clare Hall, one trip to a
    /// depot, and one that ends at 271 (nobody boards it there).
    static let trips = """
    route_id,service_id,trip_id,trip_headsign,direction_id,shape_id
    r27,WK,L1,Clare Hall,0,S1
    r27,WK,L2,Clare Hall,0,S1
    r27,WE,L3,Clare Hall,0,S1
    r27,WK,L4,Clare Hall,0
    r27,WK,L5,Decoy Depot,0
    r27,WK,L6,Clare Hall,0
    r44,WK,L7,Enniskerry,1
    """

    static let stopTimes = """
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,timepoint
    L1,07:50:00,07:50:00,8220DB000115,1,,0,0,1
    L1,08:10:00,08:10:00,8220DB000271,2,,0,0,0
    L1,08:25:00,08:25:00,8220DB0002711,3,,0,0,0
    L2,09:00:00,09:00:00,8220DB000115,1,,0,0,1
    L2,09:20:00,09:20:00,8220DB000271,2,,0,0,0
    L2,09:35:00,09:35:00,8220DB0002711,3,,0,0,0
    L3,10:00:00,10:00:00,8220DB000115,1,,0,0,1
    L3,10:20:00,10:20:00,8220DB000271,2,,0,0,0
    L3,10:35:00,10:35:00,8220DB0002711,3,,0,0,0
    L4,08:40:00,08:40:00,8220DB000271,1,,0,0,0
    L4,08:55:00,08:55:00,8220DB0002711,2,,0,0,0
    L5,11:00:00,11:00:00,8220DB000115,1,,0,0,1
    L5,11:20:00,11:20:00,8220DB000271,2,,0,0,0
    L5,11:35:00,11:35:00,8220DB0002711,3,,0,0,0
    L6,12:00:00,12:00:00,8220DB000115,1,,0,0,1
    L6,12:20:00,12:20:00,8220DB000271,2,,0,0,0
    L7,13:00:00,13:00:00,8220DB000271,1,,0,0,0
    L7,13:30:00,13:30:00,8220DB0002711,2,,0,0,0
    """

    private func load() throws -> StaticTimetable {
        try GTFSFixture(trips: Self.trips, stopTimes: Self.stopTimes).load()
    }

    @Test func groupsTheTripsByDestination() throws {
        let line = try #require(try load().lineDetails(routeID: "r27", stopCode: "271"))
        #expect(line.route.shortName == "27")
        #expect(line.stop?.code == "271")
        #expect(line.directions.map(\.headsign) == ["Clare Hall", "Decoy Depot"])

        let clareHall = line.directions[0]
        // The full trip is the most frequent, so its stops stand for the destination.
        #expect(clareHall.stops.map(\.stop.code) == ["115", "271", "2711"])
        #expect(clareHall.stopIndex == 1)
        #expect(clareHall.stops.map(\.offset) == [-20 * 60, 0, 15 * 60])
        #expect(clareHall.shape.count == 3)
        // L6 ends here, so it isn't a departure.
        #expect(clareHall.departures.map(\.tripID) == ["L1", "L4", "L2", "L3"])
        #expect(clareHall.tripIDs == ["L1", "L2", "L3", "L4"])

        // Without a shape, the path joins the stops.
        #expect(line.directions[1].shape.count == 3)
    }

    @Test func timetableKeepsTheTripsRunningThatDay() throws {
        let line = try #require(try load().lineDetails(routeID: "r27", stopCode: "271"))
        let clareHall = line.directions[0]

        let weekday = clareHall.timetable(on: monday, services: line.services)
        #expect(weekday.map(\.time) == [.dublin(2026, 11, 16, 8, 10), .dublin(2026, 11, 16, 8, 40), .dublin(2026, 11, 16, 9, 20)])
        #expect(weekday.first?.trip == TripReference(tripID: "L1", serviceDate: monday, stopID: GTFSFixture.stopID, stopSequence: 2))
        #expect(weekday[1].trip.stopSequence == 1)

        #expect(clareHall.timetable(on: saturday, services: line.services).map(\.trip.tripID) == ["L3"])
        // On Christmas Day, WK is replaced by WE.
        #expect(clareHall.timetable(on: GTFSDate(year: 2026, month: 12, day: 25), services: line.services).map(\.trip.tripID) == ["L3"])
    }

    @Test func fromTheStartTheTripsLeaveTheirFirstStop() throws {
        let line = try #require(try load().lineDetails(routeID: "r27", stopCode: nil))
        #expect(line.stop == nil)
        #expect(line.directions.map(\.headsign) == ["Clare Hall", "Decoy Depot"])

        let clareHall = line.directions[0]
        // The full trip is the most frequent, so its stops stand for the destination, from its start.
        #expect(clareHall.stops.map(\.stop.code) == ["115", "271", "2711"])
        #expect(clareHall.stopIndex == 0)
        #expect(clareHall.stops.map(\.offset) == [0, 20 * 60, 35 * 60])
        // L6, which ends at 271, leaves its first stop like the others; L4 starts at 271.
        #expect(clareHall.departures.map(\.tripID) == ["L1", "L4", "L2", "L3", "L6"])
        #expect(clareHall.departures.map(\.time) == [7 * 3600 + 50 * 60, 8 * 3600 + 40 * 60, 9 * 3600, 10 * 3600, 12 * 3600])

        let weekday = clareHall.timetable(on: monday, services: line.services)
        #expect(weekday.map(\.trip.tripID) == ["L1", "L4", "L2", "L6"])
        #expect(weekday[0].trip == TripReference(tripID: "L1", serviceDate: monday, stopID: "8220DB000115", stopSequence: 1))
        #expect(weekday[1].trip.stopID == GTFSFixture.stopID)
    }

    @Test func routesListTheirDestinationsMostFrequentFirst() throws {
        let timetable = try load()
        let found = timetable.searchRoutes("decoy", limit: 5)
        #expect(found.map(\.route.id) == ["r27"])
        #expect(found.first?.destinations == ["Clare Hall", "Decoy Depot"])
        #expect(timetable.searchRoutes("44", limit: 5).first?.destinations == ["Enniskerry"])
    }

    @Test func unknownRouteOrStopHasNoLine() throws {
        let timetable = try load()
        #expect(try timetable.lineDetails(routeID: "nope", stopCode: "271") == nil)
        #expect(try timetable.lineDetails(routeID: "nope", stopCode: nil) == nil)
        #expect(try timetable.lineDetails(routeID: "r27", stopCode: "999999") == nil)
        // Route 44 ends at 2711 and never leaves from it.
        #expect(try timetable.lineDetails(routeID: "r44", stopCode: "2711")?.directions.isEmpty == true)
    }
}
