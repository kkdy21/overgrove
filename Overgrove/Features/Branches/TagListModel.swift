import Foundation

/// One row of TAGS (information-architecture.md §4.5, #377).
struct TagRow: Identifiable, Equatable {
    /// The full ref name, e.g. `refs/tags/v1.4.0` (unique).
    let id: String
    /// The short name, escaped.
    let name: String
    /// The commit the tag points to: the peeled commit for an annotated tag. Selecting the row selects it.
    let commit: ObjectID
    /// When the tag was made: the tagger date for an annotated tag, the commit's committer date for a lightweight one.
    let date: Date?
    let isAnnotated: Bool
    /// A worktree's detached HEAD is on this commit (`tree` mark, §4.3).
    let hasDetachedWorktree: Bool
    let help: String
    /// Without the relative date, which the view adds with the current time.
    let accessibilityLabel: String
}

/// TAGS built from the cached refs (information-architecture.md §4.2, §4.5). Pure, so it is unit tested without
/// views; every tag name is escaped.
struct TagListModel: Equatable {
    /// Rows drawn at most; the rest are counted (§4.5). The filter still looks at every tag.
    static let maximumRows = 200

    /// Every tag, newest first.
    let rows: [TagRow]
    var count: Int { rows.count }

    init(tags: [Tag], detachedHeads: Set<ObjectID>) {
        let built = tags.map { tag -> TagRow in
            let name = PathValidator.displayable(tag.shortName)
            let isAnnotated = tag.peeledTarget != nil
            let hasDetachedWorktree = detachedHeads.contains(tag.commit)
            let kind =
                isAnnotated ? String(localized: "Annotated tag \(name)") : String(localized: "Lightweight tag \(name)")
            var help = [kind, String(localized: "Commit \(tag.commit.short)")]
            if hasDetachedWorktree { help.append(String(localized: "A worktree is checked out at this commit")) }
            var label = [kind]
            if hasDetachedWorktree { label.append(String(localized: "checked out in a worktree")) }
            return TagRow(
                id: tag.fullName, name: name, commit: tag.commit, date: tag.date, isAnnotated: isAnnotated,
                hasDetachedWorktree: hasDetachedWorktree, help: help.joined(separator: "\n"),
                accessibilityLabel: label.joined(separator: ", "))
        }
        // Newest first; equal or missing dates by name, missing dates last (§4.2).
        rows = built.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case (let left?, let right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// The rows to draw for the sidebar filter `query` (`nil` when empty), at most `maximumRows`, and how many matching
    /// rows were left out.
    func visible(query: String?) -> (rows: [TagRow], hidden: Int) {
        let matching = query == nil ? rows : rows.filter { SidebarFilter.matches(query, $0.name) }
        let shown = Array(matching.prefix(Self.maximumRows))
        return (shown, matching.count - shown.count)
    }
}
