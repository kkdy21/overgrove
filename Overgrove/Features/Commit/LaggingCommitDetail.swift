import SwiftUI

/// A commit as the detail panel shows it: its details and its graph lane (#649).
struct ShownCommit: Equatable {
    let model: CommitDetailModel
    let lane: Int
}

/// S-03 while the selection moves through the graph (#637, interaction.md §4: a loading state shows only after
/// 150 ms). When another commit is selected and its details are still loading, the commit shown last stays for up
/// to `loadingIndicatorDelay`. A load that finishes in time (most do: 30–80 ms on ↑/↓) replaces it directly, so
/// stepping through commits shows no spinner and no rows that appear late (Committer, Refs) and push the layout
/// down. A slower load shows the new commit with its loading state once the delay is over.
///
/// It wraps the whole detail panel (#649): the header (`Commit <SHA>`, avatar) and the body (rows, the Refs pills
/// in the commit's lane color) read the same shown commit, so they never show two different commits.
struct LaggingCommitDetail<Content: View>: View {
    /// The selected commit, or `nil` when no commit is selected (the panel follows at once).
    let selected: ShownCommit?
    /// The commit to show, and whether it is the selected one (a commit kept for a moment is not, and its content
    /// should not take clicks).
    @ViewBuilder let content: (_ shown: ShownCommit?, _ isSelected: Bool) -> Content

    @State private var shown: ShownCommit?
    @State private var latest: ShownCommit?
    @State private var waiting: Task<Void, Never>?

    var body: some View {
        let current = shown ?? selected
        content(current, current?.model.fullSHA == selected?.model.fullSHA)
            .onChange(of: selected, initial: true) { _, new in show(new) }
            .onDisappear { waiting?.cancel() }
    }

    private func show(_ new: ShownCommit?) {
        latest = new
        waiting?.cancel()
        waiting = nil
        guard let current = shown, let new, Self.keepsShowing(current.model, whileLoading: new.model) else {
            shown = new
            return
        }
        waiting = Task { @MainActor in
            try? await Task.sleep(for: loadingIndicatorDelay)
            guard !Task.isCancelled else { return }
            shown = latest
        }
    }

    /// Keep `current` while `new` is another commit that has not loaded yet, and only if `current` itself had loaded
    /// (a loading state already on screen just follows the selection).
    static func keepsShowing(_ current: CommitDetailModel, whileLoading new: CommitDetailModel) -> Bool {
        current.fullSHA != new.fullSHA && new.files == .loading && current.files != .loading
    }
}
