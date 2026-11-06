import Foundation

/// Parses `git config --list --show-scope -z --includes` (parsing-spec.md §9).
///
/// Format: `scope␀key␊value␀` per entry, or `scope␀key␀` for a valueless boolean. Values may contain line feeds.
/// Order is preserved because credential helpers must be re-inserted in their original order (ADR-0009).
///
/// This output feeds security decisions (`RepoConfigInspector`), so anything unexpected fails closed: an unknown
/// scope is not skipped, because a skipped entry would be an uninspected entry.
enum ConfigParser {
    struct Listing: Sendable, Equatable {
        let entries: [ConfigEntry]
        /// The output was cut at the size limit and the last entry was dropped.
        let isPartial: Bool
    }

    static func parse(_ data: Data, truncated: Bool = false) throws -> Listing {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        if tokens.last?.isEmpty == true { tokens.removeLast() }  // output ends with NUL
        var isPartial = false
        if truncated {
            // The last token may be cut off; dropping it also drops a dangling scope.
            if !tokens.isEmpty { tokens.removeLast() }
            if tokens.count % 2 == 1 { tokens.removeLast() }
            isPartial = true
        }
        guard tokens.count % 2 == 0 else {
            throw ParseError(parser: "ConfigParser", offset: data.count, reason: "scope without an entry")
        }

        var entries: [ConfigEntry] = []
        entries.reserveCapacity(tokens.count / 2)
        var offset = 0
        for index in stride(from: 0, to: tokens.count, by: 2) {
            let scopeToken = tokens[index]
            let entryToken = tokens[index + 1]
            guard let scope = ConfigEntry.Scope(rawValue: String(decoding: scopeToken, as: UTF8.self)) else {
                throw ParseError(parser: "ConfigParser", offset: offset, reason: "unknown scope")
            }
            offset += scopeToken.count + 1
            entries.append(try entry(entryToken, scope: scope, offset: offset))
            offset += entryToken.count + 1
        }
        return Listing(entries: entries, isPartial: isPartial)
    }

    /// Filter driver names that can be safely spliced into `-c filter.<name>.clean=` (security-review.md §3.3).
    /// A driver outside this set cannot be neutralized, so the repository must not be queried (fail closed).
    static func isNeutralizableDriverName(_ name: String) -> Bool {
        let utf8 = name.utf8
        guard (1...64).contains(utf8.count) else { return false }
        return utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    private static func entry(_ token: Data.SubSequence, scope: ConfigEntry.Scope, offset: Int) throws -> ConfigEntry {
        let keyBytes: Data.SubSequence
        let value: String?
        if let newline = token.firstIndex(of: 0x0A) {
            keyBytes = token[token.startIndex..<newline]
            value = String(decoding: token[token.index(after: newline)...], as: UTF8.self)
        } else {
            keyBytes = token
            value = nil
        }
        let key = String(decoding: keyBytes, as: UTF8.self)
        guard let firstDot = key.firstIndex(of: "."), let lastDot = key.lastIndex(of: ".") else {
            throw ParseError(parser: "ConfigParser", offset: offset, reason: "key without a section")
        }
        let section = key[..<firstDot]
        let variable = key[key.index(after: lastDot)...]
        guard !section.isEmpty, !variable.isEmpty else {
            throw ParseError(parser: "ConfigParser", offset: offset, reason: "empty section or variable")
        }
        let subsection = firstDot == lastDot ? nil : String(key[key.index(after: firstDot)..<lastDot])
        return ConfigEntry(
            scope: scope,
            section: section.lowercased(),
            subsection: subsection,
            variable: variable.lowercased(),
            value: value
        )
    }
}
