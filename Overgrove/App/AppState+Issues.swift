import Foundation

/// Sidebar branches and the issue panel (S-06). Moved out of `AppState.swift` unchanged (#253).
extension AppState {
    // MARK: Branches (#72)

    static func branchModel(_ listing: WorktreeListing) -> BranchListModel? {
        guard let refs = listing.refs else { return nil }
        return BranchListModel(
            refs: refs, checkedOut: Set(listing.entries.compactMap(\.worktree.branch)),
            remoteNames: listing.remoteNames,
            detachedHeads: Set(listing.entries.filter(\.worktree.isDetached).compactMap(\.worktree.head)),
            githubRemotes: listing.githubRemotes)
    }

    // MARK: Issues (#81)

    var issueListModel: IssueListModel {
        IssueListModel(content: issuePanel.content, isLoading: issuePanel.isLoading, links: issueLinks)
    }

    /// What `#n` badges need (#82): the fetched numbers are links, the rest grey.
    var issueBadgeContext: IssueBadgeContext {
        IssueBadgeContext(
            known: issuePanel.knownNumbers, repository: issuePanel.repository?.slug, titles: issuePanel.titles,
            select: { [weak self] in self?.selectIssue($0) })
    }

    /// The selected issue's linked branch tips, outlined in the graph without selecting them
    /// (information-architecture.md §3.2).
    var highlightedCommits: Set<ObjectID> {
        guard let number = selectedIssueNumber else { return [] }
        return Set(issueLinks.links(number).branches.map(\.target))
    }

    private func linkedCommits(_ number: Int, repository: String?) -> [CommitLink] {
        let commits = graph.commits
        var entry = CommitLinkCache(
            number: number, repository: repository, first: commits.first?.oid, scanned: 0, found: [])
        if let cached = commitLinkCache, cached.number == number, cached.repository == repository,
            cached.first == commits.first?.oid, cached.scanned <= commits.count
        {
            entry = cached
        }
        if entry.found.count < CommitLink.limit, entry.scanned < commits.count {
            entry.found += CommitLink.latest(
                CommitLink.limit - entry.found.count, linkedTo: number, in: commits[entry.scanned...],
                repository: repository)
            entry.scanned = commits.count
        }
        commitLinkCache = entry
        return entry.found
    }

    /// A LINKED branch tip or commit: selected in the graph and shown in S-03.
    func selectLinkedCommit(_ oid: ObjectID) {
        // A loaded commit opens S-03 (#69); a tip beyond the loaded pages is only highlighted.
        if graph.index(of: oid) != nil {
            selectCommit(oid)
        } else {
            graph.select(oid)
        }
    }

    var selectedIssueNumber: Int? {
        if case .issue(let number) = selection { return number }
        return nil
    }

    /// S-06 for the selected issue, `nil` unless an issue is selected.
    var issueDetailModel: IssueDetailModel? {
        guard let number = selectedIssueNumber, let issue = issuePanel.issues.first(where: { $0.number == number })
        else { return nil }
        let repository = issuePanel.repository
        return IssueDetailModel(
            issue, repository: repository, links: issueLinks.links(number),
            commits: linkedCommits(number, repository: repository?.slug))
    }

    /// Selecting an issue shows it in the detail panel; the focused worktree stays (information-architecture.md §2.2).
    func selectIssue(_ number: Int) {
        guard issuePanel.issues.contains(where: { $0.number == number }) else { return }
        selectedFile = nil
        closeComparison()
        selection = .issue(number)
    }

    /// An issue that is no longer open falls back to the focused worktree.
    func issuesDidLoad(_ issues: [Issue]) {
        guard let number = selectedIssueNumber, !issues.contains(where: { $0.number == number }) else { return }
        isSelectingAutomatically = true
        defer { isSelectingAutomatically = false }
        selection = focusedWorktreePath.map(MainSelection.wip)
    }

    // MARK: GitHub CLI state (#83)

    /// Reads gh's login state for the status bar. Git features never wait for it (ADR-0004 §4).
    func checkGitHub() {
        ghCheckTask?.cancel()
        ghCheckGeneration += 1
        let generation = ghCheckGeneration
        let checker = ghChecker
        isCheckingGitHub = true
        ghCheckTask = Task { [weak self] in
            let status = await checker.authStatus()
            guard let self, generation == self.ghCheckGeneration, !Task.isCancelled else { return }
            self.ghStatus = status
            self.isCheckingGitHub = false
        }
    }

    /// The ISSUES section's Check Again: gh's state and the issues again. Without a GitHub remote, the repository
    /// reloads so its remotes are read again.
    func checkIssuesAgain() {
        // Pressing it again while gh is still running does not start more gh processes (security review of #83).
        guard repository != nil, !issuePanel.isLoading, !isCheckingGitHub else { return }
        if issuePanel.retry() {
            checkGitHub()
            pullRequestStore.load(issuePanel.repository)
        } else {
            reload()
        }
    }
}
