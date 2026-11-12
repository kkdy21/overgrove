import Foundation

/// How git picks a transport for a remote URL (transport.c), used to report repository-chosen remote helpers and to
/// classify `transport '<name>' not allowed` refusals (#161, T5).
///
/// `isBuiltInFetchForm` refuses remotes that are not in a built-in transport form before fetch starts (#350);
/// `GIT_ALLOW_PROTOCOL` refuses helpers outside the allowed transports at fetch time (#161).
enum TransportName {
    /// Schemes git handles itself or with its own bundled helpers (`git-remote-http(s)`, `-ftp(s)`). Any other
    /// `<scheme>://` URL runs an external `git-remote-<scheme>`.
    static let builtInSchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "git", "ssh", "git+ssh", "ssh+git", "file",
    ]

    /// git's `is_urlschemechar`: the first character is a letter or digit, later ones may also be `+`, `-`, `.`.
    static func isSchemeName(_ name: some StringProtocol) -> Bool {
        var isFirst = true
        for scalar in name.unicodeScalars {
            guard scalar.isASCII else { return false }
            let isAlphanumeric = scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
            guard isAlphanumeric || (!isFirst && "+-.".unicodeScalars.contains(scalar)) else { return false }
            isFirst = false
        }
        return !isFirst
    }

    /// Schemes fetch accepts, compared as git does (case-sensitive): git's native transports and the http(s) helpers
    /// git ships. Matches `GitEnvironment.allowedProtocols` (#350).
    static let fetchSchemes: Set<String> = ["https", "http", "ssh", "git", "file", "git+ssh", "ssh+git"]

    /// Shown when fetch refuses a remote that is not in a built-in transport form (#350).
    static let nonBuiltInRemoteReason = SafetyReason.nonBuiltInRemote

    /// Whether git would fetch `url` with a built-in transport: `<scheme>://` with a scheme in `fetchSchemes`, an
    /// scp-style address, or a path. Any `<name>::<address>` form, an unknown or differently cased scheme, and
    /// `ftp(s)` are not (#350, T5). Checked before every fetch, together with `remote.<n>.vcs` and
    /// `url.<base>.insteadOf` (`RepoConfigInspector`).
    ///
    /// Follows transport.c and `is_url` byte by byte, as git does: a run of scheme characters from the start (the
    /// first alphanumeric, later ones also `+`, `-`, `.`), then `::` (a helper, even with an empty name) or `://`.
    /// String comparison would treat canonically equivalent text as equal, which git does not.
    static func isBuiltInFetchForm(_ url: String) -> Bool {
        isBuiltInFetchForm(ScannedBytes(""), ScannedBytes(url), from: 0)
    }

    /// A value's bytes with, for every index, where the run of scheme characters (`+`, `-`, `.` allowed) starting
    /// there ends. Lets `isBuiltInFetchForm(_:_:from:)` judge a rewritten URL without joining or rescanning it.
    struct ScannedBytes {
        let bytes: [UInt8]
        /// `bytes.count + 1` entries; `runEnd[i]` is the first index at or after `i` that is not a scheme character.
        let runEnd: [Int]

        init(_ value: String) {
            bytes = Array(value.utf8)
            var runEnd = Array(repeating: bytes.count, count: bytes.count + 1)
            for index in bytes.indices.reversed() {
                runEnd[index] = TransportName.isSchemeByte(bytes[index], isFirst: false) ? runEnd[index + 1] : index
            }
            self.runEnd = runEnd
        }
    }

    /// `isBuiltInFetchForm` of `head` followed by the bytes of `tail` from `start` (a `url.<base>.insteadOf` rewrite
    /// is the base followed by the rest of the URL). Constant work apart from the scheme name it may compare.
    static func isBuiltInFetchForm(_ head: ScannedBytes, _ tail: ScannedBytes, from start: Int) -> Bool {
        let headCount = head.bytes.count
        let count = headCount + tail.bytes.count - start
        func byte(_ index: Int) -> UInt8 {
            index < headCount ? head.bytes[index] : tail.bytes[start + index - headCount]
        }
        func follows(_ separator: [UInt8], at index: Int) -> Bool {
            index + separator.count <= count && separator.indices.allSatisfy { byte(index + $0) == separator[$0] }
        }
        // The run of scheme characters from the start: the first alphanumeric, later ones also `+`, `-`, `.`.
        var end = 0
        if count > 0, isSchemeByte(byte(0), isFirst: true) {
            if headCount > 0 {
                end = head.runEnd[1]
                if end == headCount { end = headCount + tail.runEnd[start] - start }
            } else {
                end = tail.runEnd[start + 1] - start
            }
        }
        if follows(helperSeparator, at: end) { return false }
        if end > 0, follows(schemeSeparator, at: end) {
            guard end <= longestFetchScheme else { return false }
            return fetchSchemes.contains(String(decoding: (0..<end).map(byte), as: UTF8.self))
        }
        return true
    }

    private static let helperSeparator = Array("::".utf8)
    private static let schemeSeparator = Array("://".utf8)
    private static let longestFetchScheme = fetchSchemes.map(\.utf8.count).max() ?? 0

    /// git's `is_urlschemechar` on one byte.
    static func isSchemeByte(_ byte: UInt8, isFirst: Bool) -> Bool {
        let isAlphanumeric =
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        return isAlphanumeric
            || (!isFirst && (byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")))
    }

    /// The external helper a remote URL makes git run, or `nil` for a built-in transport, an scp-style address, or a
    /// path. Covers `<helper>::<address>` (the helper name may even be empty) and `<scheme>://` with a scheme git
    /// does not handle itself. Scheme comparison ignores case: on a case-insensitive volume `EvilHelper://` finds
    /// `git-remote-evilhelper`.
    static func remoteHelper(forURL url: String) -> Substring? {
        if let separator = url.range(of: "::") {
            let name = url[..<separator.lowerBound]
            if name.isEmpty || isSchemeName(name) { return name }
        }
        if let separator = url.range(of: "://") {
            let scheme = url[..<separator.lowerBound]
            if isSchemeName(scheme), !builtInSchemes.contains(scheme.lowercased()) { return scheme }
        }
        return nil
    }
}
