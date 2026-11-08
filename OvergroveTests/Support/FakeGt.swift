import Foundation

/// A stand-in for `gt` (#449): `--version` prints `versionLine`; `auth …` prints `authJSON` and exits `authExit`;
/// `issue …` prints `issuesJSON` (and `stderr`) and exits `issueExit`. Every call's arguments are appended to `calls`,
/// one call per line with arguments separated by spaces; the last call's environment and directory are recorded.
///
/// STAND-IN(#154): kept apart from #154's `fakeGlab` until that merges; then both share one helper.
struct FakeGt {
    let root: URL

    var executable: URL { root.appendingPathComponent("gt") }

    init(
        in executables: TestExecutables, versionLine: String = "gt version 1.1.0 (2026-11-05)", authJSON: String = "[]",
        authExit: Int32 = 0, issuesJSON: String = "[]", issueExit: Int32 = 0, stderr: String = ""
    ) throws {
        root = executables.directory.appendingPathComponent("fake-gt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(versionLine.utf8).write(to: root.appendingPathComponent("version"))
        try Data(authJSON.utf8).write(to: root.appendingPathComponent("auth"))
        try Data(issuesJSON.utf8).write(to: root.appendingPathComponent("issues"))
        try Data(stderr.utf8).write(to: root.appendingPathComponent("stderr"))
        let path = root.path
        let body = """
            #!/bin/sh
            echo "$*" >> '\(path)/calls'
            pwd -P > '\(path)/pwd'
            /usr/bin/env > '\(path)/env'
            case "$1" in
              --version) cat '\(path)/version'; echo; exit 0 ;;
              auth) cat '\(path)/auth'; exit \(authExit) ;;
              issue) cat '\(path)/issues'; cat '\(path)/stderr' >&2; exit \(issueExit) ;;
            esac
            exit 2

            """
        try body.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    /// Every call, in order, as its arguments joined by spaces.
    var calls: [String] {
        ((try? String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var recordedDirectory: String? {
        (try? String(contentsOf: root.appendingPathComponent("pwd"), encoding: .utf8))?
            .trimmingCharacters(in: .newlines)
    }

    /// The last call's environment, without what the shell adds itself.
    var recordedEnvironment: [String: String]? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("env"), encoding: .utf8) else {
            return nil
        }
        var environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            environment[String(parts[0])] = String(parts[1])
        }
        for key in ["PWD", "SHLVL", "_", "OLDPWD"] { environment[key] = nil }
        return environment
    }
}
