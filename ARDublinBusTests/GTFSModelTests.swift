import Foundation
import Testing
@testable import ARDublinBus

struct GTFSModelTests {
    @Test func parsesTimesIncludingAfterMidnight() {
        #expect(GTFSTime.seconds(from: "08:10:00") == 29_400)
        #expect(GTFSTime.seconds(from: " 8:10:05") == 29_405)
        #expect(GTFSTime.seconds(from: "25:00:00") == 90_000)
        #expect(GTFSTime.seconds(from: "nonsense") == nil)
    }

    @Test func parsesDates() {
        let date = GTFSDate(string: "20261116")
        #expect(date == GTFSDate(year: 2026, month: 11, day: 16))
        #expect(date?.description == "20261116")
        #expect(GTFSDate(string: "2026-11-16") == nil)
    }

    @Test func weekdayIndexIsMondayFirst() {
        #expect(GTFSDate(year: 2026, month: 11, day: 16).weekdayIndex() == 0) // Monday
        #expect(GTFSDate(year: 2026, month: 11, day: 15).weekdayIndex() == 6) // Sunday
    }

    @Test func addingDaysCrossesMonths() {
        #expect(GTFSDate(year: 2026, month: 11, day: 30).adding(days: 1) == GTFSDate(year: 2026, month: 12, day: 1))
        #expect(GTFSDate(year: 2027, month: 1, day: 1).adding(days: -1) == GTFSDate(year: 2026, month: 12, day: 31))
    }

    @Test func serviceDayReferenceIsMidnightOnNormalDays() {
        let reference = GTFSDate(year: 2026, month: 11, day: 16).serviceDayReference()
        #expect(reference == Date.dublin(2026, 11, 16, 0, 0))
    }

    @Test func serviceDayReferenceIsNoonMinus12hOnDSTDays() {
        // Clocks go back on 25 October 2026: "noon minus 12h" is 01:00 local, not midnight.
        let reference = GTFSDate(year: 2026, month: 10, day: 25).serviceDayReference()
        #expect(reference.addingTimeInterval(12 * 3600) == Date.dublin(2026, 10, 25, 12, 0))
        #expect(reference != Date.dublin(2026, 10, 25, 0, 0))
    }

    @Test func serviceCalendarAppliesExceptions() throws {
        let services = try GTFSFixture().load().services
        let monday = GTFSDate(year: 2026, month: 11, day: 16)
        let saturday = GTFSDate(year: 2026, month: 11, day: 21)
        let christmas = GTFSDate(year: 2026, month: 12, day: 25) // a Friday
        let nextYear = GTFSDate(year: 2027, month: 1, day: 4)

        #expect(services.isActive("WK", on: monday))
        #expect(!services.isActive("WK", on: saturday))
        #expect(services.isActive("WE", on: saturday))
        #expect(!services.isActive("WK", on: christmas))
        #expect(services.isActive("WE", on: christmas))
        #expect(!services.isActive("WK", on: nextYear))
        #expect(!services.isActive("unknown", on: monday))
    }
}
