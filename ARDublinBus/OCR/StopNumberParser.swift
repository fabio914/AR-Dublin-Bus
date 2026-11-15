import Foundation

/// Extracts a stop number from text recognised on a sign such as "Stop 271".
enum StopNumberParser {
    static let maximumDigits = 6

    /// Returns the most plausible stop number among the recognised strings, or `nil`.
    ///
    /// Text following "Stop" (or the Irish "Stad") wins; otherwise the longest
    /// standalone number is used. Letters commonly confused with digits are
    /// corrected inside number-like tokens.
    ///
    /// - Parameter requireKeyword: only accept numbers preceded by "Stop"; use this when
    ///   the text may also contain route numbers.
    static func stopNumber(in candidates: [String], requireKeyword: Bool = false) -> String? {
        for text in candidates {
            if let number = numberAfterKeyword(in: text) { return number }
        }
        guard !requireKeyword else { return nil }

        let numbers = candidates.flatMap(standaloneNumbers(in:))
        return numbers.max { lhs, rhs in lhs.count < rhs.count }
    }

    private static func numberAfterKeyword(in text: String) -> String? {
        let pattern = /(?i)\b(?:st[o0]p|stad)\s*(?:no\.?|number)?\s*[:#]?\s*([0-9OoIlSB]{1,8})\b/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        let token = String(match.1)
        // "Stop Sd…" must not turn into stop 5: the token has to be mostly real digits.
        let digits = token.filter(\.isNumber).count
        guard digits * 2 > token.count else { return nil }
        return normalize(token)
    }

    private static func standaloneNumbers(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap { token -> String? in
                // Require mostly digits so ordinary words are not "corrected" into numbers.
                let digits = token.filter(\.isNumber).count
                guard digits >= 2, digits * 2 > token.count else { return nil }
                return normalize(String(token))
            }
    }

    /// Fixes common OCR confusions and validates the result.
    static func normalize(_ token: String) -> String? {
        let corrected = String(token.map { character -> Character in
            switch character {
            case "O", "o": "0"
            case "I", "l", "|": "1"
            case "S": "5"
            case "B": "8"
            default: character
            }
        })
        guard !corrected.isEmpty,
              corrected.count <= maximumDigits,
              corrected.allSatisfy(\.isASCIIDigit),
              let value = Int(corrected), value > 0 else { return nil }
        return String(value) // drops leading zeros, matching GTFS stop codes
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// Accepts a reading only after it has been seen several times, to filter out OCR noise.
struct ReadingConsensus {
    /// How many times a value must be seen before it is accepted.
    var required: Int
    private(set) var counts: [String: Int] = [:]

    init(required: Int) {
        self.required = required
    }

    /// Records a reading; returns it once it has been seen `required` times.
    mutating func record(_ value: String) -> String? {
        counts[value, default: 0] += 1
        return counts[value, default: 0] >= max(1, required) ? value : nil
    }

    mutating func reset() {
        counts.removeAll()
    }
}
