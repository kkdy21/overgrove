/// The configured remote names, to tell which remote a `refs/remotes/<remote>/<branch>` ref belongs to when names
/// contain `/` (`team` and `team/a`) or are names `RemoteName` refuses (#489).
///
/// A byte trie: names compare in UTF-8 bytes (Swift `String` equality folds normalization, so `café` in NFC and NFD
/// would be one remote), and a lookup walks the ref once, so the cost does not grow with the number or length of the
/// names a repository configures (T15).
struct RemoteNameIndex: Sendable, Equatable {
    /// `node << 8 | byte` → child node. Node 0 is the root.
    private var edges: [Int: Int] = [:]
    /// Nodes where a name ends.
    private var ends: Set<Int> = []
    private var nodeCount = 1

    static let empty = RemoteNameIndex([])

    init(_ names: some Sequence<String>) {
        for name in names where !name.isEmpty {
            var node = 0
            for byte in name.utf8 {
                let key = node << 8 | Int(byte)
                if let child = edges[key] {
                    node = child
                } else {
                    edges[key] = nodeCount
                    node = nodeCount
                    nodeCount += 1
                }
            }
            ends.insert(node)
        }
    }

    /// The longest name `n` such that `rest` starts with `n/`, in bytes, or `nil`.
    func remote(of rest: String) -> String? {
        let bytes = rest.utf8
        var node = 0
        var length = 0
        var longest: Int?
        for byte in bytes {
            if byte == UInt8(ascii: "/"), length > 0, ends.contains(node) { longest = length }
            guard let child = edges[node << 8 | Int(byte)] else { break }
            node = child
            length += 1
        }
        return longest.map { String(decoding: bytes.prefix($0), as: UTF8.self) }
    }
}
