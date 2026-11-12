import Foundation

/// Adding, opening, and removing registered repositories, and panel layout. Moved out of `AppState.swift` unchanged (#253).
extension AppState {
    // MARK: Registration (#84)

    /// Registers a folder picked in `NSOpenPanel` and opens it. A worktree of a repository that is already registered
    /// opens that repository instead of adding it twice.
    func addRepository(at folder: URL) async {
        guard !isAddingRepository else { return }
        isAddingRepository = true
        defer { isAddingRepository = false }
        do {
            let registration = try await registrar.register(folder)
            switch registry.add(registration.entry) {
            case .added:
                openRegistered(registration.entry.id)
                if let notice = registration.notice {
                    alert = AppAlert(title: String(localized: "Repository Added"), message: notice)
                }
            case .alreadyRegistered:
                guard let existing = registry.repository(withID: registration.entry.id) else { return }
                openRegistered(existing.id)
                alert = AppAlert(
                    title: String(localized: "Repository Already Added"),
                    message: String(
                        localized: "“\(existing.name)” is already in Overgrove, at \(existing.displayRootPath)."))
            case .rejected:
                // The registrar's checks make this unreachable; refuse rather than store a malformed path.
                alert = AppAlert(
                    title: String(localized: "Couldn’t Add Repository"),
                    message: RegistrationError.invalidPath(.controlCharacters).message)
            }
        } catch {
            if error != .git(.cancelled) {
                alert = AppAlert(title: String(localized: "Couldn’t Add Repository"), message: error.message)
            }
        }
    }

    /// Opens a registered repository. Its folder must still be where it was registered, not replaced by a symbolic
    /// link to somewhere else (T14); otherwise it stays closed and the alert says so.
    ///
    /// This is defense in depth only; it runs no git. The repository can still change before git runs, so the
    /// data loaders (#65) inspect it with `RepoConfigInspector` every time it is opened.
    /// - Parameter quietly: No alert for a missing folder (restoring at launch).
    func openRegistered(_ id: RegisteredRepository.ID, quietly: Bool = false) {
        guard let entry = registry.repository(withID: id) else { return }
        let location = URL(fileURLWithPath: entry.locationPath, isDirectory: true)
        guard let checked = try? PathValidator.checkRegistration(location), checked.resolved.path == entry.locationPath
        else {
            if !quietly {
                alert = AppAlert(
                    title: String(localized: "Repository Not Found"),
                    message: String(
                        localized:
                            "The folder of “\(entry.name)” is missing or was replaced (\(entry.displayRootPath)). Restore it, or remove the repository from Overgrove."
                    ))
            }
            return
        }
        // Picking the open repository again keeps everything as it is (#497): a reload would reset the selection,
        // history, search, filters and comparison.
        if repository?.repository.id == entry.repository.id {
            registry.lastSelected = id
            return
        }
        // No owner yet: the switcher takes it from the issue source a verified load picks (`displayedRepository`,
        // #477), never from remotes before they are inspected.
        open(RepositoryContext(repository: entry.repository, owner: nil))
        registry.lastSelected = id
        reload()
    }

    /// Opens the repository shown last, once, when the window has none.
    func restoreLastSelected() {
        // First run: nothing registered yet, so the setup assistant opens (S-07).
        if repository == nil, registry.repositories.isEmpty { return setup.present() }
        guard repository == nil, let id = registry.lastSelected else { return }
        openRegistered(id, quietly: true)
    }

    /// Removes a repository from Overgrove; its folder is not touched. Closes it if this window shows it.
    func removeRepository(_ id: RegisteredRepository.ID) {
        let removed = registry.repository(withID: id)?.repository
        registry.remove(id)
        if repository?.repository.id == id { close() }
        // Its cached results, inspections, and fetch record go too (`RepositoryService.forget`, overview.md §5, §8).
        if let removed {
            fetch.forget(removed.id)
            launchSnapshots?.delete(for: removed)
            let loader = loader
            forgetTask = Task { [weak self] in
                // Added again in the meantime: its new load must not be cancelled (security review of #243).
                guard self?.registry.repository(withID: id) == nil else { return }
                await loader.forget(removed)
            }
        }
    }

    /// Settings › Repositories removed the open repository (#86): close it here too.
    func closeIfUnregistered() {
        guard let id = repository?.repository.id, registry.repository(withID: id) == nil else { return }
        close()
    }

    private func close() {
        launchSnapshotTask?.cancel()
        repository = nil
        panelLayout = .default
        graphColumns = .default
        clearRepositoryData()
    }

    /// The toolbar's sidebar button and the View menu.
    func togglePanel(_ side: PanelLayout.Side) {
        commitPanelLayout(panelLayout.toggling(side))
    }
}
