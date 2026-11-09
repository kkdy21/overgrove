import Foundation

/// A Gitea instance URL as `gt auth status` reports it, validated (ADR-0026 §2): `https://HOST[:PORT][/BASE]`.
///
/// HOST is a `RemoteHost` (ADR-0025 §2) and must already be lowercase as printed. PORT is 1–65535 without a leading zero. BASE is 0–5 path
/// components (`GiteaRepository.isValidComponent`). No user info, query, fragment, or trailing `/`: gt prints the URL
/// in this normalized form (lowercase host, no trailing `/`, gt 1.1.0 measured), and `url` is passed to `--host`
/// exactly as gt printed it, never rebuilt from a remote.
struct GiteaInstance: Sendable, Hashable, CustomStringConvertible {
    /// The URL exactly as gt printed it.
    let url: String
    let host: RemoteHost
    let port: Int?
    let basePath: [String]

    static let maximumBaseComponents = 5

    init?(_ text: String) {
        let scheme = "https://"
        guard text.hasPrefix(scheme), text.utf8.count <= 2_048 else { return nil }
        let rest = text.dropFirst(scheme.count)
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let authority = parts.first else { return nil }
        let base = Array(parts.dropFirst())
        guard base.count <= Self.maximumBaseComponents, base.allSatisfy(GiteaRepository.isValidComponent) else {
            return nil
        }
        let hostAndPort = authority.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // The shared host rule (#117); gt prints the host lowercase, and anything else is refused, not normalized.
        guard (1...2).contains(hostAndPort.count), let host = RemoteHost(hostAndPort[0]), host.name == hostAndPort[0]
        else { return nil }
        var port: Int?
        if hostAndPort.count == 2 {
            let digits = hostAndPort[1]
            guard (1...5).contains(digits.utf8.count), digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                digits.utf8.first != UInt8(ascii: "0"), let value = Int(digits), (1...65_535).contains(value)
            else { return nil }
            port = value
        }
        self.url = text
        self.host = host
        self.port = port
        self.basePath = base
    }

    var description: String { url }
}

/// A validated Gitea repository for `gt issue list --host INSTANCE --repo OWNER/NAME` (ADR-0026 §2,
/// git-command-catalog.md §5.1).
///
/// OWNER and NAME are one component each (1–255 bytes of ASCII letters, digits, `_`, `.`, or `-`, not starting with
/// `-` or `.`, not `.` or `..`), OWNER at most 40 bytes and NAME at most 100.
struct GiteaRepository: Sendable, Hashable, CustomStringConvertible {
    let instance: GiteaInstance
    let owner: String
    let name: String

    static let maximumOwner = 40
    static let maximumName = 100

    init?(instance: GiteaInstance, owner: String, name: String) {
        guard Self.isValidComponent(owner), owner.utf8.count <= Self.maximumOwner, Self.isValidComponent(name),
            name.utf8.count <= Self.maximumName
        else { return nil }
        self.instance = instance
        self.owner = owner
        self.name = name
    }

    /// `OWNER/NAME`, the `--repo` value.
    var slug: String { "\(owner)/\(name)" }

    var description: String { "\(instance.url)/\(slug)" }

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
