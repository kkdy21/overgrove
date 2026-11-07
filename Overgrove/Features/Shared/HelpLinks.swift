import Foundation

/// Fixed links to Overgrove's own documentation on github.com. App-written constants: nothing from a repository or a
/// server goes into them.
enum HelpLinks {
    /// Self-hosted and corporate Git servers: tokens, SSH, private CAs, proxies, and fetch failures (#152).
    static let selfHostedGit = URL(
        string: "https://github.com/kkdy21/overgrove/blob/main/docs/guides/self-hosted-git.md")
}
