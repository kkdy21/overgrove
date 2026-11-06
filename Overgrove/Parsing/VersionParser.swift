import Foundation

/// Parses `git version` (parsing-spec.md §11.1), e.g. `git version 2.50.1 (Apple Git-155)` → 2.50.1.
enum VersionParser {
    static func parse(_ data: Data) throws -> GitVersion {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "git version "
        guard text.hasPrefix(prefix) else {
            throw ParseError(parser: "VersionParser", offset: 0, reason: "not a git version line")
        }
        // Leading numeric components only: "2.47.0.rc1", "2.35.1.windows.2", "2.50.1 (Apple Git-155)".
        let numbers = text.dropFirst(prefix.count)
            .prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
            .split(separator: ".", omittingEmptySubsequences: false)
            .prefix(3)
            .map { Int($0) }
        guard numbers.count >= 2, numbers.allSatisfy({ $0 != nil }), let major = numbers[0], let minor = numbers[1]
        else { throw ParseError(parser: "VersionParser", offset: prefix.count, reason: "malformed version number") }
        let patch = numbers.count > 2 ? numbers[2] ?? 0 : 0
        return GitVersion(major: major, minor: minor, patch: patch)
    }
}
