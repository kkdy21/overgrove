import Foundation

/// S-05, one worktree's facts and safety (screens.md S-05, security-review.md §6). Pure, so it is unit tested without
/// views. Repository strings are escaped; configuration values are never shown (only key names); URLs are masked.
struct WorktreeDetailModel: Equatable {
    struct InfoRow: Equatable, Identifiable {
        let label: String
        let value: String
        /// The value is a warning (`status.prunable` colour): missing folder, symbolic link, gone upstream, locked.
        var isWarning = false
        /// Missing worktrees show their last known values dimmed.
        var isDimmed = false
        var id: String { label }
    }

    let title: String
    let worktreePath: GitPath
    /// The full path for Copy Path; `nil` when copying would not give what the screen shows (see `WipDetailModel`).
    let copyablePath: String?
    let info: [InfoRow]
    /// `nil` until the inspection has loaded, or when the worktree is not inspected (not part of the repository).
    let security: WorktreeSecurityModel?
    /// Why there is no security section, when there is none and none is coming.
    let securityUnavailable: String?

    init(
        entry: WorktreeListing.Entry, inspection: WorktreeInspection?, fetchStatus: FetchStatus, now: Date,
        home: String = NSHomeDirectory()
    ) {
        let worktree = entry.worktree
        let state: WorkingState? = if case .loaded(let state) = entry.state { state } else { nil }
        let missing = entry.state == .missing || worktree.isPrunable
        title = PathValidator.displayable(
            worktree.branchShortName ?? "detached @ \(worktree.head?.short ?? "unknown")")
        worktreePath = worktree.path
        let full = worktree.path.display
        copyablePath = worktree.path.isRepresentable && PathValidator.displayable(full) == full ? full : nil

        var rows: [InfoRow] = []
        let path = PathValidator.displayable(Self.abbreviated(full, home: home))
        if missing {
            rows.append(InfoRow(label: "Path", value: "\(path) — Directory missing", isWarning: true))
        } else if let real = inspection?.realPath {
            rows.append(
                InfoRow(
                    label: "Path",
                    value: "\(path) — Symlink to \(PathValidator.displayable(Self.abbreviated(real, home: home)))",
                    isWarning: true))
        } else {
            rows.append(InfoRow(label: "Path", value: path))
        }
        rows.append(InfoRow(label: "HEAD", value: (state?.headCommit ?? worktree.head)?.short ?? "No commits yet"))
        rows.append(
            InfoRow(label: "Branch", value: worktree.branchShortName.map(PathValidator.displayable) ?? "detached"))
        rows.append(Self.upstreamRow(state?.upstream))
        rows.append(InfoRow(label: "State", value: state.map(Self.stateSummary) ?? Self.unknownState(entry.state)))
        if case .locked(let reason) = worktree.lock {
            rows.append(
                InfoRow(
                    label: "Lock", value: reason.map { "Locked: \(PathValidator.displayable($0))" } ?? "Locked",
                    isWarning: true))
        } else {
            rows.append(InfoRow(label: "Lock", value: "Not locked"))
        }
        rows.append(InfoRow(label: "Last fetch", value: Self.lastFetch(fetchStatus, now: now) + " (repository)"))
        info =
            missing
            ? rows.map {
                InfoRow(label: $0.label, value: $0.value, isWarning: $0.isWarning, isDimmed: $0.label != "Path")
            } : rows

        switch entry.state {
        case .loaded, .notQueried(.inspectionBlocked):
            security = inspection.map(WorktreeSecurityModel.init)
            securityUnavailable = nil
        case .missing:
            security = nil
            securityUnavailable = "The worktree folder is missing, so its configuration cannot be inspected."
        case .failed(let error):
            // A failed probe also lands here, so the folder is not known to belong to this repository.
            security = nil
            securityUnavailable =
                "Status could not be read, so the configuration is not inspected. "
                + PathValidator.displayable(error.message)
        case .notQueried:
            security = nil
            securityUnavailable =
                "Overgrove does not query this worktree entry, so its configuration is not inspected."
        }
    }

    /// Whether S-05 should load an inspection for this entry: only for worktrees `RepositoryService` verified as part
    /// of the repository (its status loaded, or its own configuration refused it after the check).
    static func shouldInspect(_ entry: WorktreeListing.Entry) -> Bool {
        switch entry.state {
        case .loaded, .notQueried(.inspectionBlocked): true
        case .missing, .failed, .notQueried: false
        }
    }

