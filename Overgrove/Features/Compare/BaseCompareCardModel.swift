import Foundation

/// The focused worktree's comparison with its base branch, for the card pinned under S-02 and S-05 (#581). It is
/// the same comparison S-11 runs by default (uncommitted changes included, the base S-11 would pick), so the two share
/// `RepositoryService`'s cache and show the same values.
struct BaseCompareSummary: Equatable {
    let worktree: GitPath
    /// The base the user picked for this worktree, else the one the result came back with; `nil` until known.
    var base: FullRefName?
    /// Branches the base menu offers (S-11's list).
    var bases: [FullRefName] = []
    var result: ComparisonLoadState = .loading
}

/// The card's texts (art-direction.md §7, screens.md S-02 "비교 카드"). Pure, so it is unit tested without views.
struct BaseCompareCardModel: Equatable {
    enum State: Equatable {
        case loading(String)
        /// No base branch: the card says so and keeps only the button.
        case noBase(String)
        case failed(String)
        /// `1 commit ahead · 0 behind · 4 files`, the line totals, and the base tip.
        case loaded(summary: String, added: Int, deleted: Int, baseCommit: String)
    }

    /// The focused worktree's status as far as the card goes. Only a list that is still loading is worth waiting for:
    /// a missing folder, a failed status, or one that was not queried stays that way until the next load (#684).
    enum WorktreeStatus: Equatable {
        /// The worktree list is not loaded yet, so the status is on its way.
        case pending
        case loaded
        /// The folder is gone (prunable, or deleted since); its status is never queried.
        case missing
        /// The status failed or was not queried in this load (blocked, bare, a duplicate, …); the detail says why.
        case unavailable

        init(_ entry: WorktreeListing.Entry?) {
            switch entry?.state {
            case nil: self = .pending
            case .loaded: self = .loaded
            case .missing: self = .missing
            case .failed, .notQueried: self = .unavailable
            }
        }
    }

    struct BaseChoice: Equatable, Identifiable {
        let ref: FullRefName
        let name: String
        var id: String { ref.value }
    }

    /// `main`, `origin/main` (escaped), or `base branch` before one is known.
    let baseName: String
    let bases: [BaseChoice]
    let state: State
    /// `Compare with Base…` opens S-11; off while the worktree's status is not loaded.
    let canCompare: Bool

    init(summary: BaseCompareSummary?, status: WorktreeStatus) {
        canCompare = status == .loaded
        let base = summary?.base
        baseName = base.map(ComparisonModel.shortName) ?? String(localized: "base branch")
        // A worktree that cannot be compared keeps the base menu off, as the button.
        let offered = status == .missing || status == .unavailable ? [] : summary?.bases ?? []
        bases = offered.map { BaseChoice(ref: $0, name: ComparisonModel.shortName($0)) }
        switch status {
        case .loaded:
            break
        case .pending:
            if summary == nil {
                state = .failed(String(localized: "Waiting for this worktree's status."))
                return
            }
        case .missing:
            state = .failed(String(localized: "The worktree folder is missing, so it cannot be compared."))
            return
        case .unavailable:
            state = .failed(ComparisonError.worktreeNotQueried.message)
            return
        }
        switch summary?.result ?? .loading {
        case .loading:
            state = .loading(String(localized: "Comparing with \(baseName)…"))
        case .failed(.noBaseBranch):
            state = .noBase(String(localized: "No base branch to compare with."))
        case .failed(let error):
            // The message can carry masked stderr, which still keeps separators such as U+2028.
            state = .failed(PathValidator.displayable(error.message))
        case .loaded(let comparison):
            let totals = ComparisonModel.lineTotals(comparison)
            state = .loaded(
                summary: ComparisonModel.aheadBehind(comparison) + " · " + ComparisonModel.fileCount(comparison),
                added: totals.added, deleted: totals.deleted, baseCommit: comparison.baseTip.short)
        }
    }
}
