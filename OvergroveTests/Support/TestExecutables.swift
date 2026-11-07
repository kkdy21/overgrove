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
        // The grandchild does not hold the pipes, so only a group-wide signal can stop it.
        try script("grandchild", "sleep 300 >/dev/null 2>&1 &\necho $! > \"$1\"\nwhile :; do echo flood; done")
    }

    /// Exits immediately but leaves a background child holding stdout open for a long time.
    func leavingChildWithOpenStdout() throws -> URL {
        try script("linger", "sleep 300 &\necho started\nexit 0")
    }

    /// Starts a helper that ignores SIGTERM and holds no pipe (pid written to $1), then floods stdout so the output
    /// limit triggers termination. The leader itself dies on SIGTERM.
    func spawningSIGTERMIgnoringHelperThenFlooding() throws -> URL {
        try script(
            "stubborn-helper",
            "(trap '' TERM; exec sleep 300) >/dev/null 2>&1 &\necho $! > \"$1\"\nwhile :; do echo flood; done"
        )
    }

    /// Ignores SIGTERM, creates the file passed as $1 once the trap is installed, then idles.
    func ignoringSIGTERMWithReadyFile() throws -> URL {
        try script("ignore-term-ready", "trap '' TERM\n: > \"$1\"\nwhile :; do sleep 1; done")
    }

    /// Prints "clean" unless file descriptor $1 is open in the child.
    func reportingDescriptor() throws -> URL {
        try script("fd-probe", "if [ -e \"/dev/fd/$1\" ]; then echo leaked; else echo clean; fi")
    }

    /// A fake developer directory whose `usr/bin/git` prints the given `git version` line.
    func fakeDeveloperDirectory(versionLine: String) throws -> URL {
        let root = directory.appendingPathComponent("fake-developer-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let git = bin.appendingPathComponent("git")
        try "#!/bin/sh\necho '\(versionLine)'\n".write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        return root
    }

    /// A directory holding `git-remote-<name>`, a stand-in for a remote helper the user installed (e.g. in
    /// `/opt/homebrew/bin`). When git runs it, it creates `<canary>/<name>-ran` and exits 1 (#161, T5).
    func canaryRemoteHelper(named name: String, canary: URL) throws -> URL {
        let bin = directory.appendingPathComponent("helper-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        let marker = canary.appendingPathComponent("\(name)-ran").path
        _ = try script("git-remote-\(name)", ": > '\(marker)'\nexit 1", in: bin)
        return bin
    }

    /// A stand-in for a trusted `core.sshCommand` that serves `ssh://<host>/…` from `<remotes>/<host>.git` with the
    /// real `git upload-pack`, so fetch tests need no network (#76).
    ///
    /// It creates `<markers>/<host>.started` when git connects. With `gated`, it then waits for
    /// `<markers>/<host>.release` (at most 30 seconds) before serving, which keeps a fetch running for as long as a
    /// test needs. git first probes the command with `-G` to detect OpenSSH; failing that probe makes git use the
    /// plain `<host> <command>` form.
    func fakeSSHServer(git: URL, remotes: URL, markers: URL, gated: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let wait =
            gated
            ? "i=0\nwhile [ ! -e '\(markers.path)'/\"$host\".release ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done\n"
            : ""
        let body = """
            [ "$1" = "-G" ] && exit 1
            host="$1"
            : > '\(markers.path)'/"$host".started
            \(wait)exec '\(git.path)' upload-pack '\(remotes.path)'/"$host".git
            """
        return try script("fake-ssh-\(UUID().uuidString)", body)
    }

    private func script(_ name: String, _ body: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? directory).appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// Whether a process with this pid still exists (running or zombie).
func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

/// Polls `condition` until it holds or `timeout` passes. Returns the final value.
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Number of file descriptors open in the current process.
func openDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
}
