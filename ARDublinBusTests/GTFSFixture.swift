import Foundation
@testable import ARDublinBus

/// Writes a tiny GTFS feed to a temporary directory.
struct GTFSFixture {
    let directory: URL

    init(
        stops: String = GTFSFixture.defaultStops,
        routes: String = GTFSFixture.defaultRoutes,
        trips: String = GTFSFixture.defaultTrips,
        stopTimes: String = GTFSFixture.defaultStopTimes,
        calendar: String = GTFSFixture.defaultCalendar,
        calendarDates: String = GTFSFixture.defaultCalendarDates
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gtfs-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = [
            "stops.txt": stops,
            "routes.txt": routes,
            "trips.txt": trips,
            "stop_times.txt": stopTimes,
            "calendar.txt": calendar,
            "calendar_dates.txt": calendarDates,
            "feed_info.txt": "feed_publisher_name,feed_version\nNTA,test-1\n",
        ]
        for (name, contents) in files {
            try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    func load() throws -> StaticTimetable {
        try StaticTimetable.load(from: directory)
    }

    static let stopID = "8220DB000271"

    static let defaultStops = """
    \u{FEFF}stop_id,stop_code,stop_name,stop_desc,stop_lat,stop_lon
    8220DB000271,271,O'Connell St Lwr,,53.348596,-6.259485
    8220DB000115,115,"Ballymun Rd, Ch",,53.38796,-6.26503
    8220DB0002711,2711,Decoy,,53.0,-6.0
    """

    static let defaultRoutes = """
    route_id,agency_id,route_short_name,route_long_name,route_type
    r27,1,27,Jobstown - Clare Hall,3
    r11,1,11,Wadelai Park - Sandyford,3
    r44,1,44,DCU - Enniskerry,3
    """

    static let defaultTrips = """
    route_id,service_id,trip_id,trip_headsign,direction_id
    r27,WK,T1,Clare Hall,0
    r27,WK,T2,Clare Hall,0
    r27,WK,T3,Clare Hall,0
    r44,WK,T4,Enniskerry,1
    r44,WK,T5,Enniskerry,1
    r11,WK,T7,Sandyford,0
    r11,WE,T8,Sandyford,0
    r27,WK,T9,Clare Hall,0
    r27,WK,N1,Clare Hall,0
    r27,WK,T10,Clare Hall,0
    """

    /// T1–T10 call at stop 271 at sequence 10 (T3 at 10 too).
    static let defaultStopTimes = """
    trip_id,arrival_time,departure_time,stop_id,stop_sequence,stop_headsign,pickup_type,drop_off_type,timepoint
    T1,07:50:00,07:50:00,8220DB000115,1,,0,0,1
    T1,08:10:00,08:10:00,8220DB000271,10,,0,0,0
    T2,08:20:00,08:20:00,8220DB000271,10,,0,0,0
    T3,08:05:00,08:05:00,8220DB000271,10,,0,0,0
    T4,08:30:00,08:30:00,8220DB000271,10,,0,0,0
    T5,08:40:00,08:40:00,8220DB000271,10,,0,0,0
    T7,07:30:00,07:30:00,8220DB000271,10,,0,0,0
    T8,08:15:00,08:15:00,8220DB000271,10,,0,0,0
    T9,10:00:00,10:00:00,8220DB000271,10,,0,0,0
    N1,24:35:00,24:35:00,8220DB000271,10,,0,0,0
    T10,08:50:00,08:50:00,8220DB0002711,10,,0,0,0
    T10, 8:55:00, 8:55:00,X8220DB000271,11,,0,0,0
    """

    static let defaultCalendar = """
    service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
    WK,1,1,1,1,1,0,0,20261101,20261231
    WE,0,0,0,0,0,1,1,20261101,20261231
    """

    static let defaultCalendarDates = """
    service_id,date,exception_type
    WK,20261225,2
    WE,20261225,1
    """
}

extension Date {
    /// A wall-clock time in Dublin.
    static func dublin(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Dublin.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}
