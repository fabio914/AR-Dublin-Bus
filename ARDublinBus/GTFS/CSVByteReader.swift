import Foundation

/// Reads large GTFS CSV files (`stop_times.txt`, `shapes.txt`) quickly: the file is
/// memory-mapped and fields are read as byte ranges, without building a `String`
/// per field. Lines containing quotes are parsed with `CSV.parseLine` instead.
///
/// The hot loops use `memchr`/`memcmp` rather than per-byte Swift, so this stays fast
/// in unoptimised Debug builds too.
enum CSVByteReader {
    typealias Bytes = UnsafeBufferPointer<UInt8>

    /// One data row. Only valid during the callback.
    struct Row {
        fileprivate let base: UnsafePointer<UInt8>
        fileprivate let starts: UnsafeBufferPointer<Int>
        fileprivate let ends: UnsafeBufferPointer<Int>
        fileprivate let columns: [Int]

        /// The bytes of the `index`-th requested column, trimmed of spaces.
        func field(_ index: Int) -> Bytes {
            let column = columns[index]
            guard column < starts.count else { return Bytes(start: nil, count: 0) }
            var start = starts[column], end = ends[column]
            while start < end, base[start] == 0x20 { start += 1 }
            while end > start, base[end - 1] == 0x20 { end -= 1 }
            return Bytes(start: base + start, count: end - start)
        }

        func string(_ index: Int) -> String { String(decoding: field(index), as: UTF8.self) }
        func int(_ index: Int) -> Int? { CSVByteReader.parseInt(field(index)) }
        func double(_ index: Int) -> Double? { CSVByteReader.parseDouble(field(index)) }
        /// A GTFS time (`H:MM:SS`, hours may exceed 23) in seconds.
        func time(_ index: Int) -> Int? { CSVByteReader.parseTime(field(index)) }
    }

    /// Calls `body` for every data row of the file, with `columns` resolved from the header.
    /// Throws if a column is missing.
    static func forEachRow(in url: URL, columns names: [String], _ body: (Row) throws -> Void) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let raw = buffer.baseAddress, buffer.count > 0 else { return }
            let base = raw.assumingMemoryBound(to: UInt8.self)
            let count = buffer.count

            /// Offset of the next `byte` in `from..<to`, or `to`.
            func find(_ byte: UInt8, from: Int, to: Int) -> Int {
                guard from < to, let found = memchr(base + from, Int32(byte), to - from) else { return to }
                return raw.distance(to: UnsafeRawPointer(found))
            }

            let newline = UInt8(ascii: "\n"), comma = UInt8(ascii: ","), quote = UInt8(ascii: "\""), cr = UInt8(ascii: "\r")
            let headerEnd = find(newline, from: 0, to: count)
            let header = CSV.columnIndex(for: CSV.parseLine(String(decoding: Bytes(start: base, count: headerEnd), as: UTF8.self)))
            let columns = try names.map { name in
                guard let index = header[name] else { throw TimetableError.missingColumns(file: url.lastPathComponent) }
                return index
            }

            var starts = [Int](repeating: 0, count: 64)
            var ends = [Int](repeating: 0, count: 64)
            /// Holds the fields of a quoted line once unescaped.
            var unquoted: [UInt8] = []
            var lineStart = headerEnd + 1

