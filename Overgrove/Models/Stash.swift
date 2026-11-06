import Foundation

/// One entry of `git stash list` (parsing-spec.md §4).
struct Stash: Sendable, Hashable, Identifiable {
    /// `n` in `stash@{n}`. Changes when stashes are added or dropped; use `oid` to address a stash.
    let index: Int
    let oid: ObjectID
    /// Raw reflog subject, e.g. `WIP on main: 837976f mine`.
    let subject: String
    /// Branch extracted from the subject, if it matched `(WIP on|On) <branch>: <message>`.
    let branch: String?
    /// Message extracted from the subject, or the whole subject.
    let message: String
    let date: Date

    var id: ObjectID { oid }
    var refName: String { "stash@{\(index)}" }
}

/// Files changed in a stash (`stash show --include-untracked --numstat -z`, parsing-spec.md §8.2).
struct StashDetail: Sendable, Hashable {
    let stash: Stash
    let files: [FileStat]
    let isPartial: Bool
}
