import Foundation

/// Row context menu actions (interaction.md §5, #73). Look and copy only.
extension AppState {
    var rowMenuActions: RowMenuActions {
        RowMenuActions(
            focusedWorktree: focusedWorktreePath,
            copy: { [weak self] in self?.copy($0) },
            copyMessage: { [weak self] in self?.rowActions.copy(RowActions.clipboardText($0, keepsLineBreaks: true)) },
            showCommit: { [weak self] in self?.showInGraph($0) },
            canCompareCommit: { [weak self] in self?.canCompareCommit(with: $0) ?? false },
            compareCommit: { [weak self] in self?.showCommitComparison(with: $0) },
            commitMessage: { [weak self] in self?.message(of: $0) ?? $0.subject },
            fullPath: { [weak self] in self?.fullPath(of: $1, in: $0) },
            revealFile: { [weak self] in self?.revealFile($1, in: $0) },
            showWorktreeChanges: { [weak self] in self?.showWorktree($0, info: false) },
            showWorktreeInfo: { [weak self] in self?.showWorktree($0, info: true) },
            revealWorktree: { [weak self] in self?.revealWorktree($0) },
            openTerminal: { [weak self] in self?.openTerminal(at: $0) },
            showStash: { [weak self] in self?.selectStash($0) },
            openInBrowser: { [weak self] in self?.openInBrowser($0) },
            gitHubCommitURL: { [weak self] oid in self?.gitHub.flatMap { GitHubLinks.commit($0.repository, oid) } },
            gitHubBranchURL: { [weak self] ref in
                self?.gitHub.flatMap { GitHubLinks.branch($0.repository, remoteRef: ref, remote: $0.remote) }
            },
            gitHubFileURL: { [weak self] oid, path in
                self?.gitHub.flatMap { GitHubLinks.file($0.repository, commit: oid, path: path) }
            },
            linkedBranchTip: { [weak self] in self?.linkedBranchTip(of: $0) },
            showHistory: { [weak self] in self?.showHistory(of: $1, in: $0) })
    }

    /// The github.com repository and its remote, from the loaded worktree list (#398).
    var gitHub: (repository: GitHubRepository, remote: String)? {
        guard case .loaded(let listing) = worktreeList, let repository = listing.githubRepository,
            let remote = listing.githubRemoteName
        else { return nil }
        return (repository, remote)
    }

    /// Copies `text` as it is shown (`RowActions.clipboardText`).
    func copy(_ text: String) {
        rowActions.copy(RowActions.clipboardText(text))
    }

    /// Show in Graph (branch rows, Show Linked Branch): selects a loaded tip and scrolls to it; a tip beyond the
    /// loaded pages is only highlighted.
    func showInGraph(_ oid: ObjectID) {
        selectLinkedCommit(oid)
        graph.scroll(to: oid)
    }

    func message(of commit: CommitNode) -> String {
        if commitDetail.commit?.oid == commit.oid, case .loaded(let detail) = commitDetail.detail {
            return detail.message.trimmingCharacters(in: .newlines)
        }
        return commit.subject
    }

    func fullPath(of path: GitPath, in worktree: GitPath?) -> String? {
        guard path.isRepresentable, let root = worktree ?? focusedWorktreePath else { return nil }
        return URL(fileURLWithPath: root.display).appendingPathComponent(path.display).path
    }

    /// Reveal in Finder for a file row: only when its real location is inside the worktree (T14).
    func revealFile(_ path: GitPath, in worktree: GitPath?) {
        guard path.isRepresentable, let root = worktree ?? focusedWorktreePath else { return }
        let rootURL = URL(fileURLWithPath: root.display, isDirectory: true)
        switch RowActions.revealTarget(rootURL.appendingPathComponent(path.display), within: rootURL) {
        case .success(let url): rowActions.reveal(url)
        case .failure(let refusal): alert = AppAlert(title: "Can’t Reveal in Finder", message: refusal.message)
        }
    }

    func revealWorktree(_ path: GitPath) {
        // Never from a launch snapshot's rows (ADR-0018 §5): its paths are not this load's.
        guard !worktreeList.isSnapshot, let folder = existingFolder(path, action: "Reveal in Finder") else { return }
        rowActions.reveal(folder)
    }

    /// Opens directly only when the worktree's settings were checked and hold nothing that runs code; otherwise
    /// asks first (`TerminalGuard`).
    func openTerminal(at path: GitPath) {
        // Never from a launch snapshot's rows (ADR-0018 §5): its paths are not this load's.
        guard !worktreeList.isSnapshot, let folder = existingFolder(path, action: "Open in Terminal") else { return }
        let hooks =
            repository.map { LiveWorktreeInspector.hookExecutables(in: $0.repository.commonGitDirectoryURL) } ?? []
        let reasons = TerminalGuard.reasons(
            inspection: entry(at: path)?.inspection, hooks: hooks, isUntrusted: isRepositoryUntrusted)
        if reasons.isEmpty {
            rowActions.openTerminal(at: folder)
        } else {
            terminalConfirmation = TerminalConfirmation(folder: folder, reasons: reasons)
        }
    }

    /// "Open Anyway".
    func confirmOpenTerminal() {
        guard let confirmation = terminalConfirmation else { return }
        terminalConfirmation = nil
        rowActions.openTerminal(at: confirmation.folder)
    }

    func openInBrowser(_ url: URL) {
        switch RowActions.browserTarget(url) {
        case .success(let checked): rowActions.openInBrowser(checked)
        case .failure(let refusal): alert = AppAlert(title: "Can’t Open Link", message: refusal.message)
        }
    }

    /// Show Linked Branch on an issue row: the first linked local branch's tip, else a remote one.
    func linkedBranchTip(of number: Int) -> ObjectID? {
        let branches = issueLinks.links(number).branches
        return (branches.first { !$0.isRemote } ?? branches.first)?.target
    }

    /// Show Changes / Show Info on a worktree row: focuses it, then picks the segment.
    func showWorktree(_ path: GitPath, info: Bool) {
        if focusedWorktreePath != path || selection?.worktreePath != path { selectWorktree(path) }
        if info { showWorktreeDetail() } else { showChanges() }
    }

    /// A worktree folder that is still there; a listed worktree is git's own record, so it may be anywhere.
    private func existingFolder(_ path: GitPath, action: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.display, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            alert = AppAlert(title: "Can’t \(action)", message: "The worktree folder no longer exists.")
            return nil
        }
        return URL(fileURLWithPath: path.display, isDirectory: true)
    }
}
