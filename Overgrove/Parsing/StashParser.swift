import Foundation

/// Parses `git log -g -z --format=%gd%x00%H%x00%gs%x00%ct%x00%P refs/stash` (parsing-spec.md §4).
///
/// Every field is NUL-terminated, so tokens are grouped by five. A malformed field or a token count that is not a
/// multiple of five fails the whole parse: a shifted group would attach one stash's OID to another's subject.
///
/// Stashes are addressed by `%H` (the OID), never by `stash@{n}`, because `n` shifts when stashes are added or dropped.
/// The OID is validated strictly; the subject is display-only and is decoded lossily when it is not UTF-8.
enum StashParser {
    struct Listing: Sendable, Equatable {
        /// Newest first, in git's order.
        let stashes: [Stash]
        /// The output was cut at the size limit and the incomplete last record was dropped.
        let isPartial: Bool
    }

    private static let name = "StashParser"
    private static let fieldCount = 5

    private typealias Token = Data.SubSequence

    static func parse(_ data: Data, truncated: Bool = false) throws -> Listing {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        // `split` yields one trailing token after the final NUL: empty for complete output, a fragment otherwise.
        let trailing = tokens.removeLast()
        let leftover = tokens.count % fieldCount
        if truncated {
            // Records proven complete by their final NUL are kept; only the cut group goes.
            tokens.removeLast(leftover)
        } else if leftover != 0 || !trailing.isEmpty {
            let start = leftover != 0 ? tokens[tokens.count - leftover] : trailing
            throw ParseError(parser: name, offset: offset(of: start, in: data), reason: "incomplete record")
        }

        var stashes: [Stash] = []
        stashes.reserveCapacity(tokens.count / fieldCount)
        for start in stride(from: 0, to: tokens.count, by: fieldCount) {
            stashes.append(try stash(tokens[start..<start + fieldCount], in: data))
        }
        return Listing(stashes: stashes, isPartial: truncated)
    }

    // MARK: - Fields

    private static func stash(_ fields: ArraySlice<Token>, in data: Data) throws -> Stash {
        let start = fields.startIndex
        let index = try selectorIndex(fields[start], in: data)
        let oid = try stashOID(fields[start + 1], in: data)
        let date = try time(fields[start + 3], in: data)
        let parents = try parentOIDs(fields[start + 4], in: data)
        let subject = fields[start + 2]
        let (branch, message) = split(subject: subject)
        return Stash(
            index: index,
            oid: oid,
            subject: String(decoding: subject, as: UTF8.self),
            branch: branch,
            message: message ?? String(decoding: subject, as: UTF8.self),
            date: date,
            parents: parents
        )
    }

    private static func offset(of token: Token, in data: Data) -> Int {
        token.startIndex - data.startIndex
    }

    private static let selectorPrefix = Data("stash@{".utf8)

    /// `stash@{n}` with `n` an unsigned decimal integer (parsing-spec.md §1.8).
    private static func selectorIndex(_ token: Token, in data: Data) throws -> Int {
        let invalid = ParseError(parser: name, offset: offset(of: token, in: data), reason: "invalid stash selector")
        guard token.starts(with: selectorPrefix), token.last == UInt8(ascii: "}") else { throw invalid }
        let digits = token.dropFirst(selectorPrefix.count).dropLast()
        guard let index = decimal(digits, as: Int.self) else { throw invalid }
        return index
    }

    /// The OID goes back to git as an argument, so it must be exactly 40 or 64 lowercase hex bytes.
    private static func stashOID(_ token: Token, in data: Data) throws -> ObjectID {
        guard token.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }),
            let oid = ObjectID(String(decoding: token, as: UTF8.self))
        else { throw ParseError(parser: name, offset: offset(of: token, in: data), reason: "invalid stash OID") }
        return oid
    }

    /// `%P`: one to three OIDs separated by single spaces (a stash commit always has at least the base).
    private static func parentOIDs(_ token: Token, in data: Data) throws -> [ObjectID] {
        let parts = token.split(separator: 0x20, omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else {
            throw ParseError(parser: name, offset: offset(of: token, in: data), reason: "invalid parent list")
        }
        return try parts.map { try stashOID($0, in: data) }
    }

    /// `%ct`: epoch seconds, unsigned decimal.
    private static func time(_ token: Token, in data: Data) throws -> Date {
        guard let seconds = decimal(token, as: Int64.self) else {
            throw ParseError(parser: name, offset: offset(of: token, in: data), reason: "invalid time")
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// ASCII digits only: no sign, no whitespace, no other numerals. `nil` on overflow.
    private static func decimal<T: FixedWidthInteger>(_ bytes: Token, as _: T.Type) -> T? {
        guard !bytes.isEmpty, bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return T(String(decoding: bytes, as: UTF8.self))
    }

    // MARK: - Subject

    private static let wipPrefix = Data("WIP on ".utf8)
    private static let onPrefix = Data("On ".utf8)
    private static let separator = Data(": ".utf8)

    /// Applies `^(WIP on|On) (.+?): (.*)$` to the reflog subject. Returns `(nil, nil)` when it does not match, so the
    /// subject is shown verbatim. Only valid UTF-8 subjects match: a lossily decoded branch would name another ref.
    private static func split(subject: Token) -> (branch: String?, message: String?) {
        guard String(data: Data(subject), encoding: .utf8) != nil, !containsLineTerminator(subject) else {
            return (nil, nil)
        }
        let rest: Token
        if subject.starts(with: wipPrefix) {
            rest = subject.dropFirst(wipPrefix.count)
        } else if subject.starts(with: onPrefix) {
            rest = subject.dropFirst(onPrefix.count)
        } else {
            return (nil, nil)
        }
        // `.+?` takes at least one byte, so search for the first `: ` after the first byte. Splitting at ASCII bytes
        // keeps both halves valid UTF-8.
        guard !rest.isEmpty, let range = rest.dropFirst().firstRange(of: separator) else { return (nil, nil) }
        let branch = String(decoding: rest[rest.startIndex..<range.lowerBound], as: UTF8.self)
        let message = String(decoding: rest[range.upperBound...], as: UTF8.self)
        return (branch, message)
    }

    /// Regex `.` does not match line terminators, so a subject containing one never matches.
    private static func containsLineTerminator(_ subject: Token) -> Bool {
        String(decoding: subject, as: UTF8.self).unicodeScalars.contains { scalar in
            ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"].contains(scalar)
        }
    }
}
