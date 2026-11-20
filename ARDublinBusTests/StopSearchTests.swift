import Foundation
import Testing
@testable import ARDublinBus

struct StopSearchTests {
    let index = StopSearchIndex(stopsByCode: Dictionary(grouping: [
        GTFSStop(id: "a", code: "271", name: "O'Connell St Lwr", latitude: nil, longitude: nil),
        GTFSStop(id: "b", code: "277", name: "O'Connell St Upper", latitude: nil, longitude: nil),
        GTFSStop(id: "c", code: "818", name: "O'Connell Avenue", latitude: nil, longitude: nil),
        GTFSStop(id: "d", code: "404", name: "Nassau Street", latitude: nil, longitude: nil),
        GTFSStop(id: "e", code: "842", name: "Stephen's Grn E", latitude: nil, longitude: nil),
        GTFSStop(id: "f", code: "2711", name: "Áras an Uachtaráin", latitude: nil, longitude: nil),
        GTFSStop(id: "g", code: "115", name: "Ballymun Rd, Ch", latitude: nil, longitude: nil),
        GTFSStop(id: "h", code: "7", name: "Parnell Sq West", latitude: nil, longitude: nil),
        GTFSStop(id: "i", code: "900", name: "Emmet Road", latitude: nil, longitude: nil),
    ], by: \.code))

    private func codes(_ query: String) -> [String] {
        index.search(query, limit: 10).map(\.code)
    }

    @Test func numbersMatchStopCodesByPrefix() {
        #expect(codes("271") == ["271", "2711"])
        #expect(codes("27") == ["271", "277", "2711"])
        #expect(codes("0271") == codes("271")) // leading zeros are ignored
        #expect(codes("9999").isEmpty)
    }

    @Test func namesIgnoreCaseAccentsAndPunctuation() {
        #expect(Set(codes("oconnell")) == ["271", "277", "818"])
        #expect(Set(codes("O'CONNELL")) == ["271", "277", "818"])
        #expect(codes("aras") == ["2711"])
        #expect(codes("stephens") == ["842"])
        #expect(codes("connell").count == 3) // middle of a word
    }

    @Test func everyWordMustMatch() {
        #expect(codes("oconnell lwr") == ["271"])
        #expect(codes("oconnell up") == ["277"])
        #expect(codes("oconnell nassau").isEmpty)
    }

    @Test func understandsAbbreviations() {
        #expect(codes("o'connell street lower") == ["271"])
        #expect(codes("oconnell stre lowe") == ["271"]) // still typing
        #expect(codes("ballymun road church") == ["115"])
        #expect(codes("parnell square") == ["7"])
        #expect(codes("stephens green east") == ["842"])
        // "Nassau Street" is spelled out, and still found by the abbreviation.
        #expect(codes("nassau st") == ["404"])
    }

    @Test func abbreviationsOnlyMatchWholeWords() {
        // "eas" is on its way to "east", so it finds the word "E", but not every word starting with "e".
        #expect(codes("eas") == ["842"])
    }

    @Test func namesStartingWithTheQueryComeFirst() {
        let results = codes("st")
        #expect(results.first == "842") // "Stephen's…" starts with "st"
    }

    @Test func emptyQueryFindsNothing() {
        #expect(codes("").isEmpty)
        #expect(codes("  ").isEmpty)
        #expect(codes("'").isEmpty)
    }

    @Test func timetableSearchIncludesRoutes() throws {
        let timetable = try GTFSFixture().load()
        let results = try timetable.searchStops("o'connell", limit: 10)
        #expect(results.map(\.stop.code) == ["271"])
        #expect(results.first?.routes == ["11", "27", "44"])
    }

    @Test(.enabled(if: RealGTFS.directory != nil))
    func realFeedSearch() throws {
        let timetable = try RealGTFS.timetable()
        var results: [StopSearchResult] = []
        let elapsed = try ContinuousClock().measure { results = try timetable.searchStops("oconnell st", limit: 30) }
        print("Real feed: \"oconnell st\" → \(results.count) stops in \(elapsed):", results.map { "\($0.stop.code) \($0.stop.name) \($0.routes)" })
        #expect(results.contains { $0.stop.code == "271" })
        #expect(results.first { $0.stop.code == "271" }?.routes.contains("11") == true)
    }
}

struct RouteSearchTests {
    let routes = [
        RouteSearchResult(route: GTFSRoute(id: "r27", shortName: "27", longName: "Jobstown - Clare Hall"),
                          destinations: ["Jobstown", "Clare Hall", "Eden Quay"]),
        RouteSearchResult(route: GTFSRoute(id: "r27a", shortName: "27A", longName: "Blunden Drive - Eden Quay"),
                          destinations: ["Eden Quay", "Blunden Drive"]),
        RouteSearchResult(route: GTFSRoute(id: "r27x", shortName: "27X", longName: "Clare Hall - UCD Belfield"),
                          destinations: ["UCD", "Clare Hall"]),
        RouteSearchResult(route: GTFSRoute(id: "r7", shortName: "7", longName: "Brides Glen - Mountjoy Sq"), destinations: []),
        RouteSearchResult(route: GTFSRoute(id: "rc1", shortName: "C1", longName: "Adamstown Stn - Sandymount"),
                          destinations: ["Adamstown Station", "Sandymount"]),
        RouteSearchResult(route: GTFSRoute(id: "r11", shortName: "11", longName: "Wadelai Park - Sandyford"),
                          destinations: ["Sandyford B.D.", "Phoenix Pk"]),
    ]

    private func numbers(_ query: String) -> [String] {
        RouteSearch.search(query, in: routes, limit: 10).map(\.route.shortName)
    }

    @Test func numbersMatchByPrefixExactFirst() {
        #expect(numbers("27") == ["27", "27A", "27X"])
        #expect(numbers("27a") == ["27A"])
        #expect(numbers("7") == ["7"])
        #expect(numbers("99").isEmpty)
    }

    @Test func namesMatchWordStarts() {
        #expect(numbers("clare hall") == ["27", "27X"])
        #expect(numbers("Sandy") == ["11", "C1"])
        #expect(numbers("hall clare") == ["27", "27X"]) // in any order
        #expect(numbers("lare").isEmpty) // only the starts of words
    }

    @Test func destinationsMatchToo() {
        // The 27 also goes to Eden Quay, though its name doesn't say so.
        #expect(numbers("eden quay") == ["27", "27A"])
        #expect(numbers("phoenix") == ["11"])
        #expect(numbers("ucd") == ["27X"])
    }

    @Test func numberAndNameTogether() {
        #expect(numbers("27 clare") == ["27"])
        // A letter is the start of route numbers (C1) before it's the start of names.
        #expect(numbers("c").first == "C1")
    }

    @Test func emptyQueryFindsNothing() {
        #expect(numbers("").isEmpty)
        #expect(numbers(" - ").isEmpty)
    }
}
