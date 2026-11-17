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
    /// the repository instead: Xcode's base entitlements stay out of Release, and no entitlements file adds others.
    func testReleaseBuildsAddNoExceptionEntitlements() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func settings(_ name: String) throws -> [String: String] {
            let text = try String(contentsOf: repo.appendingPathComponent("Config/\(name)"), encoding: .utf8)
            var values: [String: String] = [:]
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
                values[code[..<equals].trimmingCharacters(in: .whitespaces)] =
                    code[code.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
            return values
        }
        let app = try settings("Overgrove.xcconfig")
        XCTAssertEqual(app["ENABLE_HARDENED_RUNTIME"], "YES")
        XCTAssertEqual(app["CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Release]"], "NO")
        XCTAssertNil(app["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"], "Debug keeps Xcode's default for the debugger")
        for name in ["Base.xcconfig", "Overgrove.xcconfig"] {
            let keys = try settings(name).keys
            XCTAssertFalse(keys.contains { $0.hasPrefix("CODE_SIGN_ENTITLEMENTS") }, "\(name): no entitlements file")
        }
        let project = try String(
            contentsOf: repo.appendingPathComponent("Overgrove.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertFalse(project.contains("CODE_SIGN_ENTITLEMENTS"), "no entitlements file in the project")
        XCTAssertFalse(project.contains("CODE_SIGN_INJECT_BASE_ENTITLEMENTS"), "the xcconfig decides it")
    }

    /// #38: the app icon comes from AppIcon.appiconset (scripts/render-app-icon.sh), and the mark is an asset (S-07).
    func testAppIconAndMarkAreInTheAssetCatalog() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        let mark = try XCTUnwrap(NSImage(named: "Mark"), "Mark.imageset")
        XCTAssertGreaterThan(mark.size.width, 0)
    }
}
