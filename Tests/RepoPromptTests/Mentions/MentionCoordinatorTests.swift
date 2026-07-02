import AppKit
@testable import RepoPrompt
import SwiftUI
import XCTest

@MainActor
final class MentionCoordinatorTests: XCTestCase {
    func testWorkspaceReuseKeepsSuggestionsAndCommitRemovalOnNewFileManager() {
        let first = makeFixture(rootName: "FirstWorkspace")
        let second = makeFixture(rootName: "SecondWorkspace")
        var text = ""
        let view = AttributedTextKitView(
            text: Binding(
                get: { text },
                set: { text = $0 }
            ),
            fileManager: first.fileManager
        )
        let attributedCoordinator = AttributedTextKitView.Coordinator(view)
        let textView = MentionTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let mentionCoordinator = MentionCoordinator(
            textView: textView,
            suggestionService: MentionSuggestionService(fileManager: first.fileManager),
            commitHandler: { _ in },
            tokenRemovedHandler: { _ in }
        )
        attributedCoordinator.mentionCoord = mentionCoordinator

        attributedCoordinator.updateFileManager(second.fileManager)
        mentionCoordinator.mentionStarted(at: .zero)

        XCTAssertTrue(mentionCoordinator.testSuggestions.contains { $0.displayName == "SecondWorkspace" })
        XCTAssertFalse(mentionCoordinator.testSuggestions.contains { $0.displayName == "FirstWorkspace" })

        let suggestion = MentionSuggestion(
            displayName: second.file.name,
            relativePath: second.file.relativePath,
            kind: .file
        )
        attributedCoordinator.commit(suggestion)

        XCTAssertTrue(second.file.isChecked)
        XCTAssertFalse(first.file.isChecked)

        attributedCoordinator.tokenRemoved(
            MentionTokenPayload(relativePath: suggestion.relativePath, kind: .file)
        )

        XCTAssertFalse(second.file.isChecked)
    }

