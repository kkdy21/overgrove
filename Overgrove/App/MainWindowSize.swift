import CoreGraphics

/// The size a new main window opens at when the system has none saved for it (art-direction.md §3, #685).
///
/// Without one, the window opened at its minimum width and its content's ideal height (1040×450), shorter than the
/// setup assistant it shows on first run. A window the system restores keeps its saved size; this is only the default.
enum MainWindowSize {
    /// The reference size of art-direction.md §3.
    static let standard = CGSize(width: 1440, height: 900)

    /// `standard`, limited to the screen's visible area (without the menu bar and the Dock) when that is smaller.
    /// SwiftUI still keeps the window at its minimum size (`size.window-min-*`).
    /// - Parameter visibleScreen: The visible area of the screen the window opens on; `nil` if it is not known.
    static func initial(visibleScreen: CGSize?) -> CGSize {
        guard let visibleScreen else { return standard }
        return CGSize(
            width: min(standard.width, visibleScreen.width), height: min(standard.height, visibleScreen.height))
    }
}
