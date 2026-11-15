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
