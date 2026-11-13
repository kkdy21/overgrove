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

    init(summary: BaseCompareSummary?, canCompare: Bool) {
        self.canCompare = canCompare
        let base = summary?.base
        baseName = base.map(ComparisonModel.shortName) ?? String(localized: "base branch")
        bases = (summary?.bases ?? []).map { BaseChoice(ref: $0, name: ComparisonModel.shortName($0)) }
        if summary == nil, !canCompare {
            state = .failed(String(localized: "Waiting for this worktree's status."))
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
