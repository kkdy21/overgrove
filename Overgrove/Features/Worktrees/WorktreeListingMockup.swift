import Foundation

#if DEBUG
    extension WorktreeListing {
        /// The mockup's worktrees (design/mockups/main-window-*.png), for previews and tests. No file system or git.
        static var mockup: WorktreeListing {
            WorktreeListing(
                entries: [
                    entry("/tmp/dev/api", branch: "main", isMain: true, state: .loaded(state(branch: "main"))),
                    entry(
                        "/tmp/dev/api-wt/42-rate-limit", branch: "feat/42-rate-limit",
                        state: .loaded(
                            state(
                                branch: "feat/42-rate-limit", staged: 3, unstaged: 2, untracked: 1,
                                upstream: .tracking(upstream: "origin/feat/42-rate-limit", ahead: 2, behind: 0)))),
                    entry(
                        "/tmp/dev/api-wt/login", branch: "fix/login",
                        state: .loaded(
                            state(
                                branch: "fix/login", unstaged: 1, conflicted: 1,
                                upstream: .tracking(upstream: "origin/fix/login", ahead: 0, behind: 3)))),
                    entry(
                        "/tmp/dev/api-wt/review", branch: nil, head: "c46c37d0000000000000000000000000000000aa",
                        state: .loaded(state(branch: nil))),
                    entry(
                        "/tmp/dev/api-wt/hotfix", branch: "hotfix", lock: .locked(reason: "release in progress"),
                        state: .loaded(state(branch: "hotfix"))),
                    entry(
                        "/tmp/dev/api-wt/old-spike", branch: "spike/cache", isPrunable: true, state: .missing),
                ],
                isPartial: false)
        }

        static func entry(
            _ path: String, branch: String?, head: String = "a91f3c2000000000000000000000000000000000",
            isMain: Bool = false, lock: Worktree.Lock = .unlocked, isPrunable: Bool = false, state: State
        ) -> Entry {
            Entry(
                worktree: Worktree(
                    path: GitPath(path), head: ObjectID(head), branch: branch.map { "refs/heads/\($0)" },
                    isMain: isMain, isDetached: branch == nil, isBare: false, lock: lock, isPrunable: isPrunable,
                    prunableReason: isPrunable ? "gitdir file points to non-existent location" : nil),
                state: state)
        }

        static func state(
            branch: String?, staged: Int = 0, unstaged: Int = 0, untracked: Int = 0, conflicted: Int = 0,
            upstream: UpstreamStatus = .none, isPartial: Bool = false, skippedRecords: Int = 0
        ) -> WorkingState {
            func files(_ count: Int, _ prefix: String, _ status: FileChange.Status) -> [FileChange] {
                (0..<count).map { FileChange(path: GitPath("\(prefix)\($0).swift"), status: status) }
            }
            return WorkingState(
                headCommit: ObjectID("a91f3c2000000000000000000000000000000000"),
                head: branch.map(WorkingState.Head.branch) ?? .detached,
                upstream: upstream,
                stashCount: 0,
                staged: files(staged, "staged", .modified),
                unstaged: files(unstaged, "unstaged", .modified),
                untracked: files(untracked, "new", .untracked),
                conflicted: files(conflicted, "conflict", .conflicted(.bothModified)),
                isPartial: isPartial,
                skippedRecords: skippedRecords)
        }
    }
#endif
