import Foundation

/// A path exactly as git printed it (parsing-spec.md §1.3).
///
/// git paths are bytes, not text. `raw` is what must be passed back to git; `display` is for the UI only.
/// Paths that are not valid UTF-8 cannot be sent back as `String` arguments, so file-level actions are disabled for
/// them (`isRepresentable == false`). No Unicode normalization is applied: NFC and NFD spellings are different paths.
struct GitPath: Sendable, Hashable {
    let raw: Data
    let display: String
    let isRepresentable: Bool

    init(raw: Data) {
        self.raw = raw
        if let text = String(data: raw, encoding: .utf8) {
            display = text
            isRepresentable = true
        } else {
            display = String(decoding: raw, as: UTF8.self)
            isRepresentable = false
        }
    }

    init(_ string: String) {
        self.init(raw: Data(string.utf8))
    }

    /// The path as a `String` argument for git, or `nil` when it cannot be represented losslessly.
    var argument: String? { isRepresentable ? display : nil }
}

extension GitPath: CustomStringConvertible {
    var description: String { display }
}
