import SwiftUI

extension Tokens {
    /// Control outlines (chips, pills drawn as controls) are 1pt, and 1.5pt under Increase Contrast
    /// (interaction.md §6.4). Colors switch on their own through the Asset Catalog's High Contrast variants.
    static func controlOutlineWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
        contrast == .increased ? 1.5 : 1
    }
}
