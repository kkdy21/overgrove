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

    /// A fake `gh` that records how it was started and replies with fixed output.
    ///
    /// It writes its arguments (NUL-separated), physical working directory, and environment into its own folder,
    /// then prints `stdout` and `stderr` byte for byte and exits with `exitCode`. Output is read from files, so the
    /// test data needs no quoting. With `sleepSeconds`, it sleeps before replying (for timeout tests).
    func fakeGH(stdout: String, stderr: String = "", exitCode: Int32 = 0, sleepSeconds: Int = 0) throws -> FakeGH {
        let name = "fake-gh-\(UUID().uuidString)"
        let fake = FakeGH(root: directory.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: fake.root, withIntermediateDirectories: true)
        try Data(stdout.utf8).write(to: fake.stdoutFile)
        try Data(stderr.utf8).write(to: fake.stderrFile)
        _ = try script(
            "\(name)/gh",
            """
            for a in "$@"; do printf '%s\\0' "$a"; done > '\(fake.argumentsFile.path)'
            pwd -P > '\(fake.directoryFile.path)'
            /usr/bin/env > '\(fake.environmentFile.path)'
            if [ \(sleepSeconds) -gt 0 ]; then sleep \(sleepSeconds); fi
            cat '\(fake.stdoutFile.path)'
            cat '\(fake.stderrFile.path)' >&2
            exit \(exitCode)
            """
        )
        return fake
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

    /// A harmless payload that appends its arguments to `<canary>/<id>` and then runs `tail` (default `exit 0`).
    /// Like the `--malicious` fixture's payloads (fixtures.md §8.1), it does nothing but record that it ran.
    func canaryPayload(_ id: String, canary: URL, tail: String = "exit 0") throws -> URL {
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        let record = canary.appendingPathComponent(id).path
        return try script("payload-\(id)-\(UUID().uuidString)", "printf '%s\\n' \"$*\" >> '\(record)'\n\(tail)")
    }

    /// Runs its arguments as a command with stdin read from `input` (`ProcessRunner` always gives /dev/null).
    /// Used for `git credential fill`, the stand-in for HTTP authentication (fixtures.md §8.2, M35–38).
    func stdinWrapper(input: String) throws -> URL {
        let file = directory.appendingPathComponent("stdin-\(UUID().uuidString)")
        try Data(input.utf8).write(to: file)
        return try script("with-stdin-\(UUID().uuidString)", "exec \"$@\" < '\(file.path)'")
    }

    /// A stand-in for a trusted `core.sshCommand` that fails the way OpenSSH does: it writes `stderr` and exits 255,
    /// so git adds its own `fatal:` lines on top (#78). The `-G` probe fails too, as for a non-OpenSSH command.
    func failingSSH(stderr: String) throws -> URL {
        let message = directory.appendingPathComponent("ssh-stderr-\(UUID().uuidString)")
        try stderr.write(to: message, atomically: true, encoding: .utf8)
        return try script(
            "failing-ssh-\(UUID().uuidString)",
            "[ \"$1\" = \"-G\" ] && exit 1\ncat '\(message.path)' >&2\nexit 255"
        )
    }

    /// A program that records that it ran by creating `<canary>/<name>`, prints `stdout`, and exits 0 (#93). Stands in
    /// for anything a hostile environment or configuration could make git run (pager, external diff, askpass, ssh).
    func canaryProgram(named name: String, canary: URL, stdout: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
        let marker = canary.appendingPathComponent(name).path
        let printed = stdout.isEmpty ? "" : "printf '%s\\n' '\(stdout)'\n"
        return try script("canary-\(name)-\(UUID().uuidString)", ": > '\(marker)'\n\(printed)exit 0")
    }

    /// A stand-in for the git executable that forwards to `git`, appends each invocation's subcommand to
    /// `<markers>/invocations.log`, and holds every `status` call until `<markers>/release` exists (at most 30 s). Each
    /// held call first creates `<markers>/started-<pid>`, so a test can count how many run at once (#87).
    func gatedGit(forwardingTo git: URL, markers: URL) throws -> URL {
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let body = """
            for arg in "$@"; do
              case "$arg" in
                -c|--no-pager|--no-optional-locks|--literal-pathspecs) ;;
                *=*) ;;
                -*) ;;
                *) subcommand="$arg"; break ;;
              esac
            done
            echo "${subcommand:-}" >> '\(markers.path)/invocations.log'
            if [ "${subcommand:-}" = "status" ]; then
              : > '\(markers.path)'/started-$$
              i=0
              while [ ! -e '\(markers.path)/release' ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done
            fi
            exec '\(git.path)' "$@"
            """
        return try script("gated-git-\(UUID().uuidString)", body)
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

/// The open descriptor count once it has stopped changing (#234).
///
/// `ProcessRunner` closes a run's pipe descriptors in dispatch cancel handlers, which run on its queue just after
/// `run` returns, and an earlier test's abandoned pipes close the same way. A count taken at once can therefore be
/// one or two off in either direction. This waits until `stableReads` reads in a row agree.
func settledDescriptorCount(stableReads: Int = 3, timeout: Duration = .seconds(5)) async -> Int {
    let deadline = ContinuousClock.now + timeout
    var last = openDescriptorCount()
    var agreeing = 1
    while agreeing < stableReads, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(50))
        let current = openDescriptorCount()
        agreeing = current == last ? agreeing + 1 : 1
        last = current
    }
    return last
}

/// What a fake `gh` from `TestExecutables.fakeGH` recorded about its last run.
struct FakeGH {
    let root: URL

    var executable: URL { root.appendingPathComponent("gh") }
    var argumentsFile: URL { root.appendingPathComponent("args") }
    var directoryFile: URL { root.appendingPathComponent("pwd") }
    var environmentFile: URL { root.appendingPathComponent("env") }
    var stdoutFile: URL { root.appendingPathComponent("stdout") }
    var stderrFile: URL { root.appendingPathComponent("stderr") }

    /// `nil` until the fake has run.
    var recordedArguments: [String]? {
        guard let data = try? Data(contentsOf: argumentsFile) else { return nil }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
            String(decoding: $0, as: UTF8.self)
        }
    }

    var recordedDirectory: String? {
        (try? String(contentsOf: directoryFile, encoding: .utf8))?.trimmingCharacters(in: .newlines)
    }

    /// The child's environment. The shell adds `PWD`, `SHLVL`, and `_` itself; they are removed here.
    var recordedEnvironment: [String: String]? {
        guard let text = try? String(contentsOf: environmentFile, encoding: .utf8) else { return nil }
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
