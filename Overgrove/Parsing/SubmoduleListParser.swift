import Foundation

/// Parses `git config --file .gitmodules --no-includes -z --get-regexp ^submodule\..*\.path$` (parsing-spec.md §11.6,
/// #108).
///
/// Format: `key␊value␀` per entry, e.g. `submodule.libs/x.path␊libs/x␀`. The value is the submodule's path relative to
/// the worktree, as the repository wrote it: untrusted (it may be absolute, contain `..`, or not be UTF-8), so callers
/// validate it before using it as a folder (`PathValidator.submoduleFolder`). Duplicate paths are reported once, in
/// first-seen order. An entry without a value (`submodule.x.path` written as a bare boolean) has no path and is skipped.
/// At most `limit` paths are kept; past that the listing is partial (T15: a huge `.gitmodules` builds no huge list).
enum SubmoduleListParser {
    struct Listing: Sendable, Equatable {
        let paths: [GitPath]
        /// The output was cut at the size limit and the last entry was dropped, or more than `limit` paths were listed.
        let isPartial: Bool
    }

    private static let name = "SubmoduleListParser"

    static func parse(_ data: Data, truncated: Bool = false, limit: Int = .max) throws -> Listing {
        guard truncated || data.isEmpty || data.last == 0 else {
            throw ParseError(parser: name, offset: data.count, reason: "output does not end with NUL")
        }
        var records = data.split(separator: 0, omittingEmptySubsequences: false)
        if records.last?.isEmpty == true { records.removeLast() }
        if truncated, !records.isEmpty { records.removeLast() }

        var seen = Set<Data>()
        var paths: [GitPath] = []
        var offset = 0
        for record in records {
            defer { offset += record.count + 1 }
            guard let newline = record.firstIndex(of: 0x0A) else {
                // `key␀` alone: a valueless boolean, so no path.
                guard record.starts(with: Data("submodule.".utf8)) else {
                    throw ParseError(parser: name, offset: offset, reason: "unexpected key")
                }
                continue
            }
            let key = record[record.startIndex..<newline]
            guard key.starts(with: Data("submodule.".utf8)), key.reversed().starts(with: Data("htap.".utf8)) else {
                throw ParseError(parser: name, offset: offset, reason: "unexpected key")
            }
            let value = Data(record[record.index(after: newline)...])
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            guard paths.count < limit else { return Listing(paths: paths, isPartial: true) }
            paths.append(GitPath(raw: value))
        }
        return Listing(paths: paths, isPartial: truncated)
    }
}
