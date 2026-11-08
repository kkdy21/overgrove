import SwiftUI

/// S-07, the setup assistant (screens.md S-07): add a repository, check git, check GitHub CLI (optional).
/// `Open Repository` is enabled once a repository is open and git is ready. Install and login commands are only
/// copied, never run.
struct SetupAssistantView: View {
    let setup: SetupAssistantState
    /// The open repository's path (`~/dev/api`), escaped; `nil` before one is added.
    let repositoryPath: String?
    let isAddingRepository: Bool
    let onChooseFolder: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.lg) {
            header
            VStack(spacing: Tokens.Spacing.md) {
                SetupStepCard(number: 1, title: "Add a repository", isDone: repositoryPath != nil) {
                    repositoryStep
                } accessory: {
                    Button("Choose Folder…", action: onChooseFolder).disabled(isAddingRepository)
                }
                SetupStepCard(number: 2, title: "git", isDone: setup.git?.isReady ?? false) {
                    gitStep
                } accessory: {
                    EmptyView()
                }
                SetupStepCard(
                    number: 3, title: "GitHub", subtitle: "optional — used only to show issues", isDone: gitHubDone
                ) {
                    gitHubStep
                } accessory: {
                    EmptyView()
                }
            }
            HStack {
                Text("Reopen anytime from Help › Setup Assistant.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                Spacer()
                Button("Open Repository", action: setup.dismiss)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!setup.canFinish(hasRepository: repositoryPath != nil))
                // The assistant can be left at any time; nothing in it is required to keep using the app.
                Button("Close", action: setup.dismiss).keyboardShortcut(.cancelAction)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: Self.width)
    }

    private var header: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            // design/icon/mark.svg as the Mark asset (iconography.md §6.1, #38).
            Image("Mark")
                .resizable()
                .scaledToFit()
                .frame(height: Self.markHeight)
                .accessibilityHidden(true)
            Text("Welcome to Overgrove").font(Tokens.Font.largeTitle)
            Text("See every worktree of a repository at a glance.")
                .foregroundStyle(Tokens.Color.textSecondary)
            Label("Read-only", systemImage: "checkmark.shield")
                .font(Tokens.Font.pill)
                .foregroundStyle(Tokens.Color.statusOk)
            Text("The only network action is git fetch. Nothing in your repositories is ever changed.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.textSecondary)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var repositoryStep: some View {
        if let repositoryPath {
            Label(repositoryPath, systemImage: "checkmark.circle")
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.Color.textPrimary)
        }
        Text("Only folders you choose here are ever read.")
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Color.textTertiary)
    }

    @ViewBuilder
    private var gitStep: some View {
        switch setup.git {
        case nil:
            ProgressView().controlSize(.small)
        case .ready(let version, let path):
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Label(Self.gitReady(version, path), systemImage: "checkmark.circle")
                    .font(Tokens.Font.callout)
                    .foregroundStyle(Tokens.Color.textPrimary)
                // A supported but older git works, with fewer fetches (#383).
                if OlderGitNote.applies(to: version) {
                    Label(OlderGitNote.text, systemImage: "info.circle")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .missing:
            SetupProblem(
                title: String(localized: "git was not found"),
                message: String(localized: "Install the Xcode Command Line Tools, then check again:"),
                command: "xcode-select --install", onCheckAgain: setup.checkGit)
        case .unsupported(let found):
            SetupProblem(
                title: String(
                    localized:
                        "git \(GitVersion.minimumSupported.description) or later is required (found \(found.description))"
                ),
                message: String(localized: "Update the Xcode Command Line Tools, then check again."), command: nil,
                onCheckAgain: setup.checkGit)
        case .failed(let message):
            SetupProblem(
                title: String(localized: "git could not be checked"), message: message, command: nil,
                onCheckAgain: setup.checkGit)
        case .chosenRejected(let path, let reason):
            // ADR-0019 §4: the chosen git is not replaced behind the user's back; they pick the default here.
            SetupProblem(
                title: String(localized: "The git chosen in Settings cannot be used"), message: "\(path): \(reason)",
                command: nil,
                onCheckAgain: setup.checkGit,
                onUseDefault: setup.canUseDefaultGit ? { setup.useDefaultGit() } : nil)
        }
    }

    @ViewBuilder
    private var gitHubStep: some View {
        switch setup.gitHub {
        case .checking:
            ProgressView().controlSize(.small)
        case .done(let guidance):
            GHStatusGuidanceView(guidance: guidance, onCheckAgain: checkGitHubAgain(guidance))
        }
    }

    /// `git 2.50.1 at /usr/bin/git`. The version and path go in as text, not as localized numbers.
    static func gitReady(_ version: GitVersion, _ path: String) -> String {
        String(localized: "git \(version.description) at \(path)")
    }

    /// Check Again only while GitHub CLI is not ready.
    private func checkGitHubAgain(_ guidance: GHStatusGuidance) -> (() -> Void)? {
        guard !guidance.isOK else { return nil }
        let setup = setup
        return { setup.checkGitHub() }
    }

    private var gitHubDone: Bool {
        if case .done(let guidance) = setup.gitHub { return guidance.isOK }
        return false
    }

    /// No size tokens for the assistant panel; values from the S-07 mockup.
    static let width: CGFloat = 640
    static let markHeight: CGFloat = 64
}

/// One numbered card: a check mark when done, otherwise the step number.
private struct SetupStepCard<Content: View, Accessory: View>: View {
    let number: Int
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let isDone: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.md) {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Tokens.Color.statusOk)
                } else {
                    Image(systemName: "\(number).circle").foregroundStyle(Tokens.Color.statusWarning)
                }
            }
            .font(Tokens.Font.title)
            .accessibilityLabel(isDone ? Text("Step \(number), done") : Text("Step \(number)"))
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(Tokens.Font.headline)
                    if let subtitle {
                        Text(subtitle).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
                    }
                    Spacer()
                    accessory
                }
                content
            }
        }
        .padding(Tokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(Tokens.Color.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(Tokens.Color.borderSeparator))
    }

    /// Same radius as the detail cards (art-direction.md §7).
    static var cornerRadius: CGFloat { 8 }
}

/// A failed git check: what is wrong, what to do, a command to copy, Check Again.
private struct SetupProblem: View {
    let title: String
    let message: String
    let command: String?
    let onCheckAgain: () -> Void
    var onUseDefault: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(Tokens.Font.callout.weight(.medium))
                .foregroundStyle(Tokens.Color.statusWarning)
            Text(message)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command { CopyableCommand(command: command) }
            HStack {
                Button(action: onCheckAgain) { Label("Check Again", systemImage: "arrow.clockwise") }
                if let onUseDefault { Button("Use Default", action: onUseDefault) }
            }
        }
    }
}
