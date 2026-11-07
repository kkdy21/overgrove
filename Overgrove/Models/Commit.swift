import Foundation

/// A commit as needed by the graph and file history (`%H %P %an %ae %at %s`, parsing-spec.md §5.1).
struct CommitNode: Sendable, Hashable, Identifiable {
    let oid: ObjectID
    /// Empty for a root commit, two or more for merges.
    let parents: [ObjectID]
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let subject: String
    /// `Co-authored-by` trailer values as git printed them (`Name <email>`), in message order. Display only: a
    /// repository can write anything here.
    let coAuthors: [String]

    init(
        oid: ObjectID,
        parents: [ObjectID],
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        subject: String,
        coAuthors: [String] = []
    ) {
        self.oid = oid
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.subject = subject
        self.coAuthors = coAuthors
    }

    var id: ObjectID { oid }
    var isMerge: Bool { parents.count > 1 }
}

/// Full commit information for the detail pane (parsing-spec.md §5.2 and §8.1).
struct CommitDetail: Sendable, Hashable {
    let oid: ObjectID
    let parents: [ObjectID]
    let authorName: String
    let authorEmail: String
    let authorDate: Date
    let committerName: String
    let committerEmail: String
    let committerDate: Date
    /// Full message including the body; trailing newlines are preserved.
    let message: String
    let files: [FileStat]
    let isPartial: Bool

    var subject: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }
}

/// One step of `git log --follow -- <path>` (S-09).
struct FileHistoryEntry: Sendable, Hashable, Identifiable {
    let commit: CommitNode
    /// The file's path in this commit (it changes across renames).
    let path: GitPath

    var id: ObjectID { commit.oid }
}
