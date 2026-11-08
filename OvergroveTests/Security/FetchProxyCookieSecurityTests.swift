import Foundation
import XCTest

@testable import Overgrove

/// T11 on the app's real fetch path (#355): a repository's proxy and cookie settings do not decide where a fetch
/// connects or what it sends.
///
/// Two loopback servers stand in for the remote and for a proxy the repository names (`LocalHTTPAuthServer`, which
/// answers 401 and records each request's headers). A trusted credential helper in the test's global config answers
/// for the remote, as a user's keychain would. No network.
final class FetchProxyCookieSecurityTests: XCTestCase {
    private var executables: TestExecutables!
    private var remote: LocalHTTPAuthServer!
    private var proxy: LocalHTTPAuthServer!
    private var repository: GitTestRepository!
    private var canary: URL!

    private var home: URL { executables.directory }

    override func setUp() async throws {
        executables = try TestExecutables()
        canary = executables.directory.appendingPathComponent("canary", isDirectory: true)
        remote = try await LocalHTTPAuthServer.start()
        proxy = try await LocalHTTPAuthServer.start()
        repository = try await GitTestRepository.make()
        try await repository.git(["remote", "add", "origin", remote.url()])
    }

    override func tearDown() {
        remote?.stop()
        proxy?.stop()
        repository?.remove()
        executables?.remove()
    }

    private var target: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private var proxyURL: String { "http://127.0.0.1:\(proxy.port)" }

    /// A helper in the user's global config that hands out a password for any host (trusted scope).
    private func trustTheHelper() async throws {
        let helper = try executables.canaryProgram(
            named: "helper", canary: canary, stdout: "username=alice\npassword=trusted-secret")
        try await plainGit([
            "config", "--file", home.appendingPathComponent(".gitconfig").path, "credential.helper",
            helper.path,
        ])
    }

