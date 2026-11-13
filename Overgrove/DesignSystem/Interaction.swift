import SwiftUI

// Shared pointer feedback and motion (#571): hover fills, a hover button style, Reduce Motion-aware animations, the
// sidebar selection background, and the panel footer. Screens use these instead of their own colours and timings.

// MARK: - Motion

extension Animation {
    /// Panel content swaps and disclosures: `motion.duration-standard` with `motion.easing-standard`.
    static var standard: Animation {
        let curve = Tokens.Motion.easingStandardControlPoints
        return .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: Tokens.Motion.durationStandard)
    }

    /// Hover and selection highlights: `motion.duration-fast` (art-direction.md §9 "포인터 반응은 120ms").
    static var fast: Animation { .easeOut(duration: Tokens.Motion.durationFast) }

    /// `animation`, or `nil` (change at once) when Reduce Motion is on (interaction.md §6.5).
    static func respectingReduceMotion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

/// Runs `body` with `animation`, or without any animation when Reduce Motion is on.
@MainActor
func withMotion<Result>(_ animation: Animation, reduceMotion: Bool, _ body: () throws -> Result) rethrows -> Result {
    if let animation = Animation.respectingReduceMotion(animation, reduceMotion: reduceMotion) {
        return try withAnimation(animation, body)
    }
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    return try withTransaction(transaction, body)
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(.respectingReduceMotion(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Animates changes of `value` with `animation`, or not at all under Reduce Motion. Put it on the layer that
    /// changes (a fill, a grip), not on a whole row or divider: everything else that changes in the same transaction
    /// would follow it, such as row content or a divider dragged under the pointer.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

private struct PressedOpacity: ViewModifier {
    let isPressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Scoped to the opacity alone, so nothing else in the button animates with the press.
        content.animation(.respectingReduceMotion(.fast, reduceMotion: reduceMotion)) {
            $0.opacity(isPressed ? Tokens.Opacity.pressed : 1)
        }
    }
}

extension View {
    /// `opacity.pressed` while a button is held down, fading in `motion.duration-fast`.
    func pressedOpacity(_ isPressed: Bool) -> some View {
        modifier(PressedOpacity(isPressed: isPressed))
    }
}

// MARK: - Hover

/// Where a hover fill sits.
enum HoverShape: Sendable {
    /// Edge to edge, like graph rows.
    case fullWidth
    /// Rounded like the sidebar selection (`radius.card`); the caller's outer padding insets it.
    case inset
}

/// The `surface.hover` fill under the pointer (art-direction.md §5.2). Clear when not hovered.
struct HoverFill: View {
    let shape: HoverShape
    let isHovering: Bool

    var body: some View {
        let color = isHovering ? Tokens.Color.surfaceHover : Color.clear
        switch shape {
        case .fullWidth: Rectangle().fill(color)
        case .inset: RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous).fill(color)
        }
    }
}

private struct HoverHighlight: ViewModifier {
    let shape: HoverShape
    let isEnabled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                HoverFill(shape: shape, isHovering: isHovering && isEnabled).motion(.fast, value: isHovering)
            }
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Fills the row with `surface.hover` under the pointer, fading in `motion.duration-fast` (at once under Reduce
    /// Motion). Pass `isEnabled: false` for a selected row, whose selection background wins.
    func hoverHighlight(_ shape: HoverShape = .fullWidth, isEnabled: Bool = true) -> some View {
        modifier(HoverHighlight(shape: shape, isEnabled: isEnabled))
    }
}

// MARK: - Buttons

/// Icon and text buttons in panels (`‹ Graph`, `⇄`, copy): a rounded `surface.hover` fill under the pointer and
/// `opacity.pressed` while held down. Replaces `.borderless` and `.plain`, which give no hover feedback.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration)
    }
}

private struct HoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .pressedOpacity(configuration.isPressed)
            .padding(.horizontal, Tokens.Spacing.xs)
            .padding(.vertical, Tokens.Spacing.xxs)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
                    .fill(isHovering && isEnabled ? Tokens.Color.surfaceHover : Color.clear)
                    .motion(.fast, value: isHovering)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

extension ButtonStyle where Self == HoverButtonStyle {
    static var hover: HoverButtonStyle { HoverButtonStyle() }
}

// MARK: - Sidebar selection

/// The selected sidebar row's background (interaction.md §1.2): `surface.selection` while the list has focus,
/// `surface.selection-inactive` otherwise, with `radius.card`.
struct SidebarSelectionBackground: View {
    let isFocused: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            .fill(isFocused ? Tokens.Color.surfaceSelection : Tokens.Color.surfaceSelectionInactive)
    }
}

// MARK: - Panel footer

/// A bar pinned to the bottom of a panel, the counterpart of `PanelHeader`: `surface.panel-header`, a separator on
/// top, and `spacing.md` on both sides.
struct PanelFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            content
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, Tokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surfacePanelHeader)
        .overlay(alignment: .top) {
            Tokens.Color.borderSeparator.frame(height: 1)
        }
    }
}
