import Darwin
import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainMutationPhysicalCapabilityTests: XCTestCase {
    func testDescriptorCapabilityKeepsCreateInsideAdmittedParentAfterPathSwap() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let target = fixture.parent.appendingPathComponent("created.txt")
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [target.path],
            authorizedRoots: [fixture.root.path]
        )
        let capability = try DomainMutationPhysicalCapability.open(snapshot: snapshot)

        try FileManager.default.moveItem(at: fixture.parent, to: fixture.heldParent)
        try FileManager.default.createSymbolicLink(
            at: fixture.parent,
            withDestinationURL: fixture.outside
        )

        try capability.writeFile(
            at: target.path,
            data: Data("inside".utf8),
            overwrite: false,
            expectedContentDigest: nil,
            requireExisting: false
        )

        XCTAssertEqual(
            try String(contentsOf: fixture.heldParent.appendingPathComponent("created.txt"), encoding: .utf8),
            "inside"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("created.txt").path))
    }

    func testDescriptorCapabilityProvidesPositiveNoReplaceMove() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let source = fixture.parent.appendingPathComponent("source.txt")
        let destination = fixture.parent.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)

        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [source.path, destination.path],
            authorizedRoots: [fixture.root.path]
        )
        let capability = try DomainMutationPhysicalCapability.open(snapshot: snapshot)

        try capability.validateNoReplaceMove(from: source.path, to: destination.path)
        try capability.moveFile(from: source.path, to: destination.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "source"
        )
    }

    func testDeniedNoReplaceMoveHasNoSideEffect() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let source = fixture.parent.appendingPathComponent("source.txt")
        let destination = fixture.parent.appendingPathComponent("destination.txt")
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)

        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [source.path, destination.path],
            authorizedRoots: [fixture.root.path]
        )
        let capability = try DomainMutationPhysicalCapability.open(snapshot: snapshot)

        XCTAssertThrowsError(
            try capability.validateNoReplaceMove(from: source.path, to: destination.path)
        ) { error in
            XCTAssertEqual(
                error as? DomainMutationPhysicalCapabilityError,
                .destinationExists(destination.path)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(contentsOf: source, encoding: .utf8),
            "source"
        )
        XCTAssertEqual(
            try String(contentsOf: destination, encoding: .utf8),
            "existing"
        )
    }

    func testDescriptorCapabilityPreservesExecutableModeOnAtomicOverwrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let target = fixture.parent.appendingPathComponent("executable.sh")
        try Data("#!/bin/sh\necho before\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [target.path],
            authorizedRoots: [fixture.root.path]
        )
        let capability = try DomainMutationPhysicalCapability.open(snapshot: snapshot)

        try capability.validateWriteTarget(
            at: target.path,
            overwrite: true,
            expectedContentDigest: DomainContentDigest.sha256(Data("#!/bin/sh\necho before\n".utf8)),
            requireExisting: true
        )
        try capability.writeFile(
            at: target.path,
            data: Data("#!/bin/sh\necho after\n".utf8),
            overwrite: true,
            expectedContentDigest: DomainContentDigest.sha256(Data("#!/bin/sh\necho before\n".utf8)),
            requireExisting: true
        )

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "#!/bin/sh\necho after\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".rpce-mutation-") })
    }

    func testDescriptorCapabilityDeniesFIFOWithoutBlocking() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let target = fixture.parent.appendingPathComponent("named-pipe")
        XCTAssertEqual(mkfifo(target.path, 0o644), 0)
        let snapshot = try await DomainMutationPathFence.admit(
            requestedPaths: [target.path],
            authorizedRoots: [fixture.root.path]
        )
        let capability = try DomainMutationPhysicalCapability.open(snapshot: snapshot)

        XCTAssertThrowsError(
            try capability.validateWriteTarget(
                at: target.path,
                overwrite: true,
                expectedContentDigest: DomainContentDigest.sha256(Data()),
                requireExisting: true
            )
        ) { error in
            XCTAssertEqual(
                error as? DomainMutationPhysicalCapabilityError,
                .notRegularFile(target.path)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
}

private struct Fixture {
    let container: URL
    let root: URL
    let parent: URL
    let heldParent: URL
    let outside: URL

    init() throws {
        let fileManager = FileManager.default
        container = fileManager.temporaryDirectory
            .appendingPathComponent("domain-mutation-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("authorized-root", isDirectory: true)
        parent = root.appendingPathComponent("parent", isDirectory: true)
        heldParent = root.appendingPathComponent("held-parent", isDirectory: true)
        outside = container.appendingPathComponent("outside", isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: container)
    }
}
