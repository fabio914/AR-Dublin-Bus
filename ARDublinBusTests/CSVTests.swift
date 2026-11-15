import Testing
@testable import ARDublinBus

struct CSVTests {
    @Test func splitsPlainFields() {
        #expect(CSV.parseLine("a,b,,d") == ["a", "b", "", "d"])
    }

    @Test func handlesQuotesAndEscapes() {
        #expect(CSV.parseLine(#"1,"Ballymun Rd, Ch","say ""hi""",x"#) == ["1", "Ballymun Rd, Ch", #"say "hi""#, "x"])
    }

    @Test func ignoresLineEndings() {
        #expect(CSV.parseLine("a,b\r\n") == ["a", "b"])
    }

    @Test func columnIndexStripsBOMAndSpaces() {
        let columns = CSV.columnIndex(for: ["\u{FEFF}stop_id", " stop_code "])
        #expect(columns["stop_id"] == 0)
        #expect(columns["stop_code"] == 1)
    }

    @Test func iteratesRowsWithCRLF() throws {
        var names: [String] = []
        try CSV.forEachRow(inText: "id,name\r\n1,One\r\n2,\"Two, too\"\r\n") { row in
            names.append(row.value("name") ?? "")
        }
        #expect(names == ["One", "Two, too"])
    }
}
