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
            hasEditor: settings.editorApp != nil,
            openEditor: { [weak self] in self?.openEditor(at: $0) },
            openFileInEditor: { [weak self] in self?.openFileInEditor($1, in: $0) },
            canQuickLook: QuickLook.isAvailable(),
            quickLook: { [weak self] in self?.quickLook($1, in: $0) },
            showStash: { [weak self] in self?.selectStash($0) },
            openInBrowser: { [weak self] in self?.openInBrowser($0) },
            gitHubCommitURL: { [weak self] oid in self?.gitHub.flatMap { GitHubLinks.commit($0.repository, oid) } },
            // The target already names the tracked remote's repository (#406); no single GitHub remote is assumed.
            gitHubBranchURL: { GitHubLinks.tree($0) },
            gitHubFileURL: { [weak self] oid, path in
                self?.gitHub.flatMap { GitHubLinks.file($0.repository, commit: oid, path: path) }
            },
            linkedBranchTip: { [weak self] in self?.linkedBranchTip(of: $0) },
            showHistory: { [weak self] in self?.showHistory(of: $1, in: $0) })
    }

    /// The GitHub repository and its remote on a trusted host, from the loaded worktree list (#398, ADR-0025).
    var gitHub: (repository: GitHubRepository, remote: String)? {
        guard case .loaded(let listing) = worktreeList, let match = listing.githubMatch(trusting: trustedGitHubHosts)
        else { return nil }
        return (match.repository, match.name)
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

    /// Quick Look for a working tree file row (#399): macOS 15 and later, a regular file inside the worktree.
    func quickLook(_ path: GitPath, in worktree: GitPath?, available: Bool = QuickLook.isAvailable()) {
        guard available, let root = worktree ?? focusedWorktreePath else { return }
        switch QuickLook.target(path, in: URL(fileURLWithPath: root.display, isDirectory: true)) {
        case .success(let url): quickLookURL = url
        case .failure(let refusal):
            alert = AppAlert(title: String(localized: "Can’t Preview"), message: refusal.message)
        }
    }

    /// Reveal in Finder for a file row: only when its real location is inside the worktree (T14).
    func revealFile(_ path: GitPath, in worktree: GitPath?) {
        guard path.isRepresentable, let root = worktree ?? focusedWorktreePath else { return }
        let rootURL = URL(fileURLWithPath: root.display, isDirectory: true)
        switch RowActions.revealTarget(rootURL.appendingPathComponent(path.display), within: rootURL) {
        case .success(let url): rowActions.reveal(url)
        case .failure(let refusal):
            alert = AppAlert(title: String(localized: "Can’t Reveal in Finder"), message: refusal.message)
        }
    }

    func revealWorktree(_ path: GitPath) {
        // Never from a launch snapshot's rows (ADR-0018 §5): its paths are not this load's.
        guard !worktreeList.isSnapshot,
            let folder = existingFolder(path, alertTitle: String(localized: "Can’t Reveal in Finder"))
        else { return }
        rowActions.reveal(folder)
    }

    /// Opens the worktree in the chosen terminal (Terminal.app by default, #124). Opens directly only when the
    /// worktree's settings were checked and hold nothing that runs code; otherwise asks first (`TerminalGuard`).
    func openTerminal(at path: GitPath) {
        openFolder(path, role: .terminal, bundleIdentifier: settings.terminalBundleIdentifier)
    }

    /// Open in Editor on a worktree row (#124): the same check as the terminal, since editors run workspace settings
    /// and tasks and their git uses the repository's settings.
    func openEditor(at path: GitPath) {
        guard let editor = settings.editorApp else { return }
        openFolder(path, role: .editor, bundleIdentifier: editor)
    }

    private func openFolder(_ path: GitPath, role: ExternalAppRole, bundleIdentifier: String) {
        // Never from a launch snapshot's rows (ADR-0018 §5): its paths are not this load's.
        guard !worktreeList.isSnapshot, let folder = existingFolder(path, alertTitle: role.cantOpenTitle) else {
            return
        }
        guard let name = usableApplication(bundleIdentifier, role: role) else { return }
        let hooks =
            repository.map { LiveWorktreeInspector.hookExecutables(in: $0.repository.commonGitDirectoryURL) } ?? []
        let reasons = TerminalGuard.reasons(
            inspection: entry(at: path)?.inspection, hooks: hooks, isUntrusted: isRepositoryUntrusted)
        if reasons.isEmpty {
            open(folder, in: bundleIdentifier, role: role)
        } else {
            terminalConfirmation = TerminalConfirmation(
                folder: folder, reasons: reasons, role: role, bundleIdentifier: bundleIdentifier, appName: name)
        }
    }

    /// Open in Editor on a working tree file row (#124): one regular file whose real location is inside its
    /// worktree (T14). A link to a folder, a package, an executable, or a file macOS would run instead of open is
    /// refused, so a file row cannot open a folder without the folder's confirmation. Opens without asking unless the
    /// repository is marked untrusted.
    func openFileInEditor(_ path: GitPath, in worktree: GitPath?) {
        guard let editor = settings.editorApp, path.isRepresentable, let root = worktree ?? focusedWorktreePath
        else { return }
        let rootURL = URL(fileURLWithPath: root.display, isDirectory: true)
        let target: URL
        switch RowActions.revealTarget(rootURL.appendingPathComponent(path.display), within: rootURL) {
        case .success(let url): target = url
        case .failure(let refusal):
            alert = AppAlert(title: ExternalAppRole.editor.cantOpenTitle, message: refusal.message)
            return
        }
        guard Self.isOpenableFile(target) else {
            alert = AppAlert(
                title: ExternalAppRole.editor.cantOpenTitle,
                message: String(
                    localized:
                        "Overgrove opens regular files only: not folders, packages, executables, or files macOS runs."))
            return
        }
        guard let name = usableApplication(editor, role: .editor) else { return }
        if isRepositoryUntrusted {
            terminalConfirmation = TerminalConfirmation(
                folder: target, reasons: [TerminalGuard.untrustedReason], role: .editor, bundleIdentifier: editor,
                appName: name, isFile: true)
        } else {
            open(target, in: editor, role: .editor)
        }
    }

    /// File types macOS runs or follows when "opened" (Terminal command files, locations, apps), refused for files.
    static let runnableExtensions: Set<String> = [
        "command", "tool", "terminal", "webloc", "inetloc", "fileloc", "app", "workflow", "action", "scpt",
        "scptd", "applescript", "pkg", "mpkg",
    ]

    /// A regular file, not a package, without an execute bit, and not of a type macOS runs.
    static func isOpenableFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey]),
            values.isRegularFile == true, values.isPackage != true,
            !FileManager.default.isExecutableFile(atPath: url.path)
        else { return false }
        return !runnableExtensions.contains(url.pathExtension.lowercased())
    }

    /// The chosen app's name when it is installed and not inside a registered repository or one of this
    /// repository's worktrees (a repository could hold an app claiming the same bundle identifier, #124).
    private func usableApplication(_ bundleIdentifier: String, role: ExternalAppRole) -> String? {
        guard let url = rowActions.applicationURL(bundleIdentifier),
            let name = rowActions.applicationName(bundleIdentifier)
        else {
            alert = AppAlert(title: role.cantOpenTitle, message: role.missingAppMessage)
            return nil
        }
        if isInsideRepository(url) {
            alert = AppAlert(title: role.cantOpenTitle, message: role.insideRepositoryMessage)
            return nil
        }
        return name
    }

    private func isInsideRepository(_ url: URL) -> Bool {
        let real = (PathValidator.canonical(url) ?? url).path
        var roots = registry.repositories.flatMap { [$0.rootPath, $0.commonDirectoryPath].compactMap { $0 } }
        if case .loaded(let listing) = worktreeList { roots += listing.entries.map(\.worktree.path.display) }
        return roots.contains { root in
            let realRoot = (PathValidator.canonical(URL(fileURLWithPath: root)) ?? URL(fileURLWithPath: root)).path
            return real == realRoot || real.hasPrefix(realRoot + "/")
        }
    }

    /// "Open Anyway".
    func confirmOpenTerminal() {
        guard let confirmation = terminalConfirmation else { return }
        terminalConfirmation = nil
        open(confirmation.folder, in: confirmation.bundleIdentifier, role: confirmation.role)
    }

    private func open(_ item: URL, in bundleIdentifier: String, role: ExternalAppRole) {
        if !rowActions.open(item, inApplication: bundleIdentifier) {
            alert = AppAlert(title: role.cantOpenTitle, message: role.missingAppMessage)
        }
    }

    func openInBrowser(_ url: URL) {
        switch RowActions.browserTarget(url) {
        case .success(let checked): rowActions.openInBrowser(checked)
        case .failure(let refusal):
            alert = AppAlert(title: String(localized: "Can’t Open Link"), message: refusal.message)
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
    private func existingFolder(_ path: GitPath, alertTitle: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.display, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            alert = AppAlert(title: alertTitle, message: String(localized: "The worktree folder no longer exists."))
            return nil
        }
        return URL(fileURLWithPath: path.display, isDirectory: true)
    }
}
