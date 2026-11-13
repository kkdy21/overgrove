import SwiftUI

/// What the detail panel's header names, and the mark beside the name (#578, art-direction.md §7 "대상 표시"). It
/// follows the same order as the panel's content, so the header always speaks for what is below it.
struct DetailHeader: Equatable {
    enum Mark: Equatable {
        /// The worktree tile in its branch's lane colour, as in the sidebar; `nil` lane for a neutral tile.
        case worktree(laneIndex: Int?)
        /// The author's avatar in a ring of the commit's lane colour, as in the graph.
        case commit(initials: String, avatarIndex: Int, laneIndex: Int)
        case stash
        case issue
        /// S-11 and S-12.
        case comparison
        case none
    }

    let title: String
    let mark: Mark

    /// The panel's subjects in the order its content picks them.
    struct Subject {
        /// S-11: the base branch's short name (`ComparisonModel.baseName`).
        var comparisonBase: String?
        /// S-12: `3c5d6f1 → a91f3c2`.
        var commitComparisonTitle: String?
        var commit: (shortSHA: String, author: CommitDetailModel.Person, laneIndex: Int)?
        var issueNumber: String?
        var stashRef: String?
        /// The WIP, the worktree facts, or the focused worktree while it loads.
        var worktreeTitle: String?
        var worktreeLane: Int?
    }

    init(title: String, mark: Mark) {
        self.title = title
        self.mark = mark
    }

    init(_ subject: Subject) {
        if let base = subject.comparisonBase {
            self.init(title: String(localized: "Changes vs \(base)"), mark: .comparison)
        } else if let title = subject.commitComparisonTitle {
            self.init(title: title, mark: .comparison)
        } else if let commit = subject.commit {
            self.init(
                title: String(localized: "Commit \(commit.shortSHA)"),
                mark: .commit(
                    initials: commit.author.initials, avatarIndex: commit.author.avatarIndex,
                    laneIndex: commit.laneIndex))
        } else if let number = subject.issueNumber {
            self.init(title: number, mark: .issue)
        } else if let ref = subject.stashRef {
            self.init(title: ref, mark: .stash)
        } else if let title = subject.worktreeTitle {
            self.init(title: title, mark: .worktree(laneIndex: subject.worktreeLane))
        } else {
            self.init(title: String(localized: "No selection"), mark: .none)
        }
    }
}

/// The header mark (#578): 18pt, the size of the panel header's symbols.
struct DetailHeaderMark: View {
    let mark: DetailHeader.Mark

    var body: some View {
        Group {
            switch mark {
            case .worktree(let laneIndex):
                let lane = laneIndex.map(Self.lane)
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(lane.map { $0.opacity(WorktreeRowView.tileLaneOpacity) } ?? Tokens.Color.surfaceRaised)
                    .frame(width: Self.size, height: Self.size)
                    .overlay {
                        Image(systemName: "tree").font(Tokens.Font.caption)
                            .foregroundStyle(lane ?? Tokens.Color.textSecondary)
                    }
            case .commit(let initials, let avatarIndex, let laneIndex):
                Circle().fill(Self.lane(laneIndex)).frame(width: Self.size + 2, height: Self.size + 2)
                    .overlay { GraphChipAvatar(initials: initials, avatarIndex: avatarIndex) }
            case .stash:
                symbol("archivebox")
            case .issue:
                symbol("number.circle")
            case .comparison:
                symbol("arrow.left.arrow.right")
            case .none:
                symbol("doc.text.magnifyingglass")
            }
        }
        .accessibilityHidden(true)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).foregroundStyle(Tokens.Color.textSecondary)
            .frame(width: Self.size, height: Self.size)
    }

    private static func lane(_ index: Int) -> Color {
        Tokens.Color.graphLanes[index % Tokens.Color.graphLanes.count]
    }

    /// No token: the 16pt avatar plus its ring, and the sidebar tile scaled to the header.
    static let size: CGFloat = 18
}
