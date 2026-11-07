import Foundation

/// Parses `git rev-list --left-right --count <upstream>...<local>` (parsing-spec.md §7).
///
/// The output is exactly one line, `<left>\t<right>\n`. `ReadOnlyGitCommand.aheadBehind` puts the upstream (or base)
/// on the left, so left counts commits the local branch is behind and right counts commits it is ahead. Anything
/// else fails: the output is a few bytes, so a cut or extra line means the counts cannot be trusted.
enum RevListParser {
    struct Counts: Sendable, Equatable {
        let behind: Int
        let ahead: Int
    }

    private static let name = "RevListParser"

    static func parse(_ data: Data) throws -> Counts {
        guard let lineFeed = data.firstIndex(of: UInt8(ascii: "\n")) else {
            throw ParseError(parser: name, offset: data.count, reason: "unterminated output")
        }
        guard data.index(after: lineFeed) == data.endIndex else {
            throw ParseError(parser: name, offset: lineFeed + 1 - data.startIndex, reason: "more than one line")
        }
        let line = data[data.startIndex..<lineFeed]
        guard let tab = line.firstIndex(of: UInt8(ascii: "\t")) else {
            throw ParseError(parser: name, offset: 0, reason: "missing tab")
        }
        return Counts(
            behind: try count(line[line.startIndex..<tab], field: "left", in: data),
            ahead: try count(line[line.index(after: tab)...], field: "right", in: data)
        )
    }

    /// ASCII digits only, no sign (parsing-spec.md §1.8).
    private static func count(_ token: Data.SubSequence, field: String, in data: Data) throws -> Int {
        guard !token.isEmpty, token.allSatisfy({ (0x30...0x39).contains($0) }),
            let value = Int(String(decoding: token, as: UTF8.self))
        else {
            throw ParseError(parser: name, offset: token.startIndex - data.startIndex, reason: "invalid \(field) count")
        }
        return value
    }
}
