import Foundation

/// What a git older than `lazyFetchControlVersion` cannot do in Overgrove (#317, #361, #383): fetch a partial clone, or
/// fetch a remote on this Mac. Shown where the git is chosen (S-08) and checked (S-07).
enum OlderGitNote {
    static func applies(to version: GitVersion) -> Bool {
        version < GitEnvironment.lazyFetchControlVersion
    }

    static var text: String {
        String(
            localized:
                "With this git, Overgrove does not fetch partial clones or remotes on this Mac (local paths and file:// URLs). Fetching them needs git \(GitEnvironment.lazyFetchControlVersion.description) or later."
        )
    }
}
