import AppKit
import SwiftUI

/// `Fetch failed — Details` (interaction.md §4.2): one section per failed remote with its summary, what to do, the
/// commands to copy, and the last lines of masked stderr. Overgrove never runs these commands; copying them is not a
/// repository write (ADR-0011).
struct FetchFailureDetailsView: View {
    let failures: [FetchFailureDetail]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            Text("Fetch failed").font(Tokens.Font.title)
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
                    ForEach(failures) { failure in
                        FetchFailureSection(failure: failure)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(minWidth: Self.width, idealWidth: Self.width, minHeight: Self.minimumHeight)
    }

    /// No size tokens for sheets; a width that keeps a guidance sentence on two or three lines.
    static let width: CGFloat = 480
    static let minimumHeight: CGFloat = 240
}

private struct FetchFailureSection: View {
    let failure: FetchFailureDetail

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Label(failure.summary, systemImage: "exclamationmark.triangle")
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textPrimary)
            Text(failure.guidance)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(failure.commands, id: \.self) { command in
                HStack(spacing: Tokens.Spacing.sm) {
                    Text(command).font(Tokens.Font.mono).textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Command")
                    .accessibilityLabel("Copy command \(command)")
                }
            }
            if let detail = failure.detail {
                Text(detail)
                    .font(Tokens.Font.monoSmall)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Short VoiceOver announcements when a fetch ends (interaction.md §6: `Fetch finished`, `Fetch failed: …`).
enum FetchAnnouncement {
    static func text(from old: FetchStatus, to new: FetchStatus) -> String? {
        guard old.isFetching else { return nil }
        switch new {
        case .idle: return "Fetch finished"
        case .failed: return "Fetch failed"
        case .cancelled: return "Fetch cancelled"
        case .never, .estimated, .fetching: return nil
        }
    }
}
