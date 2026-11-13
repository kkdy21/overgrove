import SwiftUI

/// S-03 while the selection moves through the graph (#637, interaction.md §4: a loading state shows only after
/// 150 ms). When another commit is selected and its details are still loading, the commit shown last stays for up
/// to `loadingIndicatorDelay`. A load that finishes in time (most do: 30–80 ms on ↑/↓) replaces it directly, so
/// stepping through commits shows no spinner and no rows that appear late (Committer, Refs) and push the layout
/// down. A slower load shows the new commit with its loading state once the delay is over.
struct LaggingCommitDetail<Content: View>: View {
    let model: CommitDetailModel
    @ViewBuilder let content: (CommitDetailModel) -> Content

    @State private var shown: CommitDetailModel?
    @State private var latest: CommitDetailModel?
    @State private var waiting: Task<Void, Never>?

    var body: some View {
        let current = shown ?? model
        content(current)
            // The commit kept for a moment is not the selected one: its files and parents do not take clicks.
            .allowsHitTesting(current.fullSHA == model.fullSHA)
            .onChange(of: model, initial: true) { _, new in show(new) }
            .onDisappear { waiting?.cancel() }
    }

    private func show(_ new: CommitDetailModel) {
        latest = new
        waiting?.cancel()
        waiting = nil
        guard let current = shown, Self.keepsShowing(current, whileLoading: new) else {
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
