import Foundation

/// One progress update of a running `git fetch` (parsing-spec.md §11.4).
///
/// Only a phase and numbers are kept. The `remote:` lines come from the server, so no text from them reaches the UI.
struct FetchProgress: Sendable, Equatable {
    /// git's phases, in the order they run. The first three are reported by the remote.
    enum Phase: Int, Sendable, Comparable, CaseIterable {
        case enumerating, counting, compressing, receiving, resolving

        static func < (lhs: Phase, rhs: Phase) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let phase: Phase
    let completed: Int
    /// `nil` when git reports a count only (`Enumerating objects: 304, done.`).
    let total: Int?
    let isDone: Bool

    /// Share of this phase that is complete, or `nil` without a known, non-zero total.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }
}