            while lineStart < count {
                let newlineAt = find(newline, from: lineStart, to: count)
                var lineEnd = newlineAt
                if lineEnd > lineStart, base[lineEnd - 1] == cr { lineEnd -= 1 }
                defer { lineStart = newlineAt + 1 }
                guard lineEnd > lineStart else { continue }

                if find(quote, from: lineStart, to: lineEnd) == lineEnd {
                    var fields = 0
                    var fieldStart = lineStart
                    while fields < starts.count {
                        let fieldEnd = find(comma, from: fieldStart, to: lineEnd)
                        starts[fields] = fieldStart
                        ends[fields] = fieldEnd
                        fields += 1
                        if fieldEnd == lineEnd { break }
                        fieldStart = fieldEnd + 1
                    }
                    try starts.withUnsafeBufferPointer { starts in
                        try ends.withUnsafeBufferPointer { ends in
                            try body(Row(base: base, starts: UnsafeBufferPointer<Int>(rebasing: starts.prefix(fields)),
                                         ends: UnsafeBufferPointer<Int>(rebasing: ends.prefix(fields)), columns: columns))
                        }
                    }
                } else {
                    // Quoted fields may contain commas and escaped quotes: parse properly,
                    // then lay the fields out in `unquoted` so the row reads the same way.
                    let line = String(decoding: Bytes(start: base + lineStart, count: lineEnd - lineStart), as: UTF8.self)
                    let parsed = CSV.parseLine(line).prefix(starts.count)
                    unquoted.removeAll(keepingCapacity: true)
                    for (index, field) in parsed.enumerated() {
                        starts[index] = unquoted.count
                        unquoted.append(contentsOf: field.utf8)
                        ends[index] = unquoted.count
                    }
                    try unquoted.withUnsafeBufferPointer { storage in
                        let storageBase = storage.baseAddress ?? base
                        try starts.withUnsafeBufferPointer { starts in
                            try ends.withUnsafeBufferPointer { ends in
                                try body(Row(base: storageBase, starts: UnsafeBufferPointer<Int>(rebasing: starts.prefix(parsed.count)),
                                             ends: UnsafeBufferPointer<Int>(rebasing: ends.prefix(parsed.count)), columns: columns))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Whether two byte buffers hold the same bytes.
    static func equal(_ lhs: Bytes, _ rhs: Bytes) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard let left = lhs.baseAddress, let right = rhs.baseAddress else { return lhs.count == 0 }
        return memcmp(left, right, lhs.count) == 0
    }

    static func parseInt(_ bytes: Bytes) -> Int? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        var index = 0
        let negative = base[0] == UInt8(ascii: "-")
        if negative { index = 1 }
        guard index < bytes.count else { return nil }
        var value = 0
        while index < bytes.count {
            let digit = Int(base[index]) - 48
            guard digit >= 0, digit <= 9 else { return nil }
            value = value * 10 + digit
            index += 1
        }
        return negative ? -value : value
    }

    /// Parses plain decimal numbers such as `53.3486` or `-6.2595` (no exponents).
    static func parseDouble(_ bytes: Bytes) -> Double? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        var index = 0
        let negative = base[0] == UInt8(ascii: "-")
        if negative || base[0] == UInt8(ascii: "+") { index = 1 }
        guard index < bytes.count else { return nil }
        var mantissa: Int64 = 0
        var significantDigits = 0
        var scale = 0
        var seenPoint = false
        while index < bytes.count {
            let byte = base[index]
            index += 1
            if byte == UInt8(ascii: ".") {
                guard !seenPoint else { return nil }
                seenPoint = true
                continue
            }
            let digit = Int64(byte) - 48
            guard digit >= 0, digit <= 9 else { return nil }
            // Beyond 17 significant digits extra precision is meaningless.
            if significantDigits < 17 {
                mantissa = mantissa * 10 + digit
                if mantissa > 0 { significantDigits += 1 }
                if seenPoint { scale += 1 }
            } else if !seenPoint {
                scale -= 1
            }
        }
        let value = Double(mantissa) / pow(10, Double(scale))
        return negative ? -value : value
    }

    static func parseTime(_ bytes: Bytes) -> Int? {
        guard let base = bytes.baseAddress else { return nil }
        var total = 0, current = 0
        var part = 0
        var digitsInPart = 0
        var index = 0
        while index < bytes.count {
            let byte = base[index]
            index += 1
            if byte == UInt8(ascii: ":") {
                guard digitsInPart > 0, part < 2 else { return nil }
                total = (total + current) * 60
                current = 0
                part += 1
                digitsInPart = 0
            } else {
                let digit = Int(byte) - 48
                guard digit >= 0, digit <= 9 else { return nil }
                current = current * 10 + digit
                digitsInPart += 1
            }
        }
        guard part == 2, digitsInPart > 0 else { return nil }
        return total + current
    }
}