    private static func upstreamRow(_ upstream: UpstreamStatus?) -> InfoRow {
        switch upstream {
        case .some(.tracking(let name, let ahead, let behind)):
            InfoRow(label: "Upstream", value: "\(PathValidator.displayable(name))  ↑\(ahead) ↓\(behind)")
        case .some(.gone(let name)):
            InfoRow(label: "Upstream", value: "\(PathValidator.displayable(name)) (gone)", isWarning: true)
        case .some(.none):
            InfoRow(label: "Upstream", value: "No upstream")
        case nil:
            InfoRow(label: "Upstream", value: "Unknown")
        }
    }

    /// `6 changed · 1 untracked · 0 conflicts` (screens.md S-05).
    static func stateSummary(_ state: WorkingState) -> String {
        let changed = Set((state.staged + state.unstaged).map(\.path)).count
        let conflicts = state.conflicted.count
        return
            "\(changed) changed · \(state.untracked.count) untracked · \(conflicts) \(conflicts == 1 ? "conflict" : "conflicts")"
    }

    private static func unknownState(_ state: WorktreeListing.State) -> String {
        switch state {
        case .missing: "Directory missing"
        case .failed: "Status unavailable"
        case .notQueried(.inspectionBlocked): "Blocked for safety"
        default: "Not queried"
        }
    }

    private static func lastFetch(_ status: FetchStatus, now: Date) -> String {
        switch status {
        case .never: "Never fetched"
        case .idle(let last): StatusBarItem.relative(last, now: now)
        case .fetching(_, _, let last):
            last.map { StatusBarItem.relative($0, now: now) + ", fetching now" } ?? "Fetching now"
        case .failed(let last):
            last.map { StatusBarItem.relative($0, now: now) + ", last attempt failed" } ?? "Last attempt failed"
        }
    }

    private static func abbreviated(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        if path == home { return "~" }
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}

/// The SECURITY section (security-review.md §6). Each row is decided from the arguments that really run and the
/// worktree's inspection, not from fixed text.
struct WorktreeSecurityModel: Equatable {
    enum Mark: Equatable {
        /// ✓ The protection applies and nothing in this repository works against it.
        case applied
        /// ⚠ The repository sets something risky, and Overgrove overrides it.
        case neutralized
        /// ✕ It could not be confirmed; queries are already stopped.
        case unknown
    }

    struct Row: Equatable, Identifiable {
        let title: String
        let mark: Mark
        /// Key names (never values) behind a ⚠ or ✕, shown when the row is expanded. Escaped.
        let details: [String]
        /// What the user can do, shown under the details (security-review.md T11: remove credentials from URLs).
        var advice: String?
        var id: String { title }
    }

    /// A finding none of the rows covers, by key, with what Overgrove does about it.
    struct OtherFinding: Equatable, Identifiable {
        let key: String
        let handling: String
        let threat: String?
        var id: String { key + handling }
    }

    /// `Inspected 2 min ago · local and worktree scopes` is built by the view from this.
    let inspectedAt: Date
    /// `git 2.50.1`.
    let gitVersion: String?
    /// Queries are stopped (✕): the reason. Shown above the rows.
    let blockingReason: String?
    /// This worktree's configuration could not be read for S-05 (the rows that need it show ✕). Unlike
    /// `blockingReason`, queries may still be running (security review of #67).
    let failure: String?
    /// Queries run, but `git fetch` will not (e.g. a repository-local TLS certificate).
    let fetchBlockingReason: String?
    let rows: [Row]
    let others: [OtherFinding]

