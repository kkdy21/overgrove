import Foundation

/// Sidebar branches and the issue panel (S-06). Moved out of `AppState.swift` unchanged (#253).
extension AppState {
    // MARK: Branches (#72)

    /// - Parameter isVerified: Open on GitHub links use only remotes this load inspected, like the PR links (#406);
    ///   a cached paint has none.
    static func branchModel(
        _ listing: WorktreeListing, isVerified: Bool = true, trusting hosts: TrustedHosts = GitHubRemote.publicOnly
    ) -> BranchListModel? {
        guard let refs = listing.refs else { return nil }
        return BranchListModel(
            refs: refs, checkedOut: Set(listing.entries.compactMap(\.worktree.branch)),
            remoteNames: listing.remoteNames,
            detachedHeads: Set(listing.entries.filter(\.worktree.isDetached).compactMap(\.worktree.head)),
            githubRemotes: isVerified ? listing.githubRemotes(trusting: hosts) : [:])
    }

    // MARK: Issues (#81)

    var issueListModel: IssueListModel {
        IssueListModel(
            content: issuePanel.content, isLoading: issuePanel.isLoading, links: issueLinks,
            account: issuePanel.repository.flatMap { ghAccounts[$0.host] })
    }

    /// The account gh uses for the open repository's GitHub host, else github.com's (ADR-0025 §4). Either way the
    /// host is named, so another host's account is never shown as if it read this repository.
    var ghAccount: GHAccount? {
        issuePanel.repository.flatMap { ghAccounts[$0.host] } ?? ghAccounts[GitHubRepository.publicHost]
    }

    /// What `#n` badges need (#82): the fetched numbers are links, the rest grey.
    var issueBadgeContext: IssueBadgeContext {
        IssueBadgeContext(
            known: issuePanel.knownNumbers, repository: issuePanel.repository?.ownerAndName, titles: issuePanel.titles,
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
            commits: linkedCommits(number, repository: repository?.ownerAndName))
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

    /// Reads gh's login state for the status bar, and the hosts gh is logged in to. Git features never wait for it
    /// (ADR-0004 §4).
    func checkGitHub() {
        ghCheckTask?.cancel()
        ghCheckGeneration += 1
        let generation = ghCheckGeneration
        let checker = ghChecker
        isCheckingGitHub = true
        ghCheckTask = Task { [weak self] in
            let report = await checker.authReport()
            guard let self, generation == self.ghCheckGeneration, !Task.isCancelled else { return }
            self.ghStatus = report?.status
            self.isCheckingGitHub = false
            // A failed check keeps what was trusted.
            // A failed check keeps the trusted hosts but shows no account it can no longer vouch for.
            self.ghAccounts = report?.accounts ?? [:]
            if let report { self.trustGitHubHosts(report.hosts) }
        }
    }

    /// gh's login list changed what is trusted (ADR-0025 §1): the verified remotes pick the GitHub repository again,
    /// and a different one loads. gh's state was just read, so this does not check it again.
    func trustGitHubHosts(_ hosts: Set<RemoteHost>) {
        let trusted = TrustedHosts(publicHost: GitHubRepository.publicHost, loggedIn: hosts)
        guard trusted != trustedGitHubHosts else { return }
        trustedGitHubHosts = trusted
        guard let source = verifiedGitHubSource, source.repository == repository?.repository else { return }
        let remotes = source.remotes.map { (name: $0.name, url: $0.url) }
        pullRequestStore.update(
            branches: source.branches, remotes: GitHubRemote.repositories(remotes: remotes, trusting: trusted))
        // Branch rows' Open on GitHub (#406) from the same verified remotes.
        if case .loaded(var listing) = worktreeList {
            listing.remotes = source.remotes
            branchListModel = Self.branchModel(listing, trusting: trusted)
        }
        let github = GitHubRemote.repository(remotes: remotes, trusting: trusted)
        guard github != issuePanel.repository else { return }
        issuePanel.show(github)
        pullRequestStore.load(github)
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
