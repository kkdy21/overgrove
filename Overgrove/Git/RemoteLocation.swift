import Foundation

/// Where a remote URL points, by git's own rule (#107).
enum RemoteLocation {
    /// Whether fetching `url` runs git on this Mac in another repository: a local path or a `file://` URL. Follows
    /// git's `url_is_local_not_ssh`: a URL without `://` is local unless it reads as `host:path` (a colon with no slash
    /// before it). Remote helpers (`name::address`) and other schemes are not local. `FILE://` counts as local too,
    /// which only refuses more in untrusted mode.
    ///
    /// Compared byte by byte, as git does (`TransportName.isBuiltInFetchForm`, #350): `String` and `Character`
    /// comparison would let a combining mark hide a `/` or a `:`.
    static func isLocal(_ url: String) -> Bool {
        let bytes = Array(url.utf8)
        guard !bytes.isEmpty else { return false }
        var end = 0
        while end < bytes.count, TransportName.isSchemeByte(bytes[end], isFirst: end == 0) { end += 1 }
        let rest = bytes[end...]
        if rest.starts(with: "::".utf8) { return false }
        if end > 0, rest.starts(with: "://".utf8) {
            return String(decoding: bytes[..<end], as: UTF8.self).lowercased() == "file"
        }
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return true }
        if let slash = bytes.firstIndex(of: UInt8(ascii: "/")), slash < colon { return true }
        return false
    }
}