    init(_ result: WorktreeInspection) {
        inspectedAt = result.inspectedAt
        gitVersion = result.gitVersion.map { "git \($0)" }
        let inspection = result.inspection
        let findings = inspection?.report.findings ?? []
        let blocked = inspection?.report.blockingReason
        blockingReason = blocked.map(PathValidator.displayable)
        failure = result.failure.map(PathValidator.displayable)
        var fetchReason = inspection?.fetchBlockingReason
        if fetchReason == nil, inspection?.isPartialClone == true {
            fetchReason = "This repository is a partial clone; Overgrove never downloads missing objects."
        }
        fetchBlockingReason = fetchReason.map(PathValidator.displayable)

        var used = Set<RepoSecurityReport.Finding>()
        /// Key names of the findings `match` selects (never values), each once; they no longer count as "other".
        func keys(_ match: (ConfigEntry) -> Bool) -> [String] {
            let matched = findings.filter { match($0.entry) }
            used.formUnion(matched)
            var seen = Set<String>()
            return matched.map { PathValidator.displayable(Self.keyName($0.entry)) }.filter { seen.insert($0).inserted }
        }
        /// ✕ when `unknown`, ✓ when nothing was found, ⚠ (overridden) otherwise.
        func row(_ title: String, unknown: Bool, details: [String]) -> Row {
            Row(title: title, mark: unknown ? .unknown : (details.isEmpty ? .applied : .neutralized), details: details)
        }

        // The ✓ conditions read the arguments that really run (§6), so a regression in them shows as ✕ here too.
        let args = result.commonArguments
        let hooksGuarded = Self.hasPair(args, "core.hooksPath=/dev/null")
        let fsmonitorGuarded = Self.hasPair(args, "core.fsmonitor=false")
        let diffGuarded =
            result.diffArguments.contains("--no-ext-diff") && result.diffArguments.contains("--no-textconv")
        let notInspected = inspection == nil || blocked != nil

        let hookKeys = keys { $0.section == "core" && $0.variable == "hookspath" }
        let fsmonitorKeys = keys { $0.section == "core" && $0.variable == "fsmonitor" }
        let diffKeys = keys { Self.isDiffDriver($0) }
        let filterKeys = keys { $0.section == "filter" }
        var rows = [
            row(
                "Hooks disabled", unknown: notInspected || !hooksGuarded,
                details: hookKeys + result.hookExecutables),
            row("fsmonitor disabled", unknown: notInspected || !fsmonitorGuarded, details: fsmonitorKeys),
            row("External diff and textconv disabled", unknown: !diffGuarded, details: diffKeys),
            row(
                "Filters neutralized", unknown: inspection == nil || (blocked != nil && Self.hasUnsafeFilter(findings)),
                details: filterKeys),
        ]
        if let inspection {
            let transportKeys = keys {
                ($0.section == "core" && ["sshcommand", "gitproxy"].contains($0.variable))
                    || ($0.section == "remote" && ["uploadpack", "url"].contains($0.variable))
            }
            let helperKeys = keys { $0.section == "credential" && $0.variable == "helper" }
            let tlsKeys = keys { $0.section == "http" && $0.variable == "sslverify" }
            rows += [
                row("Transport commands neutralized", unknown: false, details: transportKeys),
                row("Repository credential helpers ignored", unknown: false, details: helperKeys),
                row("TLS verification kept on", unknown: false, details: tlsKeys),
                {
                    var masked = row(
                        "Remote URL credentials masked", unknown: false,
                        details: Self.remotesWithCredentials(inspection))
                    if !masked.details.isEmpty {
                        masked.advice = "Remove the credentials from the URL and let a credential helper store them."
                    }
                    return masked
                }(),
            ]
        }
        self.rows = rows
        others = findings.filter { !used.contains($0) }.map {
            OtherFinding(
                key: PathValidator.displayable(Self.keyName($0.entry)), handling: Self.handlingText($0.handling),
                threat: $0.threat)
        }
    }

    /// `filter.lfs.process`, `remote.origin.uploadpack`: the key as git names it, with its scope. A subsection can be
    /// a URL (`credential.https://user:token@host.helper`, `http.<url>.sslVerify`), so the key is credential-masked.
    static func keyName(_ entry: ConfigEntry) -> String {
        let key = CredentialMasker.mask(
            [entry.section, entry.subsection, entry.variable].compactMap { $0 }.joined(separator: "."))
        return entry.scope == .worktree ? "\(key) (worktree)" : key
    }

    static func handlingText(_ handling: RepoSecurityReport.Handling) -> String {
        switch handling {
        case .neutralized: "overridden"
        case .reported: "already blocked"
        case .warned: "review"
        }
    }

    /// `origin: https://***@example.com/repo.git`. Only masked URLs are shown (T11).
    static func remotesWithCredentials(_ inspection: RepoConfigInspection) -> [String] {
        inspection.remotes.filter { $0.displayURL != $0.url }.map {
            "\(PathValidator.displayable($0.name.value)): \(PathValidator.displayable($0.displayURL))"
        }
    }

    static func isDiffDriver(_ entry: ConfigEntry) -> Bool {
        entry.section == "diff" && ["external", "textconv", "command"].contains(entry.variable)
    }

    /// A filter key the inspector cannot neutralize: a driver name it refuses, or one with `=` (which would split the
    /// `-c` argument). These are what block queries for filters (RepoConfigInspector).
    private static func hasUnsafeFilter(_ findings: [RepoSecurityReport.Finding]) -> Bool {
        findings.contains { finding in
            guard finding.entry.section == "filter", let driver = finding.entry.subsection else { return false }
            return driver.contains("=") || !ConfigParser.isNeutralizableDriverName(driver)
        }
    }

    private static func hasPair(_ arguments: [String], _ setting: String) -> Bool {
        zip(arguments, arguments.dropFirst()).contains { $0 == "-c" && $1 == setting }
    }
}
