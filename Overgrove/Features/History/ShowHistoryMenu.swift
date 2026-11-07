import SwiftUI

extension View {
    /// A file row's context menu with `Show History` (S-09, #70), disabled for a path that is not valid UTF-8 (git's
    /// pathspec cannot name it losslessly). Without an action the row has no menu.
    func showHistoryMenu(_ path: GitPath, action: ((GitPath) -> Void)?) -> some View {
        modifier(ShowHistoryMenu(path: path, action: action))
    }
}

private struct ShowHistoryMenu: ViewModifier {
    let path: GitPath
    let action: ((GitPath) -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.contextMenu {
                Button("Show History") { action(path) }
                    .disabled(!path.isRepresentable)
            }
        } else {
            content
        }
    }
}
