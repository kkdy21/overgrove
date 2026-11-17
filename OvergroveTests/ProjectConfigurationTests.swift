import AppKit
import XCTest

@testable import Overgrove

/// Guards the project settings required by docs/README.md §2.1 and issue #30.
final class ProjectConfigurationTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.github.kkdy21.overgrove")
    }

    func testMinimumSystemVersionIsMacOS14() {
        let minimum = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
        XCTAssertEqual(minimum, "14.0")
    }

    func testAppSandboxIsDisabled() {
        // The app reads repositories anywhere on disk (HANDOFF §4), so it must not run sandboxed.
        let containerPath = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
        XCTAssertNil(containerPath)
    }

    /// #687: Release builds carry no exception entitlement (architecture/overview.md §10). The tests run a Debug build,
    /// which keeps Xcode's `get-task-allow` for the debugger, so the settings that decide a Release build are read from
    /// the repository instead. Every committed xcconfig and the project are read (the git-ignored
    /// `Personal.xcconfig.local` is each developer's own), with conditions such as `[config=Release]` kept apart. The
    /// built app itself is checked with `codesign` in release-checklist.md §4.
    func testReleaseBuildsAddNoExceptionEntitlements() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let config = repo.appendingPathComponent("Config")
        let files = try FileManager.default.contentsOfDirectory(atPath: config.path)
            .filter { $0.hasSuffix(".xcconfig") }.sorted()
        XCTAssertTrue(files.contains("Overgrove.xcconfig"))
        /// Each assignment as (setting with its condition, value), in file order.
        var assignments: [(setting: String, value: String)] = []
        for name in files {
            let text = try String(contentsOf: config.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.components(separatedBy: "//")[0]
                // The setting ends at the first `=` outside a condition such as `[config=Release]`.
                var depth = 0
                guard
                    let equals = code.firstIndex(where: { character in
                        if character == "[" { depth += 1 } else if character == "]" { depth -= 1 }
                        return character == "=" && depth == 0
                    })
                else { continue }
                assignments.append(
                    (
                        code[..<equals].trimmingCharacters(in: .whitespaces),
                        code[code.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                    ))
            }
        }
        func values(_ base: String) -> [String] {
            assignments.filter { $0.setting.split(separator: "[").first.map(String.init) == base }
                .map { "\($0.setting) = \($0.value)" }
        }
        XCTAssertEqual(
            values("CODE_SIGN_INJECT_BASE_ENTITLEMENTS"),
            ["CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Debug] = YES"],
            "Xcode's base entitlements only in Debug")
        XCTAssertFalse(values("ENABLE_HARDENED_RUNTIME").isEmpty)
        XCTAssertEqual(Set(values("ENABLE_HARDENED_RUNTIME")), ["ENABLE_HARDENED_RUNTIME = YES"], "on, unconditionally")
        for base in ["CODE_SIGN_ENTITLEMENTS", "OTHER_CODE_SIGN_FLAGS"] {
            XCTAssertEqual(values(base), [], "no entitlements file and no extra codesign options")
        }
        XCTAssertFalse(assignments.contains { $0.setting.hasPrefix("RUNTIME_EXCEPTION_") }, "no runtime exceptions")
        let project = try String(
            contentsOf: repo.appendingPathComponent("Overgrove.xcodeproj/project.pbxproj"), encoding: .utf8)
        for key in [
            "CODE_SIGN_ENTITLEMENTS", "CODE_SIGN_INJECT_BASE_ENTITLEMENTS", "ENABLE_HARDENED_RUNTIME",
            "OTHER_CODE_SIGN_FLAGS", "RUNTIME_EXCEPTION_",
        ] {
            XCTAssertFalse(project.contains(key), "\(key): the xcconfigs decide signing, not the project")
        }
    }

    /// #38: the app icon comes from AppIcon.appiconset (scripts/render-app-icon.sh), and the mark is an asset (S-07).
    func testAppIconAndMarkAreInTheAssetCatalog() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        let mark = try XCTUnwrap(NSImage(named: "Mark"), "Mark.imageset")
        XCTAssertGreaterThan(mark.size.width, 0)
    }
}
