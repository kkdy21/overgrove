import Foundation

/// Removes credentials from text before it is shown, logged, or put into an error summary
/// (docs/design/security-review.md T11, T16).
///
/// Every remote URL and every stderr excerpt must pass through `mask(_:)` first. URL userinfo is masked regardless
/// of its format, so new token formats embedded in URLs are still covered.
enum CredentialMasker {
    static let placeholder = "***"

    /// Returns `text` with credentials replaced by `***`. Applying it twice gives the same result.
    static func mask(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }

    /// Decodes bytes lossily (stderr may not be valid UTF-8) and masks them.
    static func mask(_ data: Data) -> String {
        mask(String(decoding: data, as: UTF8.self))
    }

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    // Built per call: NSRegularExpression is cheap to create and this keeps the type free of shared mutable state.
    private static var rules: [Rule] {
        [
            // scheme://user:password@host, scheme://token@host → scheme://***@host
            rule(#"([A-Za-z][A-Za-z0-9+.\-]*://)[^/\s'"<>]+@"#, "$1***@"),
            // ?access_token=…&token=… and similar query parameters
            rule(
                #"([?&;](?:access_token|token|private_token|oauth_token|refresh_token|password|passwd|secret|key)=)[^&#\s'"]+"#,
                "$1***",
                options: [.caseInsensitive]
            ),
            // GitHub tokens: ghp_ gho_ ghu_ ghs_ ghr_ and fine-grained github_pat_
            rule(#"\bgh[pousr]_[A-Za-z0-9]{16,}"#, "***"),
            rule(#"\bgithub_pat_[A-Za-z0-9_]{16,}"#, "***"),
            // Authorization / Proxy-Authorization headers anywhere in a line (curl and GIT_TRACE output prefix them)
            rule(#"(\b(?:proxy-)?authorization[ \t]*:[ \t]*)[^\r\n]*"#, "$1***", options: [.caseInsensitive]),
        ]
    }

    private static func rule(
        _ pattern: String,
        _ template: String,
        options: NSRegularExpression.Options = []
    ) -> Rule {
        // The patterns are constants covered by tests; a failure here is a programming error.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("invalid masking pattern: \(pattern)")
        }
        return Rule(regex: regex, template: template)
    }
}
