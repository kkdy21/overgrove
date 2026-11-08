import SwiftUI

/// Graph zoom (`⌘+` / `⌘−` / `⌘0`, #121, interaction.md §6.3): scales the graph panel's rows, lanes, nodes, and row
/// text together. The sidebar and the detail panel keep their size. Each step has a fixed row height, so the list
/// stays virtualized. One app-wide value (`AppSettings.graphZoomStep`).
struct GraphZoom: Equatable, Sendable {
    /// 85, 100, 115, 130, and 150 %.
    static let scales: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5]
    /// The row height of each step, in whole points (`size.row-graph` at 100 %).
    static let rowHeights: [CGFloat] = [26, 30, 34, 39, 45]
    static let actualSizeStep = 1
    static let actualSize = GraphZoom(step: actualSizeStep)

    let step: Int

    /// Any stored value outside the steps falls back to the nearest one.
    init(step: Int) {
        self.step = min(max(step, 0), Self.scales.count - 1)
    }

    var scale: CGFloat { Self.scales[step] }
    var percent: Int { Int((scale * 100).rounded()) }
    var isActualSize: Bool { step == Self.actualSizeStep }
    var canZoomIn: Bool { step < Self.scales.count - 1 }
    var canZoomOut: Bool { step > 0 }
    var zoomedIn: GraphZoom { GraphZoom(step: step + 1) }
    var zoomedOut: GraphZoom { GraphZoom(step: step - 1) }

    var geometry: GraphGeometry { GraphGeometry(scale: scale, rowHeight: Self.rowHeights[step]) }
    var typography: GraphTypography { GraphTypography(scale: scale) }
}

/// The graph rows' text at a zoom step. At 100 % these are the design tokens' text styles. Otherwise they are the
/// same styles' macOS sizes (body 13, callout 12, subheadline 11, caption 10 pt) times the scale: macOS has no
/// Dynamic Type to scale a text style, so the graph zoom is the one exception to "no point sizes" (interaction.md
/// §6.3, #121).
struct GraphTypography: Equatable, Sendable {
    let scale: CGFloat

    private var isActualSize: Bool { scale == 1 }

    var body: Font { isActualSize ? Tokens.Font.body : .system(size: 13 * scale) }
    var callout: Font { isActualSize ? Tokens.Font.callout : .system(size: 12 * scale) }
    var caption: Font { isActualSize ? Tokens.Font.caption : .system(size: 10 * scale) }
    var monoSmall: Font {
        isActualSize ? Tokens.Font.monoSmall : .system(size: 11 * scale, design: .monospaced)
    }
    var initials: Font { .system(size: 8.5 * scale, weight: .bold) }

    /// A size the graph rows already give in points (ref pills, badges, symbols), scaled.
    func points(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * scale, weight: weight)
    }
}

private struct GraphZoomKey: EnvironmentKey {
    static let defaultValue = GraphZoom.actualSize
}

extension EnvironmentValues {
    /// The graph panel's zoom; 100 % unless the window sets it.
    var graphZoom: GraphZoom {
        get { self[GraphZoomKey.self] }
        set { self[GraphZoomKey.self] = newValue }
    }
}
