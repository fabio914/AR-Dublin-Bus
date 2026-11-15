import Foundation

/// Minimal RFC 4180 CSV helpers, sufficient for GTFS files.
enum CSV {

    /// Splits a single CSV record into its fields, honouring double-quoted fields
    /// and `""` escapes. Trailing `\r`/`\n` characters are ignored.
    static func parseLine<S: StringProtocol>(_ line: S) -> [String] {
        var fields: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        let scalars = Array(line.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    inQuotes = true
                case ",":
                    fields.append(String(field))
                    field = String.UnicodeScalarView()
                case "\r", "\n":
                    break
                default:
                    field.append(scalar)
                }
            }
            index += 1
        }

        fields.append(String(field))
        return fields
    }

    /// Maps header names to column indices. Strips a UTF-8 BOM and surrounding whitespace.
    static func columnIndex(for header: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, rawName) in header.enumerated() {
            let name = rawName
                .replacingOccurrences(of: "\u{FEFF}", with: "")
                .trimmingCharacters(in: .whitespaces)
            result[name] = index
        }
        return result
    }

    /// Calls `body` for every data row of the CSV file at `url`.
    static func forEachRow(in url: URL, _ body: (_ row: Row) throws -> Void) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        try forEachRow(inText: text, body)
    }

    static func forEachRow(inText text: String, _ body: (_ row: Row) throws -> Void) throws {
        var columns: [String: Int]?
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let fields = parseLine(line)
            guard let columns else {
                columns = columnIndex(for: fields)
                continue
            }
            try body(Row(fields: fields, columns: columns))
        }
    }

    struct Row {
        let fields: [String]
        let columns: [String: Int]

        subscript(_ column: String) -> String? {
            guard let index = columns[column], index < fields.count else { return nil }
            return fields[index]
        }

        /// Trimmed, non-empty value for `column`, or `nil`.
        func value(_ column: String) -> String? {
            guard let raw = self[column]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
    }
}
