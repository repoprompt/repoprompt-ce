import RepoPromptRuntimeModel
@testable import RepoPromptWorkspaceRuntimeCore
import XCTest

final class WorkspaceRuntimeTests: XCTestCase {
    func testSameResourceIDIsIsolatedByOwner() async throws {
        let runtime = WorkspaceRuntime()
        let ownerA = RuntimeOwnerID(rawValue: "a")
        let ownerB = RuntimeOwnerID(rawValue: "b")
        let resource = RuntimeResourceID(rawValue: "repository")
        try await runtime.registerOwner(ownerA)
        try await runtime.registerOwner(ownerB)
        let referenceA = try await runtime.attach(resource, to: ownerA)
        let referenceB = try await runtime.attach(resource, to: ownerB)

        _ = try await runtime.authorize(referenceA, requestedBy: ownerA)
        _ = try await runtime.authorize(referenceB, requestedBy: ownerB)
        await XCTAssertThrowsErrorAsync {
            _ = try await runtime.authorize(referenceA, requestedBy: ownerB)
        }
    }

    func testDetachAndReattachInvalidatesOldGrant() async throws {
        let runtime = WorkspaceRuntime()
        let owner = RuntimeOwnerID(rawValue: "owner")
        try await runtime.registerOwner(owner)
        let reference = try await runtime.attach(RuntimeResourceID(rawValue: "resource"), to: owner)
        let firstGrant = try await runtime.authorize(reference, requestedBy: owner)
        try await runtime.detach(reference, requestedBy: owner)
        _ = try await runtime.attach(reference.resourceID, to: owner)

        await XCTAssertThrowsErrorAsync {
            try await runtime.validate(firstGrant, requestedBy: owner)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
