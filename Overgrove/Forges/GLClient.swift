import Foundation

/// Runs allowlisted glab commands (git-command-catalog.md §5.1, ADR-0026). Every glab process in the app goes through
/// here, hardened like `GHClient`:
/// - the executable is looked up at fixed paths only, never through PATH (ADR-0008), and its `--version` line must be
///   glab's, at least `minimumVersion`, before anything else runs: another tool may be installed as `glab`;
/// - nothing runs until glab's own configuration file exists, because glab creates one on first use (ADR-0021, as
///   ADR-0025 reads it: the app does not create the user's tool settings);
/// - the working directory is an app-owned empty folder, never a repository;
/// - the environment is rebuilt from an allowlist, with telemetry, update checks, prompts, and automatic downloads off;
/// - raw output stays in this actor; glab's stderr is dropped, not masked (ADR-0026 §4).
actor GLClient {
    static let defaultExecutableCandidates = [
        URL(fileURLWithPath: "/opt/homebrew/bin/glab"),
        URL(fileURLWithPath: "/usr/local/bin/glab"),
    ]

    /// The version these rules were checked against (ADR-0026, measured 2026-11-08).
    static let minimumVersion = GitVersion(major: 1, minor: 128, patch: 0)

    /// Taken from the parent. `HOME` is not: glab gets the folder whose configuration `isSetUp()` checked.
    static let passthroughVariables = ["USER", "TMPDIR"]

    /// Fixed variables for every glab process (git-command-catalog.md §5.1). glab sends usage data and checks for
    /// updates by default (`POST /api/v4/usage_data/track_event`, a releases request); both are turned off here.
    static let fixedEnvironment: [String: String] = [
        "PATH": GitEnvironment.path,
        "LC_ALL": "C",
        "GIT_TERMINAL_PROMPT": "0",
        "NO_COLOR": "1",
        "GLAB_SEND_TELEMETRY": "false",
        "GLAB_CHECK_UPDATE": "false",
        "GLAB_NO_PROMPT": "true",
        "GLAB_PAGER": "cat",
        "GLAB_DISPLAY_HYPERLINKS": "false",
        "GLAB_SHOW_WHATS_NEW": "false",
        "GLAB_NOTIFY_SKILL_UPDATES": "false",
        "GLAB_DUO_CLI_AUTO_DOWNLOAD": "false",
        "GLAB_DUO_CLI_AUTO_RUN": "false",
        "GLAB_ORBIT_CLI_AUTO_DOWNLOAD": "false",
        "GLAB_ORBIT_CLI_AUTO_RUN": "false",
    ]

    static let defaultNeutralDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("io.github.kkdy21.overgrove.glab-neutral", isDirectory: true)

    /// Where glab keeps its configuration, relative to HOME; glab reads either (1.128.0, measured).
    static let configurationFiles = [".config/glab-cli/config.yml", "Library/Application Support/glab-cli/config.yml"]

    private let parentEnvironment: [String: String]
    private let executableCandidates: [URL]
    private let launcher: ForgeCLILauncher
    private let home: URL

    init(
        runner: ProcessRunner = ProcessRunner(),
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        neutralDirectory: URL = GLClient.defaultNeutralDirectory,
        executableCandidates: [URL] = GLClient.defaultExecutableCandidates,
        limits: ProcessLimits = .gh,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.parentEnvironment = parentEnvironment
        self.executableCandidates = executableCandidates
        launcher = ForgeCLILauncher(runner: runner, neutralDirectory: neutralDirectory, limits: limits)
        self.home = home
    }

    /// The complete child environment: the allowlist, nothing else from `parent`, and `HOME` set to `home`, the folder
    /// whose glab configuration was checked, so glab reads exactly that configuration.
    static func environment(parent: [String: String], home: URL) -> [String: String] {
        var environment = fixedEnvironment
        for key in passthroughVariables {
            if let value = parent[key] { environment[key] = value }
        }
        environment["HOME"] = home.path
        return environment
    }

    /// `glab 1.128.0 (519ea19f7)` → 1.128.0; `nil` for any other first line (another tool named `glab`).
    static func parseVersion(_ output: Data) -> GitVersion? {
        let line = String(decoding: output.prefix(256), as: UTF8.self).split(separator: "\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "glab" else { return nil }
        let numbers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
            numbers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2])
        else { return nil }
        return GitVersion(major: major, minor: minor, patch: patch)
    }

    // MARK: - Commands

    /// Whether glab reports `host` as logged in (ADR-0026 §2). glab refuses an unconfigured host without the network.
    func hostStatus(_ host: RemoteHost) async throws -> GLHostStatus {
        try await hostStatus(host, executable: try await preparedExecutable())
    }

    private func hostStatus(_ host: RemoteHost, executable: URL) async throws -> GLHostStatus {
        let output = try await run(.authStatus(host: host), executable: executable, acceptsAnyExit: true)
        let hosts: [GLHostStatus]
        do {
            hosts = try GLAuthParser.parse(output)
        } catch {
            // glab prints an error object, not `hosts`, for a host it has no configuration for.
            return GLHostStatus(host: host.name, user: nil)
        }
        return hosts.first { $0.host == host.name } ?? GLHostStatus(host: host.name, user: nil)
    }

    /// Open issues of `project`, after its host is confirmed logged in.
    func issues(in project: GitLabProject) async throws -> [Issue] {
        // One setup and version check for the whole load.
        let executable = try await preparedExecutable()
        guard try await hostStatus(project.host, executable: executable).isLoggedIn else {
            throw GLError.notLoggedIn(host: project.host.name)
        }
        let output = try await run(.issueList(project: project), executable: executable, acceptsAnyExit: false)
        do {
            return try GLIssueParser.parse(output)
        } catch let error as ParseError {
            throw GLError.parseFailed(parser: error.parser)
        }
    }

    // MARK: - Execution

    /// glab's configuration exists and the executable is a supported glab; nothing runs before this passes.
    private func preparedExecutable() async throws -> URL {
        guard isSetUp() else { throw GLError.notSetUp }
        return try await verifiedExecutable()
    }

    /// Runs `command` with a prepared executable and returns stdout. glab's `auth status` exits non-zero for a host
    /// that is not logged in, so its JSON is read regardless of the exit code.
    private func run(_ command: GLCommand, executable: URL, acceptsAnyExit: Bool) async throws -> Data {
        let result = try await launch(command, executable: executable)
        guard acceptsAnyExit || result.termination == .exited(code: 0) else {
            throw GLError.failed(code: ForgeCLILauncher.failureCode(result.termination))
        }
        return result.stdout
    }

    /// glab's configuration file exists in one of the places glab reads. Nothing runs otherwise (ADR-0026 §6).
    func isSetUp() -> Bool {
        Self.configurationFiles.contains { relative in
            var isDirectory: ObjCBool = false
            let path = home.appendingPathComponent(relative).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    private func verifiedExecutable() async throws -> URL {
        guard let executable = GHClient.locateExecutable(candidates: executableCandidates) else {
            throw GLError.notInstalled
        }
        let result = try await launch(.version, executable: executable)
        guard result.termination == .exited(code: 0), let version = Self.parseVersion(result.stdout) else {
            throw GLError.notInstalled
        }
        guard version >= Self.minimumVersion else { throw GLError.unsupportedVersion(found: version.description) }
        return executable
    }

    private func launch(_ command: GLCommand, executable: URL) async throws(GLError) -> ProcessResult {
        do {
            return try await launcher.run(
                executable: executable, arguments: command.arguments,
                environment: Self.environment(parent: parentEnvironment, home: home))
        } catch {
            throw GLError(error)
        }
    }
}

extension GLError {
    init(_ failure: ForgeCLILauncher.Failure) {
        switch failure {
        case .notInstalled: self = .notInstalled
        case .launchFailed(let code): self = .launchFailed(errno: code)
        case .timeout(let seconds): self = .timeout(seconds: seconds)
        case .outputTruncated: self = .outputTruncated
        case .cancelled: self = .cancelled
        }
    }
}
