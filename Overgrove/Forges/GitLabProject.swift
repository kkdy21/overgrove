import Foundation

/// A validated GitLab project for `glab --repo https://HOST/NAMESPACE/NAME` (ADR-0026 §2, git-command-catalog.md §5.1).
///
/// HOST is a `RemoteHost` (ADR-0025 §2, shared with GitHub): a lowercase ASCII DNS name, no IP literal, user info, or
/// port, so a URL built from it cannot point anywhere else.
///
/// NAMESPACE has 1–20 components (subgroups) and NAME one. A component is 1–255 bytes of ASCII letters, digits, `_`,
/// `.`, or `-`, does not start with `-` or `.`, and is not `.` or `..`. The whole path is at most 255 bytes.
struct GitLabProject: Sendable, Hashable, CustomStringConvertible {
    let host: RemoteHost
    let namespace: [String]
    let name: String

    init?(host: RemoteHost, namespace: [String], name: String) {
        guard (1...20).contains(namespace.count), namespace.allSatisfy(Self.isValidComponent),
            Self.isValidComponent(name), (namespace + [name]).joined(separator: "/").utf8.count <= 255
        else { return nil }
        self.host = host
        self.namespace = namespace
        self.name = name
    }

    /// `NAMESPACE/NAME`.
    var path: String { (namespace + [name]).joined(separator: "/") }

    /// `https://HOST/NAMESPACE/NAME`, the `--repo` value.
    var url: String { "https://\(host.name)/\(path)" }

    var description: String { "\(host.name)/\(path)" }

    static func isValidComponent(_ component: String) -> Bool {
        let bytes = component.utf8
        guard (1...255).contains(bytes.count), component != ".", component != "..",
            bytes.first != UInt8(ascii: "-"), bytes.first != UInt8(ascii: ".")
        else { return false }
        return bytes.allSatisfy {
            (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || (0x30...0x39).contains($0)
                || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-")
        }
    }

    /// The issue page Open in Browser may open: glab's `web_url` only when it is exactly this project's
    /// `/-/issues/<iid>` or `/-/work_items/<iid>` page on its host (ADR-0026 §5, `GitLabRemote.issueURL`).
    func browserURL(for issue: Issue) -> URL? {
        GitLabRemote.issueURL(for: issue, in: self)
    }
}
