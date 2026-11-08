import Darwin
import Foundation

/// Keeps one `LaunchSnapshot` per repository in `~/Library/Caches/<bundle id>/LaunchSnapshots/` (ADR-0018 §3–§6,
/// #109, T19).
///
/// Every read treats the file as untrusted input (§4) and every failure removes it: a snapshot is a convenience, so
/// the answer to anything odd is to draw nothing and let the first load run as it would have.
final class LaunchSnapshotStore: Sendable {
    let directory: URL
    /// `CFBundleShortVersionString (CFBundleVersion)`; a snapshot from another build is not shown.
    let appVersion: String

    init(directory: URL, appVersion: String) {
        self.directory = directory
        self.appVersion = appVersion
    }

    /// The app's store. `nil` when the caches directory cannot be found, and when the app is only the host of a unit
    /// test run: the tests must not write snapshots of the developer's registered repositories.
    static let live: LaunchSnapshotStore? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else {
            return nil
        }
        let bundle = Bundle.main.bundleIdentifier ?? "io.github.kkdy21.overgrove"
        let info = Bundle.main.infoDictionary
        let version =
            "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
        return LaunchSnapshotStore(
            directory: caches.appendingPathComponent(bundle, isDirectory: true)
                .appendingPathComponent("LaunchSnapshots", isDirectory: true),
            appVersion: version)
    }()

    func file(for repository: Repository) -> URL {
        directory.appendingPathComponent(LaunchSnapshot.hash(repository) + ".json")
    }

    // MARK: Reading

    /// The repository's snapshot when it is still current (§3), else `nil` (and the file is gone).
    func load(for repository: Repository, now: Date = Date()) -> LaunchSnapshot? {
        switch check(for: repository, now: now) {
        case .success(let snapshot):
            return snapshot
        case .failure:
            // Removing a file that is not there is harmless; a link is removed, never followed.
            delete(for: repository)
            return nil
        }
    }

    /// `load` without removing anything: what was wrong, for tests and the log.
    func check(for repository: Repository, now: Date = Date()) -> Result<LaunchSnapshot, LaunchSnapshot.Rejection> {
        let snapshot: LaunchSnapshot
        do throws(LaunchSnapshot.Rejection) {
            snapshot = try LaunchSnapshot.decode(try read(file(for: repository)))
        } catch {
            return .failure(error)
        }
        guard snapshot.appVersion == appVersion else { return .failure(.otherVersion) }
        guard snapshot.repositoryHash == LaunchSnapshot.hash(repository) else { return .failure(.otherRepository) }
        let age = now.timeIntervalSince(snapshot.writtenAt)
        // A date ahead of now (clock moved back, or a forged file) is not current either.
        guard age >= -60, age <= LaunchSnapshot.maximumAge else { return .failure(.expired) }
        let git = LaunchSnapshot.FileStamp.of(snapshot.gitExecutable, name: snapshot.gitExecutable)
        guard git.exists, git == snapshot.gitExecutableStamp else { return .failure(.gitChanged) }
        guard let current = LaunchSnapshot.fingerprint(repository.commonGitDirectoryURL),
            current == snapshot.fingerprint
        else {
            return .failure(.repositoryChanged)
        }
        return .success(snapshot)
    }

    /// A regular file (a link is refused, not followed) of at most `LaunchSnapshot.maximumBytes`.
    private func read(_ url: URL) throws(LaunchSnapshot.Rejection) -> Data {
        // Non-blocking, so a FIFO in its place cannot hold the launch; checked to be a regular file of ours first.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw .unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw .unreadable
        }
        guard info.st_size <= LaunchSnapshot.maximumBytes else { throw .tooLarge }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: LaunchSnapshot.maximumBytes + 1) else { return Data() }
        guard data.count <= LaunchSnapshot.maximumBytes else { throw .tooLarge }
        return data
    }

    // MARK: Writing

    /// Writes atomically into a `0700` directory as a `0600` file. Failures are ignored: the next launch simply has
    /// no snapshot.
    func save(_ snapshot: LaunchSnapshot, for repository: Repository) {
        guard snapshot.repositoryHash == LaunchSnapshot.hash(repository), prepareDirectory(),
            let data = try? JSONEncoder().encode(snapshot), data.count <= LaunchSnapshot.maximumBytes
        else { return }
        let target = file(for: repository)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        // Created as 0600 from the start, never through a link, never over an existing file.
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { buffer in write(descriptor, buffer.baseAddress, buffer.count) }
        close(descriptor)
        guard written == data.count, rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            return
        }
    }

    /// Leftovers: temporary files of an interrupted write, and snapshots past `LaunchSnapshot.maximumAge` (a
    /// repository not opened again). At most `maximumCleanup` entries are looked at per call.
    func removeLeftovers(now: Date = Date()) {
        guard let directory = opendir(self.directory.path) else { return }
        defer { closedir(directory) }
        var looked = 0
        while looked < Self.maximumCleanup, let entry = readdir(directory) {
            looked += 1
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            let path = self.directory.appendingPathComponent(name).path
            var info = stat()
            guard name != ".", name != "..", lstat(path, &info) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            let isTemporary = name.hasPrefix(".") && name.hasSuffix(".tmp")
            let isOld = name.hasSuffix(".json") && now.timeIntervalSince(modified) > LaunchSnapshot.maximumAge
            if isTemporary || isOld { unlink(path) }
        }
    }

    static let maximumCleanup = 1_024

    func delete(for repository: Repository) {
        unlink(file(for: repository).path)
    }

    /// The directory exists as a real directory (not a link) with mode `0700`.
    private func prepareDirectory() -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                return false
            }
            guard lstat(directory.path, &info) == 0 else { return false }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        return info.st_mode & 0o777 == 0o700 || chmod(directory.path, 0o700) == 0
    }
}
