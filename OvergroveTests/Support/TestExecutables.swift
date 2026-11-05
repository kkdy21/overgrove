import Foundation

/// Small executables for exercising `ProcessRunner` in tests.
///
/// Test support code is the one place outside `Overgrove/Execution/` that may mention shells
/// (docs/README.md §2.2). Scripts are written to a fresh temporary directory per test case.
struct TestExecutables {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Prints "out" to stdout, "err" to stderr, and exits with the given code.
    func exitWith(_ code: Int32) throws -> URL {
        try script("exit-\(code)", "echo out\necho err >&2\nexit \(code)")
    }

    /// Ignores SIGTERM, then floods stdout. Termination is triggered by the output limit only after the trap is
    /// installed, so the test does not race the shell's startup.
    func ignoringSIGTERMThenFlooding() throws -> URL {
        try script("ignore-term", "trap '' TERM\nwhile :; do echo flood; done")
    }

    /// Starts a background `sleep` (a grandchild of the runner), writes its pid to the file passed as $1, then floods
    /// stdout so the output limit triggers termination after the grandchild exists.
    func spawningGrandchildThenFlooding() throws -> URL {
        try script("grandchild", "sleep 300 &\necho $! > \"$1\"\nwhile :; do echo flood; done")
    }

    /// Exits immediately but leaves a background child holding stdout open for a long time.
    func leavingChildWithOpenStdout() throws -> URL {
        try script("linger", "sleep 300 &\necho started\nexit 0")
    }

    private func script(_ name: String, _ body: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// Whether a process with this pid still exists (running or zombie).
func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}
