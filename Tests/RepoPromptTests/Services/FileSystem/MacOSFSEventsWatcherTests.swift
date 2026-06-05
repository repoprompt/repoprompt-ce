import CoreFoundation
import CoreServices
import Foundation
@testable import RepoPrompt
import XCTest

final class MacOSFSEventsWatcherTests: XCTestCase {
    func testSemanticFlagsMapsNativeMutationAndTypeBits() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemIsFile
        )

        XCTAssertEqual(
            MacOSFSEventsWatcher.semanticFlags(for: rawFlags),
            [.itemCreated, .contentChanged, .itemIsFile]
        )
    }

    func testSemanticFlagsCollapsesNativeReliabilityBits() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagRootChanged
        )

        XCTAssertEqual(
            MacOSFSEventsWatcher.semanticFlags(for: rawFlags),
            [.mustScanSubdirectories, .droppedEvents, .rootChanged]
        )
    }

    func testBuildOwnedPayloadDeepCopiesMutablePathStorage() throws {
        let mutablePath = NSMutableString(string: "/tmp/original.swift")
        let payload = try XCTUnwrap(ownedPayload(
            paths: [mutablePath] as CFArray,
            flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)],
            eventIDs: [7]
        ))

        mutablePath.setString("/tmp/mutated.swift")

        XCTAssertEqual(payload.entries, [
            FileSystemWatchEvent(path: "/tmp/original.swift", flags: [.contentChanged], id: 7)
        ])
    }

    func testBuildOwnedPayloadRetainsTemporaryPathAfterCallbackStorageLifetime() throws {
        let payload = try XCTUnwrap(autoreleasepool { () -> FileSystemWatchEventPayload? in
            let temporaryPath = NSMutableString(string: "/tmp/temporary.swift")
            return ownedPayload(
                paths: [temporaryPath] as CFArray,
                flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)],
                eventIDs: [8]
            )
        })

        XCTAssertEqual(payload.entries, [
            FileSystemWatchEvent(path: "/tmp/temporary.swift", flags: [.itemCreated], id: 8)
        ])
    }

    func testSemanticFlagsCollapsesNativeMetadataBits() {
        let rawFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemFinderInfoMod
                | kFSEventStreamEventFlagItemChangeOwner
        )

        XCTAssertEqual(MacOSFSEventsWatcher.semanticFlags(for: rawFlags), [.metadataChanged])
    }

    private func ownedPayload(
        paths: CFArray,
        flags: [FSEventStreamEventFlags],
        eventIDs: [FSEventStreamEventId]
    ) -> FileSystemWatchEventPayload? {
        flags.withUnsafeBufferPointer { flagsBuffer in
            eventIDs.withUnsafeBufferPointer { eventIDsBuffer in
                guard let flagsBaseAddress = flagsBuffer.baseAddress,
                      let eventIDsBaseAddress = eventIDsBuffer.baseAddress
                else { return nil }
                return MacOSFSEventsWatcher.buildOwnedPayload(
                    numEvents: flags.count,
                    eventPaths: Unmanaged.passUnretained(paths).toOpaque(),
                    eventFlags: flagsBaseAddress,
                    eventIDs: eventIDsBaseAddress
                )
            }
        }
    }
}
