import Foundation

/// One branch row of LOCAL or REMOTE (information-architecture.md §4.3).
struct BranchRow: Identifiable, Equatable {
    /// The full ref name, e.g. `refs/heads/feat/42` (unique).
    let id: String
    /// The name within its folder or remote (`42-rate-limit` under `feat/`), escaped.
    let name: String
    /// The short name (`feat/42-rate-limit`, `origin/main`), escaped, for the tooltip and VoiceOver.
    let fullDisplayName: String
    /// A worktree has this branch checked out (`tree` symbol, local branches only).
    let isCheckedOut: Bool
    /// The default branch, pinned at the top of LOCAL.
    let isDefault: Bool
    let ahead: Int
    let behind: Int
    /// The configured upstream's remote-tracking ref no longer exists.
    let isUpstreamGone: Bool
    /// The tip commit's committer date (remote rows show it relative).
    let date: Date?
    /// The issue a local branch names (`feat/12-x`, #82); remote rows show none (information-architecture.md §4.3).
    let issueNumber: Int?
    let help: String
    let accessibilityLabel: String
    /// The tip commit, for Show in Graph (#73).
    var tip: ObjectID?
    /// The configured upstream's short name (`origin/main`), escaped, for Copy Upstream Name (#73).
    var upstreamName: String?
    /// The configured upstream's full ref name as git gave it (`refs/remotes/origin/main`), for Open on GitHub (#398).
    var upstreamRef: String?

    /// The remote-tracking ref Open on GitHub names: the row itself for a remote row, the upstream for a local one.
    var remoteRef: String? { id.hasPrefix("refs/remotes/") ? id : upstreamRef }
    /// Where Open on GitHub goes (#406): the repository of the remote this branch tracks (a remote row: its own remote),
    /// so a branch tracking a fork opens the fork. `nil` when that remote is not a github.com repository.
    var gitHubTarget: GitHubBranchTarget?
}

/// A row or a folder of rows (`feat/`, a remote) in the sidebar tree.
enum BranchNode: Identifiable, Equatable {
    case branch(BranchRow)
    /// `id` is unique per section; `rows` may themselves be folders (a remote's `feat/`).
    case folder(id: String, name: String, count: Int, children: [BranchNode])

    /// Unique per section in bytes, not only by `String` equality (#565): `café` in NFC and NFD, or `K` and KELVIN
    /// SIGN, are two remotes, branches, or folders to git, so they must not share a SwiftUI identity or an open state.
    var id: String {
        switch self {
        case .branch(let row): Self.key(row.id)
        case .folder(let id, _, _, _): id
        }
    }

    /// `name` with `%` and every non-ASCII byte percent-encoded: equal only when the bytes are equal.
    static func key(_ name: String) -> String {
        var key = ""
        for byte in name.utf8 {
            if byte < 0x80, byte != UInt8(ascii: "%") {
                key.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                key += String(format: "%%%02X", byte)
            }
        }
        return key
    }
}

/// LOCAL and REMOTE built from the cached refs (information-architecture.md §4.2–§4.3). Pure, so it is unit tested
/// without views; every ref name is escaped.
struct BranchListModel: Equatable {
    let local: [BranchNode]
    let localCount: Int
    let remote: [BranchNode]
    let remoteCount: Int
    /// TAGS (#377), from the same refs.
    let tags: TagListModel
    /// A non-blocking note when branches were skipped (names git cannot take back) or the list was cut.
    let warning: String?

    /// The rows to draw: folders and, inside open ones, their children, flattened so one lazy stack builds only what
    /// is on screen (thousands of branches, security review of #72).
    static func visibleRows(_ nodes: [BranchNode], open: Set<String>, depth: Int = 0) -> [(
        node: BranchNode, depth: Int
    )] {
        nodes.flatMap { node -> [(node: BranchNode, depth: Int)] in
            guard case .folder(let id, _, _, let children) = node, open.contains(id) else { return [(node, depth)] }
            return [(node, depth)] + visibleRows(children, open: open, depth: depth + 1)
        }
    }

