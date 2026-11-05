import SwiftUI

/// Temporary root view shown until the main window (S-01, docs/design/screens.md) is implemented.
struct PlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Overgrove")
                .font(.largeTitle)
            Text("Under construction. See the roadmap at github.com/kkdy21/overgrove.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 240)
    }
}

#Preview {
    PlaceholderView()
}
