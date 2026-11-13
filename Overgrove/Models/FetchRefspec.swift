/// One fetch refspec (`remote.<name>.fetch`), read backwards: which ref on the remote a remote-tracking ref holds
/// (#490). Open on GitHub needs a branch, and only the refspec says whether `origin/pr/123` came from
/// `refs/heads/pr/123` or from `refs/pull/123/head`.
///
/// Parsed once per remote and compared in UTF-8 bytes. A refspec is `[+]SRC:DST`, both sides exact or both with one
/// `*` (git's glob, which may match `/`); `^SRC` excludes sources. Anything else (no destination, a short source, a
/// one-sided or double glob) maps nothing, so an unusual configuration offers no link rather than a wrong one.
struct FetchRefspec: Sendable, Equatable {
    /// The longest value read (T15): a source and a destination of a valid ref (1,024 bytes each), `+` and `:`.
    static let maximumLength = 2_050

    private let source: Pattern
    /// `nil` for a negative refspec.
    private let destination: Pattern?

    /// One side, with its `*` found once at parse time (T15: rows reuse it).
    private struct Pattern: Sendable, Equatable {
        let head: [UInt8]
        /// After the `*`; `nil` for an exact side.
        let tail: [UInt8]?

        /// `nil` with more than one `*`.
        init?(_ bytes: ArraySlice<UInt8>) {
            guard let star = bytes.firstIndex(of: UInt8(ascii: "*")) else {
                head = Array(bytes)
                tail = nil
                return
            }
            let after = bytes[(star + 1)...]
            guard !after.contains(UInt8(ascii: "*")) else { return nil }
            head = Array(bytes[..<star])
            tail = Array(after)
        }

        /// What `*` matches in `ref` (an empty capture for an exact match); `nil` otherwise. A glob matches at least
        /// one byte.
        func capture(_ ref: [UInt8]) -> ArraySlice<UInt8>? {
            guard let tail else { return ref == head ? [] : nil }
            guard ref.count > head.count + tail.count, ref.starts(with: head),
                ref[(ref.count - tail.count)...].elementsEqual(tail)
            else { return nil }
            return ref[head.count..<(ref.count - tail.count)]
        }

        func filled(with middle: ArraySlice<UInt8>) -> [UInt8] {
            guard let tail else { return head }
            return head + middle + tail
        }
    }

    /// `nil` for a refspec that maps no remote-tracking ref (no destination), is malformed (a double glob, a glob on
    /// one side only), or is longer than `maximumLength`.
    init?(_ value: String) {
        guard value.utf8.count <= Self.maximumLength else { return nil }
        var spec = Array(value.utf8)[...]
        if spec.first == UInt8(ascii: "^") {
            guard let source = Pattern(spec.dropFirst()) else { return nil }
            self.source = source
            destination = nil
            return
        }
        if spec.first == UInt8(ascii: "+") { spec = spec.dropFirst() }
        guard let colon = spec.firstIndex(of: UInt8(ascii: ":")), colon < spec.endIndex - 1,
            let source = Pattern(spec[..<colon]), let destination = Pattern(spec[(colon + 1)...]),
            (source.tail == nil) == (destination.tail == nil)
        else { return nil }
        self.source = source
        self.destination = destination
    }

    /// The branch name (`refs/heads/` dropped) that `ref` holds, or `nil` when no refspec maps it from a branch, a
    /// negative refspec excludes that branch, or two refspecs map it from different sources.
    static func sourceBranch(of ref: String, refspecs: [FetchRefspec]) -> String? {
        let target = Array(ref.utf8)
        var sources: [[UInt8]] = []
        for refspec in refspecs {
            guard let destination = refspec.destination, let middle = destination.capture(target) else { continue }
            let mapped = refspec.source.filled(with: middle)
            if !sources.contains(mapped) { sources.append(mapped) }
        }
        let heads = Array("refs/heads/".utf8)
        guard sources.count == 1, let source = sources.first, source.starts(with: heads), source.count > heads.count,
            !refspecs.contains(where: { $0.destination == nil && $0.source.capture(source) != nil })
        else { return nil }
        return String(decoding: source.dropFirst(heads.count), as: UTF8.self)
    }

    /// The same for refspecs not parsed yet.
    static func sourceBranch(of ref: String, refspecs: [String]) -> String? {
        sourceBranch(of: ref, refspecs: refspecs.compactMap(FetchRefspec.init))
    }
}