    /// - Parameters:
    ///   - checkedOut: Full ref names checked out in a worktree.
    ///   - remoteNames: Configured remotes, to split `refs/remotes/<remote>/<branch>` when a name has `/`.
    ///   - detachedHeads: Commits a worktree has checked out detached, for the TAGS `tree` mark.
    ///   - githubRemotes: The verified listing's github.com remotes by name, for Open on GitHub (#406).
    ///   - fetchRefspecs: Each remote's fetch refspecs, by name: a remote-tracking row opens on GitHub only when they
    ///     map it from a branch (#490).
    init(
        refs: RefParser.Listing, checkedOut: Set<String>, remoteNames: [String], detachedHeads: Set<ObjectID> = [],
        githubRemotes: [String: GitHubRepository] = [:], fetchRefspecs: [String: [String]] = [:]
    ) {
        tags = TagListModel(tags: refs.tags, detachedHeads: detachedHeads)
        let symbolic = refs.branches.filter { $0.symbolicTarget != nil }
        let locals = refs.branches.filter { $0.kind == .local }
        let remotes = refs.branches.filter {
            if case .remote = $0.kind { return $0.symbolicTarget == nil }
            return false
        }
        let defaultName = Self.defaultLocal(locals: locals, symbolic: symbolic)

        localCount = locals.count
        let localRows = locals.map { branch in
            Self.row(
                branch, name: String(branch.fullName.dropFirst("refs/heads/".count)),
                isCheckedOut: checkedOut.contains(branch.fullName), isDefault: branch.fullName == defaultName,
                gitHub: GitHubBranchTarget.forLocal(branch, remotes: githubRemotes))
        }
        let pinned = localRows.filter(\.isDefault)
        local = pinned.map(BranchNode.branch) + Self.folders(localRows.filter { !$0.isDefault }, idPrefix: "local")

        remoteCount = remotes.count
        // The longest configured remote wins, so `team/a` owns `refs/remotes/team/a/x`, not `team` (#466, #489).
        let index = RemoteNameIndex(remoteNames + githubRemotes.keys)
        // Parsed once per remote, not per row (T15).
        let parsedRefspecs = fetchRefspecs.mapValues { $0.compactMap(FetchRefspec.init) }
        // Grouped by the name's bytes: `String` keys would merge a remote spelled in NFC with one in NFD (#489).
        var byRemote: [[UInt8]: (name: String, rows: [BranchRow])] = [:]
        for branch in remotes {
            let rest = String(branch.fullName.dropFirst("refs/remotes/".count))
            // Compared and cut in UTF-8 bytes: by characters, a combining mark after `/` would join it and hide the
            // match (security review of #72).
            let remote =
                index.remote(of: rest)
                ?? {
                    guard case .remote(let guess) = branch.kind else { return "" }
                    return guess
                }()
            let cut = String(decoding: rest.utf8.dropFirst(remote.utf8.count + 1), as: UTF8.self)
            let name = cut.isEmpty ? rest : cut
            byRemote[Array(remote.utf8), default: (remote, [])].rows.append(
                Self.row(
                    branch, name: name, isCheckedOut: false, isDefault: false,
                    gitHub: GitHubBranchTarget.forRemoteRef(
                        branch.fullName, remotes: githubRemotes, index: index, fetchRefspecs: parsedRefspecs)))
        }
        // `origin` first, then the rest by name (information-architecture.md §4.2).
        let order = byRemote.values.sorted { lhs, rhs in
            if (lhs.name == "origin") != (rhs.name == "origin") { return lhs.name == "origin" }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        remote = order.map { name, rows in
            return .folder(
                id: "remote:\(BranchNode.key(name))", name: PathValidator.displayable(name), count: rows.count,
                children: Self.folders(rows, idPrefix: "remote:\(BranchNode.key(name))"))
        }

        var notes: [String] = []
        if refs.skippedRecords > 0 {
            let count = refs.skippedRecords
            notes.append(
                count == 1
                    ? String(localized: "\(count) branch is not shown: the name is not valid UTF-8.")
                    : String(localized: "\(count) branches are not shown: the name is not valid UTF-8."))
        }
        if refs.isPartial {
            notes.append(String(localized: "Some branches could not be listed because git's output was too large."))
        }
        warning = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// The local branch `origin/HEAD` points at (tracked or same name), else `main`, else `master`.
    static func defaultLocal(locals: [Branch], symbolic: [Branch]) -> String? {
        let names = Set(locals.map(\.fullName))
        if let target = symbolic.first(where: { $0.fullName == "refs/remotes/origin/HEAD" })?.symbolicTarget {
            if let tracking = locals.first(where: { $0.upstream == target }) { return tracking.fullName }
            let same = "refs/heads/" + String(target.dropFirst("refs/remotes/origin/".count))
            if target.hasPrefix("refs/remotes/origin/"), names.contains(same) { return same }
        }
        return ["refs/heads/main", "refs/heads/master"].first(where: names.contains)
    }

    /// Groups rows by the part before the first `/` (`feat/`); folders and names each sorted by name. Folders are
    /// keyed by bytes (#565): `café/` in NFC and NFD are two folders, as git keeps them two branches.
    private static func folders(_ rows: [BranchRow], idPrefix: String) -> [BranchNode] {
        var loose: [BranchRow] = []
        var grouped: [String: (name: String, rows: [BranchRow])] = [:]
        for row in rows {
            if let slash = row.name.firstIndex(of: "/"), slash != row.name.startIndex {
                let folder = String(row.name[..<slash])
                let rest = String(row.name[row.name.index(after: slash)...])
                grouped[BranchNode.key(folder), default: (folder, [])].rows.append(row.renamed(rest))
            } else {
                loose.append(row)
            }
        }
        let byName: (BranchRow, BranchRow) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let folderNodes = grouped.sorted { lhs, rhs in
            let order = lhs.value.name.localizedStandardCompare(rhs.value.name)
            return order == .orderedSame ? lhs.key < rhs.key : order == .orderedAscending
        }.map { key, folder in
            BranchNode.folder(
                id: "\(idPrefix)/\(key)", name: folder.name + "/", count: folder.rows.count,
                children: folder.rows.sorted(by: byName).map(BranchNode.branch))
        }
        // Folders first (as in the mockup), then loose branches.
        return folderNodes + loose.sorted(by: byName).map(BranchNode.branch)
    }

    private static func row(
        _ branch: Branch, name: String, isCheckedOut: Bool, isDefault: Bool, gitHub: GitHubBranchTarget?
    ) -> BranchRow {
        let display = PathValidator.displayable(name)
        let full = PathValidator.displayable(branch.shortName)
        let upstream = branch.upstreamStatus
        let isGone: Bool = if case .gone = upstream { true } else { false }
        let issueNumber = branch.kind == .local ? IssueRefExtractor.issueNumber(inBranch: branch.fullName) : nil
        var help = [full]
        switch upstream {
        case .tracking(let name, let ahead, let behind):
            let upstreamName = PathValidator.displayable(Self.short(name))
            help.append(String(localized: "Tracks \(upstreamName)") + "  ↑\(ahead) ↓\(behind)")
        case .gone(let name):
            let upstreamName = PathValidator.displayable(Self.short(name))
            help.append(String(localized: "Upstream \(upstreamName) is gone"))
        case .none:
            if branch.kind == .local { help.append(Text.noUpstream) }
        }
        if isCheckedOut { help.append(Text.checkedOutInWorktree) }
        var label = [full, branch.kind == .local ? Text.localBranch : Text.remoteBranch]
        if isDefault { label.append(Text.defaultBranch) }
        if isCheckedOut { label.append(Text.checkedOut) }
        if upstream.ahead > 0 { label.append(String(localized: "\(upstream.ahead) ahead")) }
        if upstream.behind > 0 { label.append(String(localized: "\(upstream.behind) behind")) }
        if isGone { label.append(Text.upstreamGone) }
        if let issueNumber { label.append(String(localized: "issue \(issueNumber)")) }
        return BranchRow(
            id: branch.fullName, name: display, fullDisplayName: full, isCheckedOut: isCheckedOut, isDefault: isDefault,
            ahead: upstream.ahead, behind: upstream.behind, isUpstreamGone: isGone, date: branch.committerDate,
            issueNumber: issueNumber, help: help.joined(separator: "\n"),
            accessibilityLabel: label.joined(separator: ", "), tip: branch.target,
            upstreamName: branch.upstream.map { PathValidator.displayable(Self.short($0)) },
            upstreamRef: branch.upstream, gitHubTarget: gitHub)
    }

    /// `refs/remotes/origin/main` → `origin/main`.
    private static func short(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}

extension BranchRow {
    /// The same row shown under a folder (`feat/` + `42-rate-limit`). `name` is already escaped; slicing it at an ASCII
    /// `/` keeps it escaped.
    fileprivate func renamed(_ name: String) -> BranchRow {
        BranchRow(
            id: id, name: name, fullDisplayName: fullDisplayName, isCheckedOut: isCheckedOut, isDefault: isDefault,
            ahead: ahead, behind: behind, isUpstreamGone: isUpstreamGone, date: date, issueNumber: issueNumber,
            help: help,
            accessibilityLabel: accessibilityLabel, tip: tip, upstreamName: upstreamName, upstreamRef: upstreamRef,
            gitHubTarget: gitHubTarget)
    }
}

extension BranchListModel {
    /// Fixed row texts, looked up once: a load can build thousands of rows (security review of #72).
    fileprivate enum Text {
        static let noUpstream = String(localized: "No upstream")
        static let checkedOutInWorktree = String(localized: "Checked out in a worktree")
        static let localBranch = String(localized: "local branch")
        static let remoteBranch = String(localized: "remote branch")
        static let defaultBranch = String(localized: "default", comment: "VoiceOver: the default branch")
        static let checkedOut = String(localized: "checked out")
        static let upstreamGone = String(localized: "upstream gone")
    }
}
