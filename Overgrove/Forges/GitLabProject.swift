import Foundation

/// A validated GitLab host name for `--hostname` and the project URL (ADR-0026 §2).
///
/// A lowercase ASCII DNS name: labels of 1–63 letters, digits, or `-`, not starting or ending with `-`, at least two
/// labels, at most 253 bytes. No IP literal, user info, or port, so a URL built from it cannot point anywhere else.
struct GitLabHost: Sendable, Hashable, CustomStringConvertible {
    let name: String

    init?(_ name: String) {
        // STAND-IN(#117): ADR-0025's host rule, written here until #117's shared remote parsing lands.
        guard Self.isValid(name) else { return nil }
        self.name = name
    }

    var description: String { name }

    static func isValid(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // All-numeric labels are a dotted-decimal address, not a name.
        guard labels.count >= 2, !labels.allSatisfy({ $0.utf8.allSatisfy { (0x30...0x39).contains($0) } }) else {
            return false
        }
        return labels.allSatisfy { label in
            let bytes = label.utf8
            return (1...63).contains(bytes.count) && bytes.first != UInt8(ascii: "-")
                && bytes.last != UInt8(ascii: "-")
                && bytes.allSatisfy {
                    (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-")
                }
        }
    }
}

/// A validated GitLab project for `glab --repo https://HOST/NAMESPACE/NAME` (ADR-0026 §2, git-command-catalog.md §5.1).
///
/// NAMESPACE has 1–20 components (subgroups) and NAME one. A component is 1–255 bytes of ASCII letters, digits, `_`,
/// `.`, or `-`, does not start with `-` or `.`, and is not `.` or `..`. The whole path is at most 255 bytes.
struct GitLabProject: Sendable, Hashable, CustomStringConvertible {
    let host: GitLabHost
    let namespace: [String]
    let name: String

    init?(host: GitLabHost, namespace: [String], name: String) {
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
}
