import Foundation

/// A stop found by `StopSearchIndex`, with the routes that call there.
struct StopSearchResult: Identifiable, Hashable, Sendable {
    let stop: GTFSStop
    /// Route short names, sorted naturally ("11", "44", "122").
    let routes: [String]

    var id: String { stop.code }
}

/// Finds stops by number or by name, as the user types.
///
/// Numbers match stop codes by prefix. Names match word by word, ignoring case, accents
/// and punctuation ("oconnell" finds "O'Connell St Lwr"), and the abbreviations used in
/// stop names are understood ("street" or "str" also finds "St").
struct StopSearchIndex: Sendable {
    private struct Entry: Sendable {
        let stop: GTFSStop
        let words: [String]
    }

    private let entries: [Entry]

    /// One entry per stop code.
    init(stopsByCode: [String: [GTFSStop]]) {
        entries = stopsByCode.values.compactMap { stops in
            stops.first.map { Entry(stop: $0, words: Self.words(in: $0.name)) }
        }
    }

    func search(_ query: String, limit: Int) -> [GTFSStop] {
        let tokens = Self.words(in: query)
        guard !tokens.isEmpty else { return [] }

        if tokens.count == 1, tokens[0].allSatisfy(\.isNumber) {
            let number = String(tokens[0].drop { $0 == "0" })
            guard !number.isEmpty else { return [] }
            return entries
                .filter { $0.stop.code.hasPrefix(number) }
                .sorted { ($0.stop.code.count, Int($0.stop.code) ?? .max) < ($1.stop.code.count, Int($1.stop.code) ?? .max) }
                .prefix(limit)
                .map(\.stop)
        }

        let variants = tokens.map(Self.variants(of:))
        var matches: [(entry: Entry, score: Int)] = []
        for entry in entries {
            var score = 0
            for tokenVariants in variants {
                let best = Self.score(tokenVariants, in: entry.words)
                guard best > 0 else { score = 0; break }
                score += best
            }
            guard score > 0 else { continue }
            // Names that start with what was typed come first.
            if let first = entry.words.first, variants[0].contains(where: { first.hasPrefix($0.text) }) { score += 2 }
            matches.append((entry, score))
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.entry.stop.name != rhs.entry.stop.name {
                    return lhs.entry.stop.name.localizedStandardCompare(rhs.entry.stop.name) == .orderedAscending
                }
                return (Int(lhs.entry.stop.code) ?? .max) < (Int(rhs.entry.stop.code) ?? .max)
            }
            .prefix(limit)
            .map(\.entry.stop)
    }

    // MARK: Matching

    private struct Variant: Hashable {
        let text: String
        /// Abbreviations must match a whole word ("e" for "east" mustn't match every word starting with e).
        let wholeWordOnly: Bool
    }

    /// 3 for a whole word, 2 for the start of a word, 1 for the middle of one; 0 if absent.
    private static func score(_ variants: [Variant], in words: [String]) -> Int {
        var best = 0
        for variant in variants {
            for word in words {
                if word == variant.text { return 3 }
                guard !variant.wholeWordOnly else { continue }
                if word.hasPrefix(variant.text) { best = max(best, 2) }
                else if variant.text.count >= 3, word.contains(variant.text) { best = max(best, 1) }
            }
        }
        return best
    }

    /// Words used in full or abbreviated in Dublin Bus stop names.
    static let abbreviations: [(word: String, abbreviation: String)] = [
        ("street", "st"), ("saint", "st"), ("road", "rd"), ("avenue", "ave"), ("upper", "upr"), ("lower", "lwr"),
        ("north", "nth"), ("south", "sth"), ("east", "e"), ("west", "w"), ("green", "grn"), ("square", "sq"),
        ("terrace", "tce"), ("place", "pl"), ("park", "pk"), ("bridge", "br"), ("station", "stn"),
        ("church", "ch"), ("drive", "dr"), ("crescent", "cres"), ("court", "ct"), ("gardens", "gdns"),
        ("hospital", "hosp"), ("cross", "x"), ("centre", "ctr"), ("lane", "ln"), ("college", "coll"),
    ]

    private static func variants(of token: String) -> [Variant] {
        var variants: Set<Variant> = [Variant(text: token, wholeWordOnly: false)]
        for (word, abbreviation) in abbreviations {
            // "str", "stre"… are on their way to "street", so also look for "st".
            if token.count >= 3, word.hasPrefix(token) {
                variants.insert(Variant(text: abbreviation, wholeWordOnly: true))
            }
            if token == abbreviation {
                variants.insert(Variant(text: word, wholeWordOnly: false))
            }
        }
        return Array(variants)
    }

    /// Lowercased words without accents or punctuation; apostrophes and dots are dropped
    /// rather than splitting words ("O'Connell" → "oconnell").
    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_IE"))
            .filter { !"'’‘.".contains($0) }
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Finds routes by number or by name, as the user types.
///
/// A single word matches route numbers by prefix ("27" finds 27, 27A, 27B…; "c" finds C1, C2…).
/// Otherwise every word must match the start of a word of the route's name ("clare" finds
/// "Jobstown - Clare Hall"), or the route's number ("27 clare").
enum RouteSearch {
    static func search(_ query: String, in routes: some Sequence<GTFSRoute>, limit: Int) -> [GTFSRoute] {
        let tokens = StopSearchIndex.words(in: query)
        guard !tokens.isEmpty else { return [] }

        var matches: [(route: GTFSRoute, rank: Int)] = []
        for route in routes {
            let number = StopSearchIndex.words(in: route.shortName).joined()
            let words = StopSearchIndex.words(in: route.longName)
            let rank: Int
            if tokens == [number] {
                rank = 0
            } else if tokens.count == 1, number.hasPrefix(tokens[0]) {
                rank = 1
            } else if tokens.allSatisfy({ token in token == number || words.contains { $0.hasPrefix(token) } }) {
                rank = 2
            } else {
                continue
            }
            matches.append((route, rank))
        }

        return matches
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                let order = lhs.route.shortName.localizedStandardCompare(rhs.route.shortName)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.route.longName < rhs.route.longName
            }
            .prefix(limit)
            .map(\.route)
    }
}
