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

    /// Onboarding step transitions: `motion.duration-slow` with `motion.easing-standard`.
    static var slow: Animation {
        let curve = Tokens.Motion.easingStandardControlPoints
        return .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: Tokens.Motion.durationSlow)
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
enum HoverShape: Equatable, Sendable {
    /// Edge to edge, like graph rows.
    case fullWidth
    /// Rounded like the sidebar selection (`radius.card`); the caller's outer padding insets it.
    case inset
    /// Rounded like a row's own selection background, e.g. `radius.md` for detail file rows.
    case rounded(radius: CGFloat)
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
        case .rounded(let radius): RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color)
        }
    }
}

private struct HoverHighlight: ViewModifier {
    let shape: HoverShape
    let isEnabled: Bool
    let horizontalInset: CGFloat
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background {
                HoverFill(shape: shape, isHovering: isHovering && isEnabled)
                    .motion(.fast, value: isHovering)
                    .padding(.horizontal, horizontalInset)
            }
            .onHover { isHovering = $0 }
    }
}

extension View {
    /// Fills the row with `surface.hover` under the pointer, fading in `motion.duration-fast` (at once under Reduce
    /// Motion). Pass `isEnabled: false` for a selected row, whose selection background wins, or a row that does
    /// nothing when clicked. `horizontalInset` matches a selection background drawn inside the row's padding.
    func hoverHighlight(
        _ shape: HoverShape = .fullWidth, isEnabled: Bool = true, horizontalInset: CGFloat = 0
    ) -> some View {
        modifier(HoverHighlight(shape: shape, isEnabled: isEnabled, horizontalInset: horizontalInset))
    }
}

// MARK: - Content swaps

/// What kind of content a panel shows, as a coarse `fadeIn(on:)` key: new text or rows within the same phase
/// update in place, and only a change of phase fades.
enum LoadPhase: Hashable, Sendable {
    case loading
    case empty
    case failed
    case loaded
}

private struct FadeIn<Key: Hashable>: ViewModifier {
    let key: Key
    /// The first content shows at once: only a change of `key` fades.
    @State private var hasAppeared = false

    func body(content: Content) -> some View {
        // The old content leaves at once (a new identity, no transition) and only the new one fades in, so the two
        // never overlap: a view on its way out keeps no focus request handler, keyboard shortcut, or heavy rows
        // alive during the fade (#576).
        content
            .modifier(FadeInOnAppear(fades: hasAppeared))
            .id(key)
            .onAppear { hasAppeared = true }
    }
}

/// Starts at 0 and fades to 1 on the run loop turn after it appears (#637). A heavy screen (S-11, S-12) takes its
/// first layout in the frame it is inserted; a fade started in that frame has run its course by the time the next
/// frame draws, so the screen popped in at full opacity after a blank frame or two. Starting after that layout
/// keeps every frame of the fade.
private struct FadeInOnAppear: ViewModifier {
    /// Taken once, when this content is created: the container's first content never fades, even after the
    /// container has appeared.
    @State private var startsHidden: Bool
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fades: Bool) {
        _startsHidden = State(initialValue: fades)
    }

    func body(content: Content) -> some View {
        content
            .opacity(startsHidden && !isShown ? 0 : 1)
            .onAppear {
                guard startsHidden, !isShown else { return }
                if reduceMotion {
                    isShown = true
                    return
                }
                DispatchQueue.main.async {
                    withAnimation(.standard) { isShown = true }
                }
            }
    }
}

extension View {
    /// Fades new content in when `key` changes (a screen opening over the graph, loading → loaded), in
    /// `motion.duration-standard`; at once under Reduce Motion (interaction.md §6.5). Keep `key` coarse: content that
    /// changes under the same key updates in place.
    func fadeIn<Key: Hashable>(on key: Key) -> some View {
        modifier(FadeIn(key: key))
    }
}

// MARK: - Loading indicators

/// interaction.md §4: a loading indicator shows only once a result has not arrived for 150 ms, so a short load
/// does not flash one. No token: the value comes from the document.
let loadingIndicatorDelay: Duration = .milliseconds(150)

/// A small spinner that appears only after `loadingIndicatorDelay` (#637). Until then it takes its place, empty, so
/// nothing moves when it appears.
struct DelayedProgressView: View {
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(isVisible ? 1 : 0)
            .task {
                try? await Task.sleep(for: loadingIndicatorDelay)
                guard !Task.isCancelled else { return }
                isVisible = true
            }
            .accessibilityHidden(!isVisible)
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
/// `surface.selection-inactive` with a `border.strong` outline otherwise, with `radius.card`.
struct SidebarSelectionBackground: View {
    let isFocused: Bool
    /// `false` for a row that marks its selection another way (a worktree row's lane border), so the outline does not
    /// sit under that mark.
    var outlinesWhenInactive = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
        shape
            .fill(isFocused ? Tokens.Color.surfaceSelection : Tokens.Color.surfaceSelectionInactive)
            // Inactive, the fill is nearly `surface.hover`; a `border.strong` outline tells the two apart, as on file
            // rows (#605).
            .overlay { if !isFocused && outlinesWhenInactive { shape.strokeBorder(Tokens.Color.borderStrong) } }
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
