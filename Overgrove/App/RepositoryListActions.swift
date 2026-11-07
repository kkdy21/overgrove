import Foundation

/// Adding and removing registered repositories outside a window (Settings › Repositories, S-08, #86), with the
/// same steps a window takes (`AppState.addRepository`, `removeRepository`). Windows showing a removed repository
/// close it (`AppState.closeIfUnregistered`).
@MainActor
struct RepositoryListActions {
    enum AddOutcome: Equatable {
        case added(notice: String?)
        case alreadyRegistered(name: String, path: String)
        case failed(String)
        case cancelled
    }

    let registry: RepositoryRegistry
    let registrar: RepositoryRegistrar
    let fetchRecords: FetchRecordStore
    let loader: any RepositoryLoading

    /// Checks a picked folder the way a window does (#84) and registers it.
    func add(_ folder: URL) async -> AddOutcome {
        do {
            let registration = try await registrar.register(folder)
            switch registry.add(registration.entry) {
            case .added:
                return .added(notice: registration.notice)
            case .alreadyRegistered:
                let existing = registry.repository(withID: registration.entry.id)
                return .alreadyRegistered(name: existing?.name ?? "", path: existing?.displayRootPath ?? "")
            case .rejected:
                return .failed(RegistrationError.invalidPath(.controlCharacters).message)
            }
        } catch {
            return error == .git(.cancelled) ? .cancelled : .failed(error.message)
        }
    }

    /// Forgets a repository: its registration, fetch record, and cached results. Its folder is not touched.
    func remove(_ id: RegisteredRepository.ID) {
        guard let removed = registry.repository(withID: id)?.repository else { return }
        registry.remove(id)
        fetchRecords.remove(removed.id)
        let loader = loader
        Task { await loader.forget(removed) }
    }
}
