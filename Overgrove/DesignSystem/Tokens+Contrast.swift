import SwiftUI

extension Tokens {
    /// Control outlines (chips, pills drawn as controls) are 1pt, and 1.5pt under Increase Contrast
    /// (interaction.md §6.4). Colors switch on their own through the Asset Catalog's High Contrast variants.
    static func controlOutlineWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1.5 : 1
    }

    /// A chip or control outline as drawn (#304, art-direction.md "Increase Contrast").
    struct ControlOutline: Equatable {
        let color: SwiftUI.Color
        let width: CGFloat
    }

    /// The outline of a chip or control inside a panel.
    ///
    /// - Standard contrast: `normal` at 1pt, or no outline when `normal` is `nil`, so the screen does not change.
    /// - Increase Contrast: `increased` at 1.5pt. That is `border.strong` unless the outline already uses a text
    ///   colour (an issue link, the AI badge), which stays because it is the stronger of the two.
    static func controlOutline(
        _ contrast: ColorSchemeContrast, normal: SwiftUI.Color?, increased: SwiftUI.Color = Tokens.Color.borderStrong
    ) -> ControlOutline? {
        if contrast == .increased { return ControlOutline(color: increased, width: controlOutlineWidth(contrast)) }
        return normal.map { ControlOutline(color: $0, width: controlOutlineWidth(contrast)) }
    }

    /// Lane colour on graph ref marks (pill border, connector to the node): the token opacity normally, the full
    /// lane colour under Increase Contrast (#304).
    static func refMarkOpacity(_ contrast: ColorSchemeContrast, normal: Double) -> Double {
        contrast == .increased ? 1 : normal
    }
}

/// Draws `Tokens.controlOutline` around a chip or control.
private struct ControlOutlineModifier<Outline: InsettableShape>: ViewModifier {
    let shape: Outline
    let normal: Color?
    let increased: Color

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if let outline = Tokens.controlOutline(contrast, normal: normal, increased: increased) {
                shape.strokeBorder(outline.color, lineWidth: outline.width)
            }
        }
    }
}

extension View {
    /// The outline of a chip or control inside a panel: `normal` at 1pt (none when `nil`), and `increased`
    /// (`border.strong` by default) at 1.5pt under Increase Contrast.
    func controlOutline(
        _ shape: some InsettableShape, normal: Color? = Tokens.Color.borderSeparator,
        increased: Color = Tokens.Color.borderStrong
    ) -> some View {
        modifier(ControlOutlineModifier(shape: shape, normal: normal, increased: increased))
    }
}
