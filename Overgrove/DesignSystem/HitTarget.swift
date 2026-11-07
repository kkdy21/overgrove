import SwiftUI

extension View {
    /// Pads an inline icon button's label to `size.hit-target-min` (20pt) in both directions and makes the whole
    /// square clickable (interaction.md §6.5).
    func hitTarget() -> some View {
        frame(minWidth: Tokens.Size.hitTargetMin, minHeight: Tokens.Size.hitTargetMin).contentShape(Rectangle())
    }
}
