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
    /// `%P`: base commit, index commit, and (with `-u`/`-a`) the untracked-files commit, in that order.
    let parents: [ObjectID]

    var id: ObjectID { oid }
    /// The commit the stash was made on (first parent).
    var baseCommit: ObjectID? { parents.first }
    /// The stash recorded the index (second parent; `git stash` always makes one).
    var includesIndex: Bool { parents.count >= 2 }
    /// The stash has an untracked-files commit (third parent, `git stash -u`).
    var includesUntracked: Bool { parents.count >= 3 }
    var refName: String { "stash@{\(index)}" }
}

/// Files changed in a stash (`stash show --include-untracked --numstat -z`, parsing-spec.md §8.2).
struct StashDetail: Sendable, Hashable {
    let stash: Stash
    let files: [FileStat]
    let isPartial: Bool
}
