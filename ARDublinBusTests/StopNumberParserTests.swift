import Testing
@testable import ARDublinBus

struct StopNumberParserTests {
    @Test(arguments: [
        (["Stop 271"], "271"),
        (["STOP271"], "271"),
        (["Stop  27I"], "271"),        // letter I for 1
        (["St0p 1l5"], "115"),           // zero in "Stop", l for 1
        (["Stad 7613"], "7613"),         // Irish
        (["Stop No. 4521"], "4521"),
        (["271"], "271"),              // number alone in the tight crop
        (["O'Connell St Lwr", "Stop 271"], "271"),
    ])
    func readsStopNumbers(text: [String], expected: String) {
        #expect(StopNumberParser.stopNumber(in: text) == expected)
    }

    @Test func findsTheWholeLabel() throws {
        let text = "Bus Stop 271 here"
        let label = try #require(StopNumberParser.label(in: text))
        #expect(label.number == "271")
        #expect(text[label.range] == "Stop 271")
        #expect(StopNumberParser.label(in: "15a 15b 44") == nil)
    }

    /// Round signs print "Stop" or "STOP NO." on one line and the number on the next.
    @Test func readsTwoLineLabels() {
        #expect(StopNumberParser.keywordLine("Stop") == .stop)
        #expect(StopNumberParser.keywordLine("St0p ") == .stop)
        #expect(StopNumberParser.keywordLine("Stad") == .stop)
        #expect(StopNumberParser.keywordLine("STOP NO.") == .stopNumber)
        #expect(StopNumberParser.keywordLine("Stop No") == .stopNumber)
        #expect(StopNumberParser.keywordLine("Stop 271") == nil)
        #expect(StopNumberParser.keywordLine("Bus Stop") == nil)
        #expect(StopNumberParser.keywordLine("Stopping") == nil)

        #expect(StopNumberParser.numberLine("2383") == "2383")
        #expect(StopNumberParser.numberLine(" 2O02 ") == "2002")
        #expect(StopNumberParser.numberLine("2OO2") == nil) // as many letters as digits
        #expect(StopNumberParser.numberLine("SOS") == nil)
        #expect(StopNumberParser.numberLine("44d") == nil)
        #expect(StopNumberParser.numberLine("15 44") == nil)
    }

    @Test func doesNotTurnWordsIntoNumbers() {
        #expect(StopNumberParser.stopNumber(in: ["Stop Sd Uí Chonaill"]) == nil)
        #expect(StopNumberParser.stopNumber(in: ["Bus Stop"]) == nil)
        #expect(StopNumberParser.stopNumber(in: ["SOS"]) == nil)
    }

    @Test func prefersStopKeywordOverRouteNumbers() {
        #expect(StopNumberParser.stopNumber(in: ["11 44 44d", "53 122", "Stop 115"]) == "115")
    }

    @Test func requireKeywordIgnoresRouteNumbers() {
        #expect(StopNumberParser.stopNumber(in: ["11", "122"], requireKeyword: true) == nil)
        #expect(StopNumberParser.stopNumber(in: ["11", "122"]) == "122")
    }

    @Test func normalizeRejectsJunk() {
        #expect(StopNumberParser.normalize("0") == nil)
        #expect(StopNumberParser.normalize("1234567") == nil)
        #expect(StopNumberParser.normalize("0115") == "115")
        #expect(StopNumberParser.normalize("12a") == nil)
    }

    @Test func consensusNeedsRepeatedReadings() {
        var consensus = ReadingConsensus(required: 2)
        #expect(consensus.record("271") == nil)
        #expect(consensus.record("277") == nil)
        #expect(consensus.record("271") == "271")
        consensus.reset()
        #expect(consensus.counts.isEmpty)
    }
}
