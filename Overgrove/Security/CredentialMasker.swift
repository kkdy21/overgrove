import Foundation

/// Removes credentials from text before it is shown, logged, or put into an error summary
/// (docs/design/security-review.md T11, T16).
///
/// Every remote URL and every stderr excerpt must pass through `mask(_:)` first. URL userinfo is masked regardless
/// of its format, so new token formats embedded in URLs are still covered. Without a scheme (`user:token@host:repo`,
/// #244) the password after the first `:` is masked, so scp-like `git@host:repo` stays readable and the host stays
/// true; config keys go through `maskConfigKey(_:)`, which masks any userinfo in a URL subsection.
///
/// Input can be remote-controlled (up to 256 KiB of fetch stderr), so every rule must run in linear time (#143).
/// URL userinfo is handled by a hand-written scanner; the remaining regexes have no nested or overlapping
/// quantifiers.
enum CredentialMasker {
    static let placeholder = "***"

    /// Returns `text` with credentials replaced by `***`. Applying it again never reveals anything; on crafted input
    /// it can hide a little more, when a replaced separator lets another pattern match (#375 review).
    static func mask(_ text: String) -> String {
        var result = maskSchemelessUserinfo(maskURLUserinfo(text))
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

    /// `user:token@host:repo` → `user:***@host:repo` without a scheme (#244), in one pass over the bytes.
    ///
    /// A segment is a run of bytes up to `/`, whitespace, a quote, `<`, or `>`. When an `@` follows the segment's
    /// first `:`, the bytes between that `:` and the last `@` are replaced. Only the password goes: what precedes the
    /// `:` stays, because git reads `a:b@c:d` as scp-style SSH to host `a`, and hiding it would make the remote look
    /// like it points at `c` (security review of #244, #86). An unescaped `@` in the password, or a decoy `@` before
    /// the `:`, leaks nothing. `git@host:repo`, `alice@example.com`, and `bob@host's password:` have no `@` after a
    /// `:` and stay as they are.
    ///
    /// False positives are text shaped like `word:word@word` with no space (`mailto:a@b`, `git@host:repo@v1`); they
    /// only hide a little text. `***` holds neither `:` nor `@`, so masking twice changes nothing.
    static func maskSchemelessUserinfo(_ text: String) -> String {
        let bytes = Array(text.utf8)
        guard bytes.contains(0x40) else { return text }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var start = 0
        while start < bytes.count {
            if isSegmentTerminator(bytes[start]) {
                output.append(bytes[start])
                start += 1
                continue
            }
            var end = start
            var colon = -1
            var lastAt = -1
            while end < bytes.count, !isSegmentTerminator(bytes[end]) {
                switch bytes[end] {
                case 0x3A where colon < 0: colon = end
                case 0x40 where colon >= 0: lastAt = end
                default: break
                }
                end += 1
            }
            if lastAt > colon + 1 {
                output.append(contentsOf: bytes[start...colon])
                output.append(contentsOf: Array(placeholder.utf8))
                output.append(contentsOf: bytes[lastAt..<end])
            } else {
                output.append(contentsOf: bytes[start..<end])
            }
            start = end
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Sections whose subsection is a URL or a URL pattern (`credential.<url>.helper`, `url.<base>.insteadOf`,
    /// `http.<url>.sslVerify`).
    private static let urlSubsectionSections: Set<String> = ["credential", "url", "http"]

    /// A config key as S-05 and Open in Terminal list it (`section.subsection.variable`), with the subsection's
    /// userinfo masked whatever its form (#244): `credential.token@host.helper` → `credential.***@host.helper`.
    ///
    /// For `credential`, `url`, and `http`, a subsection that does not start with a scheme is masked up to the last
    /// `@` before its first `/`, as `maskURLUserinfo` treats what follows `://`. A user name goes too
    /// (`url.***@github.com:.insteadof`), as in a URL; the key is shown, never connected to. One that starts with a
    /// scheme is left to `maskURLUserinfo`. The section and variable cannot contain dots, so the subsection is what
    /// lies between the first and last dot. The result always goes through `mask(_:)`.
    static func maskConfigKey(_ key: String) -> String {
        guard let first = key.firstIndex(of: "."), let last = key.lastIndex(of: "."), first < last,
            urlSubsectionSections.contains(key[..<first].lowercased())
        else { return mask(key) }
        let subsection = key[key.index(after: first)..<last]
        guard !startsWithScheme(subsection) else { return mask(key) }
        let host = subsection.firstIndex(of: "/") ?? subsection.endIndex
        guard let at = subsection[..<host].lastIndex(of: "@") else { return mask(key) }
        return mask(String(key[...first]) + placeholder + String(key[at...]))
    }

    /// `^[A-Za-z][A-Za-z0-9+.-]*://`
    private static func startsWithScheme(_ text: Substring) -> Bool {
        let bytes = text.utf8
        guard let first = bytes.first, (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first) else {
            return false
        }
        guard let separator = text.range(of: "://") else { return false }
        return text[..<separator.lowerBound].utf8.allSatisfy(isSchemeByte)
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
