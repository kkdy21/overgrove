/// Reads a remote's fetch refspecs (`remote.<name>.fetch`) backwards: which ref on the remote a remote-tracking ref
/// holds (#490). Open on GitHub needs a branch, and only the refspec says whether `origin/pr/123` came from
/// `refs/heads/pr/123` or from `refs/pull/123/head`.
///
/// Compared in UTF-8 bytes. A refspec is `[+]SRC:DST`, both sides exact or both with one `*` (git's glob, which may
/// match `/`); `^SRC` excludes sources. Anything else (no destination, a short source, a one-sided or double glob) maps
/// nothing, so an unusual configuration offers no link rather than a wrong one.
enum FetchRefspec {
    /// The branch name (`refs/heads/` dropped) that `ref` holds, or `nil` when no refspec maps it from a branch, a
    /// negative refspec excludes that branch, or two refspecs map it from different sources.
    static func sourceBranch(of ref: String, refspecs: [String]) -> String? {
        let target = Array(ref.utf8)
        var negatives: [[UInt8]] = []
        var sources: [[UInt8]] = []
        for refspec in refspecs {
            var spec = Array(refspec.utf8)[...]
            if spec.first == UInt8(ascii: "^") {
                negatives.append(Array(spec.dropFirst()))
                continue
            }
            if spec.first == UInt8(ascii: "+") { spec = spec.dropFirst() }
            guard let colon = spec.firstIndex(of: UInt8(ascii: ":")) else { continue }
            let source = Array(spec[..<colon])
            let destination = Array(spec[(colon + 1)...])
            guard !destination.isEmpty, let mapped = map(target, from: destination, to: source) else { continue }
            if !sources.contains(mapped) { sources.append(mapped) }
        }
        let heads = Array("refs/heads/".utf8)
        guard sources.count == 1, let source = sources.first, source.starts(with: heads), source.count > heads.count,
            !negatives.contains(where: { capture(source, in: $0) != nil })
        else { return nil }
        return String(decoding: source.dropFirst(heads.count), as: UTF8.self)
    }

    /// `ref` matched against `pattern`, rewritten with `replacement`; `nil` without a match or for a malformed pair.
    private static func map(_ ref: [UInt8], from pattern: [UInt8], to replacement: [UInt8]) -> [UInt8]? {
        let stars = (pattern.count { $0 == UInt8(ascii: "*") }, replacement.count { $0 == UInt8(ascii: "*") })
        switch stars {
        case (0, 0):
            return ref == pattern ? replacement : nil
        case (1, 1):
            guard let middle = capture(ref, in: pattern), let star = replacement.firstIndex(of: UInt8(ascii: "*"))
            else { return nil }
            return Array(replacement[..<star]) + middle + Array(replacement[(star + 1)...])
        default:
            return nil
        }
    }

    /// What `*` matches when `ref` fits `pattern` (exactly when it has no `*`: an empty capture); `nil` otherwise. A
    /// glob matches at least one byte.
    private static func capture(_ ref: [UInt8], in pattern: [UInt8]) -> [UInt8]? {
        guard let star = pattern.firstIndex(of: UInt8(ascii: "*")) else { return ref == pattern ? [] : nil }
        let head = pattern[..<star]
        let tail = pattern[(star + 1)...]
        guard tail.firstIndex(of: UInt8(ascii: "*")) == nil, ref.count > head.count + tail.count,
            ref.starts(with: head), ref.reversed().starts(with: tail.reversed())
        else { return nil }
        return Array(ref[head.count..<(ref.count - tail.count)])
    }
}
