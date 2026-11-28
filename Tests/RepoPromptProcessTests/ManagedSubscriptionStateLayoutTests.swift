import Foundation
import RepoPromptProcess
import XCTest

final class ManagedSubscriptionStateLayoutTests: XCTestCase {
    func testEveryProviderProfileChannelAndAppRootHasDistinctLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = UUID()
        let profileB = UUID()
        var paths: Set<URL> = []
        for name in ["normal-profile", "test-profile"] {
            let appRoot = root.appendingPathComponent(name, isDirectory: true)
            for channel: ManagedSubscriptionStateLayout.BuildChannel in [.debug, .release] {
                let layout = try XCTUnwrap(ManagedSubscriptionStateLayout(applicationProfileRoot: appRoot, channel: channel))
                for id in [profileA, profileB] {
                    let codex = layout.codex(profileID: id)
                    XCTAssertEqual(layout.codex(profileID: id), codex)
                    for path in [codex.codexHome, codex.sqliteHome, layout.claudeCodeConfigDirectory(profileID: id)] {
                        XCTAssertTrue(path.pathComponents.starts(with: appRoot.standardizedFileURL.pathComponents))
                        XCTAssertTrue(path.pathComponents.contains(id.uuidString.lowercased()))
                        XCTAssertTrue(paths.insert(path).inserted)
                    }
                }
            }
        }
        XCTAssertEqual(paths.count, 24)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRejectsNonFileAndRelativeRoots() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/profile"))
        XCTAssertNil(ManagedSubscriptionStateLayout(applicationProfileRoot: remote, channel: .release))
        let base = URL(fileURLWithPath: "/fixture", isDirectory: true)
        let relative = URL(fileURLWithPath: "profile", isDirectory: true, relativeTo: base)
        XCTAssertNil(ManagedSubscriptionStateLayout(applicationProfileRoot: relative, channel: .debug))
    }
}
