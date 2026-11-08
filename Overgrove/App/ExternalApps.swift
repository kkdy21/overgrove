import Foundation

/// The terminal and editor Overgrove opens worktrees in (#124, interaction.md §5, security-review.md T14).
///
/// Every external app is opened with `NSWorkspace` and gets one checked folder or file URL: no shell string, no
/// `Process`, no AppleScript, and no argument templates. Only the chosen app's bundle identifier is stored; the app is
/// looked up by it each time (`NSWorkspace.urlForApplication(withBundleIdentifier:)`), never by a stored path.
enum ExternalAppRole: Sendable, Equatable {
    case terminal
    case editor

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .editor: "Editor"
        }
    }
}

/// A chosen app as Settings shows it. The signature is shown only, never required (as ADR-0019 §2 for git).
struct ExternalAppInfo: Sendable, Equatable {
    let bundleIdentifier: String
    let name: String
    let isAppleSigned: Bool
}

/// Why a chosen app was not accepted.
enum ExternalAppRefusal: Error, Equatable {
    case notAnApp
    case noBundleIdentifier
    case noExecutable

    var message: String {
        switch self {
        case .notAnApp: "Choose an application (.app)."
        case .noBundleIdentifier: "The application has no valid bundle identifier."
        case .noExecutable: "The application has no executable."
        }
    }
}

enum ExternalApps {
    /// Open in Terminal uses Terminal.app unless Settings names another terminal.
    static let defaultTerminal = "com.apple.Terminal"

    /// A reverse-DNS bundle identifier: 1–255 ASCII letters, digits, `.`, and `-`, not starting with `.` or `-`.
    /// A stored value is untrusted; anything else reads as no choice.
    static func isValidBundleIdentifier(_ value: String) -> Bool {
        let utf8 = value.utf8
        guard (1...255).contains(utf8.count), let first = utf8.first, first != UInt8(ascii: "."),
            first != UInt8(ascii: "-")
        else { return false }
        return utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
        }
    }

    /// Checks an app picked in Settings: a folder named `*.app` that is a bundle with a valid identifier and an
    /// executable file.
    static func inspect(
        _ url: URL, isAppleSigned: (URL) -> Bool = GitExecutablePolicy.isAppleSigned
    ) -> Result<ExternalAppInfo, ExternalAppRefusal> {
        var isDirectory: ObjCBool = false
        guard url.pathExtension.lowercased() == "app",
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
            let bundle = Bundle(url: url)
        else { return .failure(.notAnApp) }
        guard let identifier = bundle.bundleIdentifier, isValidBundleIdentifier(identifier) else {
            return .failure(.noBundleIdentifier)
        }
        guard let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            return .failure(.noExecutable)
        }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return .success(
            ExternalAppInfo(
                bundleIdentifier: identifier, name: PathValidator.displayable(name), isAppleSigned: isAppleSigned(url)))
    }
}
