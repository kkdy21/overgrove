import Foundation

/// Output of `rev-parse --path-format=absolute --git-common-dir --absolute-git-dir --is-bare-repository
/// --is-inside-work-tree` (#222).
struct GitDirectoryProbe: Equatable, Sendable {
    /// The repository's shared git directory.
    let commonDirectory: URL
    /// The git directory of the probed location: the common directory itself, or `<common>/worktrees/<id>` for a
    /// linked worktree.
    let gitDirectory: URL
    let isBare: Bool
    let isInsideWorkTree: Bool
}

/// Parses the registration's first probe (parsing-spec.md §11.2.1).
///
/// Same shape rules as `ProbeParser`: exactly four LF-terminated lines, two absolute UTF-8 paths without control
/// characters, then two `true`/`false` flags. A path with a line feed would shift the fields, so it fails.
enum GitDirectoryProbeParser {
    private static let name = "GitDirectoryProbeParser"

    static func parse(_ data: Data) throws -> GitDirectoryProbe {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ParseError(parser: name, offset: 0, reason: "not valid UTF-8")
        }
        guard text.hasSuffix("\n") else {
            throw ParseError(parser: name, offset: data.count, reason: "missing final line feed")
        }
        let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == 4 else {
            throw ParseError(parser: name, offset: 0, reason: "expected 4 lines, found \(lines.count)")
        }
        return GitDirectoryProbe(
            commonDirectory: try path(lines[0], field: 0),
            gitDirectory: try path(lines[1], field: 1),
            isBare: try flag(lines[2], field: 2),
            isInsideWorkTree: try flag(lines[3], field: 3)
        )
    }

    private static func path(_ line: Substring, field: Int) throws -> URL {
        guard line.hasPrefix("/") else {
            throw ParseError(parser: name, offset: field, reason: "path is not absolute")
        }
        guard !PathValidator.containsControlCharacters(String(line)) else {
            throw ParseError(parser: name, offset: field, reason: "path contains a control character")
        }
        // Kept as git printed it (already resolved); see `ProbeParser`.
        return URL(fileURLWithPath: String(line), isDirectory: true)
    }

    private static func flag(_ line: Substring, field: Int) throws -> Bool {
        switch line {
        case "true": return true
        case "false": return false
        default: throw ParseError(parser: name, offset: field, reason: "flag is not true or false")
        }
    }
}
