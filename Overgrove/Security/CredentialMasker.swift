import Foundation

/// Removes credentials from text before it is shown, logged, or put into an error summary
/// (docs/design/security-review.md T11, T16).
///
/// Every remote URL and every stderr excerpt must pass through `mask(_:)` first. URL userinfo is masked regardless
/// of its format, so new token formats embedded in URLs are still covered.
///
/// Input can be remote-controlled (up to 256 KiB of fetch stderr), so every rule must run in linear time (#143).
/// URL userinfo is handled by a hand-written scanner; the remaining regexes have no nested or overlapping
/// quantifiers.
enum CredentialMasker {
    static let placeholder = "***"

    /// Returns `text` with credentials replaced by `***`. Applying it twice gives the same result.
    static func mask(_ text: String) -> String {
        var result = maskURLUserinfo(text)
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

    /// `scheme://user:password@host` and `scheme://token@host` → `scheme://***@host`, in one pass over the bytes.
    ///
    /// After `://`, the userinfo segment runs to the first `/`, whitespace, quote, `<`, or `>`; everything up to the
    /// last `@` in that segment is replaced. A segment ends at `/`, so a nested `x://y://u@h` is resumed at the
    /// inner `:`; each byte is visited at most twice.
    static func maskURLUserinfo(_ text: String) -> String {
        let bytes = Array(text.utf8)
        let count = bytes.count
        guard count >= 4 else { return text }
        var output: [UInt8] = []
        output.reserveCapacity(count)
        var index = 0
        while index < count {
            let isSeparator =
                index + 2 < count && bytes[index] == 0x3A && bytes[index + 1] == 0x2F && bytes[index + 2] == 0x2F
            guard isSeparator, index > 0, isSchemeByte(bytes[index - 1]) else {
                output.append(bytes[index])
                index += 1
                continue
            }
            let start = index + 3
            var end = start
            var lastAt = -1
            while end < count, !isSegmentTerminator(bytes[end]) {
                if bytes[end] == 0x40 { lastAt = end }
                end += 1
            }
            output.append(contentsOf: bytes[index..<start])
            if lastAt > start {
                output.append(contentsOf: Array(placeholder.utf8))
                output.append(contentsOf: bytes[lastAt..<end])
                index = end
            } else if end > start, bytes[end - 1] == 0x3A, end + 1 < count, bytes[end] == 0x2F, bytes[end + 1] == 0x2F {
                // The segment ends with the ":" of another "://": emit up to it and resume there.
                output.append(contentsOf: bytes[start..<(end - 1)])
                index = end - 1
            } else {
                output.append(contentsOf: bytes[start..<end])
                index = end
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func isSchemeByte(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
            || byte == 0x2B || byte == 0x2E || byte == 0x2D
    }

    /// `/`, whitespace, `'`, `"`, `<`, `>`
    private static func isSegmentTerminator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x2F, 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x27, 0x22, 0x3C, 0x3E: true
        default: false
        }
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
