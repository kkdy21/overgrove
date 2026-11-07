import Foundation

/// Output of `rev-parse --path-format=absolute --show-toplevel --git-common-dir --is-bare-repository`.
struct RepositoryProbe: Equatable, Sendable {
    /// The worktree that contains the probed folder (a linked worktree's own root, not the main one).
    let topLevel: URL
    /// The repository's shared git directory. Every worktree of one repository reports the same one.
    let commonDirectory: URL
    let isBare: Bool
}

/// Parses the registration probe (parsing-spec.md §11.2).
///
/// git prints one value per line, so the output is accepted only as exactly three LF-terminated lines: two absolute,
/// valid UTF-8 paths without control characters and `true`/`false`. Anything else (a path with a line feed shifts
/// every field after it) fails instead of being guessed at.
enum ProbeParser {
    private static let name = "ProbeParser"

    static func parse(_ data: Data) throws -> RepositoryProbe {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParseError(parser: name, offset: 0, reason: "not valid UTF-8")
        }
        guard text.hasSuffix("\n") else {
            throw ParseError(parser: name, offset: data.count, reason: "missing final line feed")
        }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 3 else {
            throw ParseError(parser: name, offset: 0, reason: "expected 3 lines, found \(lines.count)")
        }
        let topLevel = try path(lines[0], field: 0)
        let commonDirectory = try path(lines[1], field: 1)
        let isBare: Bool
        switch lines[2] {
        case "true": isBare = true
        case "false": isBare = false
        default: throw ParseError(parser: name, offset: 2, reason: "bare flag is not true or false")
        }
        return RepositoryProbe(topLevel: topLevel, commonDirectory: commonDirectory, isBare: isBare)
    }

    private static func path(_ line: Substring, field: Int) throws -> URL {
        guard line.hasPrefix("/") else {
            throw ParseError(parser: name, offset: field, reason: "path is not absolute")
        }
        guard !PathValidator.containsControlCharacters(String(line)) else {
            throw ParseError(parser: name, offset: field, reason: "path contains a control character")
        }
        // Kept as git printed it (already resolved). `standardizedFileURL` would strip `/private` and break the
        // comparison with `realpath(3)` results (PathValidator).
        return URL(fileURLWithPath: String(line), isDirectory: true)
    }
}
