import Foundation

/// Parses `git worktree list --porcelain -z` (parsing-spec.md §2).
///
/// Format: one NUL-terminated token per attribute, and an empty token (a second NUL) ends each record. The first
/// record is the main worktree. Paths and lock reasons may contain line feeds; `-z` keeps them intact.
///
/// - `HEAD` is absent for a bare main repository and is the all-zero OID for an unborn branch (confirmed with
///   Apple Git 2.54.0, PAR-WT-09). Both become `head == nil`.
/// - Unknown attributes are ignored for forward compatibility. A malformed known attribute fails the whole parse.
enum WorktreeParser {
    struct Listing: Sendable, Equatable {
        let worktrees: [Worktree]
        /// The output was cut at the size limit and the last record was dropped.
        let isPartial: Bool
    }

    private static let name = "WorktreeParser"

    static func parse(_ data: Data, truncated: Bool = false) throws -> Listing {
        var records: [Worktree] = []
        var current: RecordBuilder?
        var offset = 0
        for token in data.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            // `split` yields one trailing token after the final NUL; it is either empty or an unterminated fragment
            // and is handled below via `current`.
            if token.isEmpty {
                guard let record = current else {
                    throw ParseError(parser: name, offset: offset, reason: "empty record")
                }
                records.append(try record.build(isMain: records.isEmpty))
                current = nil
            } else if current == nil {
                current = try RecordBuilder(firstToken: token, offset: offset)
            } else {
                try current?.apply(token, offset: offset)
            }
            offset += token.count + 1
        }

        let hasTrailingFragment = data.last.map { $0 != 0 } ?? false
        let isUnterminated = current != nil || hasTrailingFragment
        if truncated {
            // The last record may be incomplete even when its terminator survived the cut, so drop it either way.
            if !isUnterminated, !records.isEmpty { records.removeLast() }
            return Listing(worktrees: records, isPartial: true)
        }
        guard !isUnterminated else {
            throw ParseError(parser: name, offset: offset, reason: "unterminated record")
        }
        return Listing(worktrees: records, isPartial: false)
    }
}

extension WorktreeParser {
    private struct RecordBuilder {
        let path: GitPath
        let offset: Int
        var head: ObjectID?
        var branch: String?
        var isDetached = false
        var isBare = false
        var lock: Worktree.Lock = .unlocked
        var isPrunable = false
        var prunableReason: String?

        private static let worktreePrefix = Data("worktree ".utf8)
        private static let headPrefix = Data("HEAD ".utf8)
        private static let branchPrefix = Data("branch ".utf8)

        init(firstToken token: Data.SubSequence, offset: Int) throws {
            guard token.starts(with: Self.worktreePrefix) else {
                throw ParseError(parser: name, offset: offset, reason: "record does not start with worktree")
            }
            let raw = token.dropFirst(Self.worktreePrefix.count)
            guard !raw.isEmpty else {
                throw ParseError(parser: name, offset: offset, reason: "empty worktree path")
            }
            path = GitPath(raw: Data(raw))
            self.offset = offset
        }

        mutating func apply(_ token: Data.SubSequence, offset: Int) throws {
            if token.starts(with: Self.worktreePrefix) {
                throw ParseError(parser: name, offset: offset, reason: "duplicate worktree attribute")
            } else if token.starts(with: Self.headPrefix) {
                head = try Self.head(token.dropFirst(Self.headPrefix.count), offset: offset)
            } else if token.starts(with: Self.branchPrefix) {
                let ref = token.dropFirst(Self.branchPrefix.count)
                guard !ref.isEmpty else { throw ParseError(parser: name, offset: offset, reason: "empty branch") }
                branch = String(decoding: ref, as: UTF8.self)
            } else if token.elementsEqual("detached".utf8) {
                isDetached = true
            } else if token.elementsEqual("bare".utf8) {
                isBare = true
            } else if let reason = Self.flag("locked", in: token) {
                lock = .locked(reason: reason)
            } else if let reason = Self.flag("prunable", in: token) {
                isPrunable = true
                prunableReason = reason
            }
            // Anything else is an attribute from a newer git; ignore it (parsing-spec.md §1.6).
        }

        func build(isMain: Bool) throws -> Worktree {
            if isDetached, branch != nil {
                throw ParseError(parser: name, offset: offset, reason: "both branch and detached")
            }
            return Worktree(
                path: path,
                head: head,
                branch: branch,
                isMain: isMain,
                isDetached: isDetached,
                isBare: isBare,
                lock: lock,
                isPrunable: isPrunable,
                prunableReason: prunableReason
            )
        }

        /// The all-zero OID marks an unborn branch and maps to `nil`.
        private static func head(_ bytes: Data.SubSequence, offset: Int) throws -> ObjectID? {
            guard let oid = ObjectID(String(decoding: bytes, as: UTF8.self)) else {
                throw ParseError(parser: name, offset: offset, reason: "invalid HEAD object ID")
            }
            return oid.hex.utf8.allSatisfy { $0 == 0x30 } ? nil : oid
        }

        /// Matches `<keyword>` or `<keyword> <reason>`. Returns `.some(nil)` without a reason, `nil` for no match.
        private static func flag(_ keyword: String, in token: Data.SubSequence) -> String?? {
            let keywordBytes = Data(keyword.utf8)
            guard token.starts(with: keywordBytes) else { return nil }
            let rest = token.dropFirst(keywordBytes.count)
            if rest.isEmpty { return .some(nil) }
            guard rest.first == 0x20 else { return nil }
            let reason = rest.dropFirst()
            return .some(reason.isEmpty ? nil : String(decoding: reason, as: UTF8.self))
        }
    }
}
