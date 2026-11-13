import AppKit
import SwiftUI

/// An AppKit tooltip (`NSView.toolTip`) under a view, instead of SwiftUI's `.help` (#658).
///
/// In the real app, `.help` on SwiftUI-styled buttons and fields (the copy buttons, the narrow detail view switch,
/// the clickable status bar fields, sidebar branch folders) stayed up long after the pointer left, or stopped
/// appearing after a drag or a menu. Moving their hover tracking outside the `Button` (#662) changed nothing.
/// Toolbar buttons, which are AppKit buttons with their own `toolTip`, always behaved. These views now take their
/// tooltip from an `NSView` of their own in the same way. Its tooltip area is registered once and follows the view's
/// bounds; it changes only when the text does, not when the content redraws on hover.
///
/// AppKit shows a view's tooltip from the pointer resting in that area, so the view need not be the one under the
/// pointer. It sits behind the content and never takes a hit: clicks, drags, scrolls, the context menu, SwiftUI's
/// hover, and the pointer cursor all stay with the content in front.
extension View {
    /// `accessibilityHint` defaults to the tooltip text, as `.help` gave VoiceOver.
    func toolTip(_ text: String, accessibilityHint: String? = nil) -> some View {
        background(ToolTipArea(text: text))
            .accessibilityHint(Text(accessibilityHint ?? text))
    }
}

struct ToolTipArea: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ToolTipView {
        let view = ToolTipView()
        view.toolTip = shown
        return view
    }

    func updateNSView(_ view: ToolTipView, context: Context) {
        if view.toolTip != shown { view.toolTip = shown }
    }

    /// An empty text shows no tooltip.
    var shown: String? { text.isEmpty ? nil : text }

    final class ToolTipView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func isAccessibilityElement() -> Bool { false }
    }
}
