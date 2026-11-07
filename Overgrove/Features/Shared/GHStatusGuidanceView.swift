import AppKit
import SwiftUI

/// GitHub CLI's state with what to do (`GHStatusGuidance`), shared by the setup assistant (S-07) and the issues
/// panel (#83): the state line, the advice, a command to copy, and Check Again. Copying is not a repository write and
/// Overgrove never runs the command (ADR-0011, ADR-0004 §4).
struct GHStatusGuidanceView: View {
    let guidance: GHStatusGuidance
    /// `nil` hides Check Again.
    var onCheckAgain: (() -> Void)?
    var showsTokenNote = true

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Label(guidance.title, systemImage: guidance.isOK ? "checkmark.circle" : "person.crop.circle.badge.xmark")
                .foregroundStyle(guidance.isOK ? Tokens.Color.statusOk : Tokens.Color.statusWarning)
                .font(Tokens.Font.callout.weight(.medium))
            if let message = guidance.message {
                Text(message)
                    .font(Tokens.Font.callout)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = guidance.command {
                CopyableCommand(command: command)
            }
            if onCheckAgain != nil || showsTokenNote {
                HStack(spacing: Tokens.Spacing.md) {
                    if let onCheckAgain {
                        Button(action: onCheckAgain) { Label("Check Again", systemImage: "arrow.clockwise") }
                    }
                    if showsTokenNote {
                        Label(GHStatusGuidance.tokenNote, systemImage: "lock")
                            .font(Tokens.Font.caption)
                            .foregroundStyle(Tokens.Color.textTertiary)
                    }
                }
            }
        }
    }
}

/// `$ gh auth login  [Copy]`: a command the user runs in Terminal.
struct CopyableCommand: View {
    let command: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Text("$ " + command)
                .font(Tokens.Font.mono)
                .textSelection(.enabled)
                .padding(.horizontal, Tokens.Spacing.sm)
                .padding(.vertical, Tokens.Spacing.xs)
                .frame(minWidth: Self.minimumWidth, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Tokens.Color.borderStrong))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .accessibilityLabel("Copy command \(command)")
        }
    }

    /// No token: wide enough for `xcode-select --install` without the box resizing between states.
    static let minimumWidth: CGFloat = 240
}