    /// A Netscape cookie file with one cookie for the loopback remote.
    private func cookieFile() throws -> URL {
        let file = home.appendingPathComponent("cookies.txt")
        try "127.0.0.1\tFALSE\t/\tFALSE\t0\tsession\tcookie-canary\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Plain git with the test's HOME and no prompts: the control, without any of the app's arguments.
    @discardableResult
    private func plainGit(_ arguments: [String]) async throws -> ProcessResult {
        try await ProcessRunner().run(
            ProcessRequest(
                executable: repository.environment.executable, arguments: arguments,
                environment: ["HOME": home.path, "PATH": GitEnvironment.path, "GIT_TERMINAL_PROMPT": "0"],
                currentDirectory: repository.root, limits: .query))
    }

    /// Inspects the configuration and fetches `origin` the way the app does. The server always answers 401, so the
    /// fetch fails; what matters is what each server saw.
    private func appFetch() async throws {
        let client = GitClient(
            environment: repository.environment,
            parentEnvironment: ["HOME": home.path, "TMPDIR": FileManager.default.temporaryDirectory.path])
        let listing = try await client.run(.configList, in: repository.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        _ = try? await client.fetch(.fetch(remote: RemoteName("origin")!), in: target, safety: safety)
    }

    /// Whether a request after the first `skipping` carried a password.
    private func sawPassword(_ server: LocalHTTPAuthServer, skipping: Int) -> Bool {
        server.requestHeads.dropFirst(skipping).contains {
            $0.range(of: "\r\nAuthorization:", options: .caseInsensitive) != nil
        }
    }

    // MARK: - SEC-T11-07

    /// A repository's proxy (`remote.<name>.proxy`, and `http.<url>.proxy` from #150) never sees a request, so it
    /// cannot read the password a trusted helper releases over plain http.
    func testSECT11_07_RepositoryProxyNeverSeesTheFetch() async throws {
        try await trustTheHelper()
        for key in ["remote.origin.proxy", "http.\(remote.url("")).proxy", "http.proxy"] {
            try await repository.git(["config", key, proxyURL])

            // Control: plain git sends the request, password included, through the repository's proxy.
            let before = proxy.requestHeads.count
            try await plainGit(["fetch", "origin"])
            XCTAssertGreaterThan(proxy.requestHeads.count, before, "\(key) control: plain git must use the proxy")
            XCTAssertTrue(
                sawPassword(proxy, skipping: before), "\(key) control: the helper's password must reach the proxy")

            let proxied = proxy.requestCount
            let direct = remote.requestCount
            try await appFetch()
            XCTAssertEqual(proxy.requestCount, proxied, "\(key): the app's fetch must not go through the proxy")
            XCTAssertGreaterThan(remote.requestCount, direct, "\(key): the app's fetch goes to the remote directly")
            try await repository.git(["config", "--unset", key])
        }
    }

    /// SEC-T11-07: the override is the user's own proxy for that URL, not an empty value, so a fetch behind a company
    /// proxy keeps working while the repository's proxy still sees nothing.
    func testSECT11_07_TheUsersProxyReplacesTheRepositorys() async throws {
        let userProxy = try await LocalHTTPAuthServer.start()
        defer { userProxy.stop() }
        try await plainGit([
            "config", "--file", home.appendingPathComponent(".gitconfig").path, "http.proxy",
            "http://127.0.0.1:\(userProxy.port)",
        ])
        for key in ["remote.origin.proxy", "http.\(remote.url("")).proxy"] {
            try await repository.git(["config", key, proxyURL])
            let viaUser = userProxy.requestCount
            let viaRepository = proxy.requestCount
            try await appFetch()
            XCTAssertGreaterThan(userProxy.requestCount, viaUser, "\(key): the fetch goes through the user's proxy")
            XCTAssertEqual(proxy.requestCount, viaRepository, "\(key): never through the repository's")
            try await repository.git(["config", "--unset", key])
        }
    }

    // MARK: - SEC-T11-09

    /// #367: with the user's own proxy (which offers Digest), a repository's `proxyAuthMethod=basic` would make fetch
    /// send the proxy password as cleartext Basic. Checked for the generic, per-URL, and per-remote keys.
    func testSECT11_09_RepositoryCannotChooseTheProxyAuthMethod() async throws {
        let userProxy = try await LocalHTTPAuthServer.start(response: .proxyAuthenticationRequired)
        defer { userProxy.stop() }
        try await plainGit([
            "config", "--file", home.appendingPathComponent(".gitconfig").path, "http.proxy",
            "http://alice:proxy-secret@127.0.0.1:\(userProxy.port)",
        ])
        func sentBasic(skipping: Int) -> Bool {
            userProxy.requestHeads.dropFirst(skipping).contains {
                $0.range(of: "\r\nProxy-Authorization: Basic", options: .caseInsensitive) != nil
            }
        }
        for key in ["http.proxyAuthMethod", "http.\(remote.url("")).proxyAuthMethod", "remote.origin.proxyAuthMethod"] {
            try await repository.git(["config", key, "basic"])

            let before = userProxy.requestHeads.count
            try await plainGit(["-c", "credential.helper=", "fetch", "origin"])
            XCTAssertTrue(sentBasic(skipping: before), "\(key) control: plain git must send Basic to the proxy")

            let sent = userProxy.requestHeads.count
            try await appFetch()
            XCTAssertGreaterThan(userProxy.requestHeads.count, sent, "\(key): the app's fetch uses the user's proxy")
            XCTAssertFalse(sentBasic(skipping: sent), "\(key): the app's fetch must not send Basic")
            XCTAssertTrue(
                userProxy.requestHeads[sent...].contains { $0.contains("Proxy-Authorization: Digest") },
                "\(key): it answers the proxy's Digest challenge instead")
            try await repository.git(["config", "--unset", key])
        }
    }

    // MARK: - SEC-T11-10

    /// #367: `proxySSLCertPasswordProtected` makes git ask the trusted helper for the password of the user's proxy
    /// certificate. A repository does not get to trigger that query.
    func testSECT11_10_RepositoryCannotTriggerAProxyCertificatePasswordQuery() async throws {
        let config = home.appendingPathComponent(".gitconfig").path
        let helper = try executables.canaryProgram(named: "cert-helper", canary: canary)
        let certificate = home.appendingPathComponent("proxy-client.pem")
        try "not a certificate\n".write(to: certificate, atomically: true, encoding: .utf8)
        // The user's TLS proxy on a closed port: git asks for the password while it sets up the connection.
        try await plainGit(["config", "--file", config, "http.proxy", "https://127.0.0.1:9"])
        try await plainGit(["config", "--file", config, "http.proxySSLCert", certificate.path])
        try await plainGit(["config", "--file", config, "credential.helper", helper.path])
        let marker = canary.appendingPathComponent("cert-helper")

        try await plainGit(["fetch", "origin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no query without the setting")

        for key in ["http.proxySSLCertPasswordProtected", "http.\(remote.url("")).proxySSLCertPasswordProtected"] {
            try await repository.git(["config", key, "true"])
            try await plainGit(["fetch", "origin"])
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "\(key) control: plain git asks")
            try FileManager.default.removeItem(at: marker)

            try await appFetch()
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "\(key): the app's fetch does not ask")
            try await repository.git(["config", "--unset", key])
        }
    }

    /// SEC-T11-10: certificate files for the TLS connection to the proxy are the user's. A repository that sets its own
    /// (it could make git trust a CA it chose for that connection) gets no fetch at all, while plain git uses them.
    func testSECT11_10_RepositoryProxyCertificateFilesTurnFetchOff() async throws {
        let caFile = home.appendingPathComponent("evil-ca.pem")
        try "not a certificate\n".write(to: caFile, atomically: true, encoding: .utf8)
        try await plainGit([
            "config", "--file", home.appendingPathComponent(".gitconfig").path, "http.proxy", proxyURL,
        ])
        for key in [
            "http.proxySSLCAInfo", "http.proxySSLCert", "http.proxySSLKey", "http.\(remote.url("")).proxySSLCAInfo",
        ] {
            try await repository.git(["config", key, caFile.path])
            let viaProxy = proxy.requestCount
            try await plainGit(["-c", "credential.helper=", "fetch", "origin"])
            XCTAssertGreaterThan(proxy.requestCount, viaProxy, "\(key) control: plain git fetches with the setting")

            let before = proxy.requestCount + remote.requestCount
            try await appFetch()
            XCTAssertEqual(proxy.requestCount + remote.requestCount, before, "\(key): the app does not fetch")
            try await repository.git(["config", "--unset", key])
        }
    }

    // MARK: - SEC-T11-08

    /// A repository's cookie file (generic, and under a URL, which a generic override does not reach) is not read
    /// into the fetch.
    func testSECT11_08_RepositoryCookieFileIsNotSent() async throws {
        let file = try cookieFile()
        for key in ["http.cookieFile", "http.\(remote.url("")).cookieFile"] {
            try await repository.git(["config", key, file.path])

            let before = remote.requestHeads.count
            try await plainGit(["-c", "credential.helper=", "fetch", "origin"])
            XCTAssertGreaterThan(remote.requestHeads.count, before, "\(key) control: plain git reached the remote")
            XCTAssertTrue(
                remote.requestHeads[before...].contains { $0.contains("cookie-canary") },
                "\(key) control: plain git must send the cookie")

            let sent = remote.requestHeads.count
            try await appFetch()
            XCTAssertGreaterThan(remote.requestHeads.count, sent, "\(key): the app's fetch reached the remote")
            XCTAssertFalse(
                remote.requestHeads[sent...].contains { $0.contains("cookie-canary") },
                "\(key): the app's fetch must not send the repository's cookies")
            try await repository.git(["config", "--unset", key])
        }
    }

    /// SEC-T11-08: with `saveCookies`, git writes its cookie jar over the cookie file when it ends, so a repository
    /// could make fetch overwrite any file the user can write, partly with what the server sends. The app's fetch
    /// writes nothing there.
    func testSECT11_08_RepositoryCookieJarIsNeverWritten() async throws {
        let server = try await LocalHTTPAuthServer.start(response: .emptyWithCookie("jar-canary=from-server; Path=/"))
        defer { server.stop() }
        try await repository.git(["remote", "set-url", "origin", server.url()])
        let target = home.appendingPathComponent("target.txt")
        for key in ["http", "http.\(server.url(""))"] {
            try "ORIGINAL\n".write(to: target, atomically: true, encoding: .utf8)
            try await repository.git(["config", "\(key).cookieFile", target.path])
            try await repository.git(["config", "\(key).saveCookies", "true"])

            try await plainGit(["-c", "credential.helper=", "fetch", "origin"])
            let written = try String(contentsOf: target, encoding: .utf8)
            XCTAssertTrue(written.contains("jar-canary"), "\(key) control: plain git must overwrite the file")

            try "ORIGINAL\n".write(to: target, atomically: true, encoding: .utf8)
            let requests = server.requestCount
            try await appFetch()
            XCTAssertGreaterThan(server.requestCount, requests, "\(key): the app's fetch reached the server")
            XCTAssertEqual(
                try String(contentsOf: target, encoding: .utf8), "ORIGINAL\n", "\(key): the file is untouched")
            try await repository.git(["config", "--unset", "\(key).cookieFile"])
            try await repository.git(["config", "--unset", "\(key).saveCookies"])
        }
    }
}