    func testClickingAncestorWindowMakesThatLevelCurrentForFurtherNavigation() throws {
        let fixture = makeFixture(rootName: "ClickedWorkspace")
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        defer { owner.orderOut(nil) }
        let contentView = NSView(frame: owner.contentView?.bounds ?? .zero)
        let textView = MentionTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 80))
        contentView.addSubview(textView)
        owner.contentView = contentView
        var committed: MentionSuggestion?
        let coordinator = MentionCoordinator(
            textView: textView,
            suggestionService: MentionSuggestionService(fileManager: fixture.fileManager),
            commitHandler: { committed = $0 },
            tokenRemovedHandler: { _ in }
        )

        coordinator.mentionStarted(at: NSRect(x: 100, y: 100, width: 1, height: 18))
        coordinator.mentionNavigate(.down)
        coordinator.mentionNavigate(.right)
        XCTAssertTrue(coordinator.testFlushPendingDebouncedQuery())
        XCTAssertEqual(coordinator.testOverlayWindowCount, 2)
        XCTAssertFalse(coordinator.testSuggestions(atLevel: 1).isEmpty)
        coordinator.mentionNavigate(.right)
        XCTAssertTrue(coordinator.testFlushPendingDebouncedQuery())
        XCTAssertEqual(coordinator.testOverlayWindowCount, 3)
        XCTAssertFalse(coordinator.testSuggestions(atLevel: 2).isEmpty)

        let ancestorSuggestions = coordinator.testSuggestions(atLevel: 1)
        let previousHighlight = try XCTUnwrap(coordinator.testHighlightedIndex(atLevel: 1))
        let clickedIndex = try XCTUnwrap(
            ancestorSuggestions.indices.first {
                $0 != previousHighlight && ancestorSuggestions[$0].kind == .folder
            }
        )
        let clickedFolder = ancestorSuggestions[clickedIndex]

        coordinator.testClickOverlayRow(level: 1, index: clickedIndex)

        XCTAssertEqual(coordinator.testOverlayWindowCount, 2)
        coordinator.mentionNavigate(.right)
        XCTAssertTrue(coordinator.testFlushPendingDebouncedQuery())
        XCTAssertEqual(coordinator.testOverlayWindowCount, 3)
        XCTAssertFalse(coordinator.testSuggestions(atLevel: 2).isEmpty)

        coordinator.mentionAccept()
        let expectedFileName = clickedFolder.displayName == "Sources"
            ? fixture.file.name
            : fixture.alternateFile.name
        XCTAssertEqual(committed?.displayName, expectedFileName)
    }

    func testDeallocatedManagerUpdatingToNilInvalidatesActiveMentionState() {
        var manager: WorkspaceFilesViewModel? = makeFixture(rootName: "ReleasedWorkspace").fileManager
        let textView = MentionTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let coordinator = MentionCoordinator(
            textView: textView,
            suggestionService: MentionSuggestionService(fileManager: manager),
            commitHandler: { _ in },
            tokenRemovedHandler: { _ in }
        )

        coordinator.mentionStarted(at: .zero)
        XCTAssertFalse(coordinator.testSuggestions.isEmpty)
        coordinator.mentionQueryChanged("Released", parent: nil)
        manager = nil

        coordinator.updateFileManager(nil)
        XCTAssertTrue(coordinator.testFlushPendingDebouncedQuery())
        XCTAssertTrue(coordinator.testSuggestions.isEmpty)
    }

    func testWorkspaceSwitchInvalidatesStaleDebouncedQuery() {
        let first = makeFixture(rootName: "FirstWorkspace")
        let second = makeFixture(rootName: "SecondWorkspace", fileName: "SecondOnly.swift")
        let textView = MentionTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let coordinator = MentionCoordinator(
            textView: textView,
            suggestionService: MentionSuggestionService(fileManager: first.fileManager),
            commitHandler: { _ in },
            tokenRemovedHandler: { _ in }
        )

        coordinator.mentionStarted(at: .zero)
        coordinator.mentionQueryChanged("SecondOnly", parent: nil)
        coordinator.updateFileManager(second.fileManager)
        XCTAssertTrue(coordinator.testFlushPendingDebouncedQuery())
        XCTAssertTrue(coordinator.testSuggestions.isEmpty)
    }

    private func makeFixture(
        rootName: String,
        fileName: String = "Shared.swift"
    ) -> (fileManager: WorkspaceFilesViewModel, file: FileViewModel, alternateFile: FileViewModel) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MentionCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let alternateURL = rootURL.appendingPathComponent("Alternate", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1000)
        let root = FolderViewModel(
            folder: Folder(name: rootName, path: rootURL.path, modificationDate: date),
            rootPath: rootURL.path,
            isExpanded: true
        )
        let sources = FolderViewModel(
            folder: Folder(name: "Sources", path: sourceURL.path, modificationDate: date),
            rootPath: rootURL.path,
            hierarchyLevel: 1,
            isExpanded: true
        )
        let file = FileViewModel(
            file: File(name: fileName, path: sourceURL.appendingPathComponent(fileName).path, modificationDate: date),
            rootPath: rootURL.path,
            hierarchyLevel: 2,
            rootIdentifier: root.id,
            rootFolderPath: rootURL.path,
            fileSystemService: nil,
            parentFolder: sources
        )
        let alternateFolder = FolderViewModel(
            folder: Folder(name: "Alternate", path: alternateURL.path, modificationDate: date),
            rootPath: rootURL.path,
            hierarchyLevel: 1,
            isExpanded: true
        )
        let alternateFile = FileViewModel(
            file: File(
                name: "Alternate.swift",
                path: alternateURL.appendingPathComponent("Alternate.swift").path,
                modificationDate: date
            ),
            rootPath: rootURL.path,
            hierarchyLevel: 2,
            rootIdentifier: root.id,
            rootFolderPath: rootURL.path,
            fileSystemService: nil,
            parentFolder: alternateFolder
        )
        sources.addChildrenBatch([.file(file)])
        alternateFolder.addChildrenBatch([.file(alternateFile)])
        root.addChildrenBatch([.folder(sources), .folder(alternateFolder)])

        let fileManager = WorkspaceFilesViewModel()
        fileManager.registerRootFolderForTesting(root)
        return (fileManager, file, alternateFile)
    }
}
