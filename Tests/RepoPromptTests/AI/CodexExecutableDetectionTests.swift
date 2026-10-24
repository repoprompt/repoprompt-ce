import AppKit
import Darwin
import Foundation
import RepoPromptApp
import RepoPromptProcess
import XCTest

final class CodexExecutableDetectionTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExecutableDetectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testDetectExecutablesDeduplicatesSymlinks() throws {
        let binA = try makeDirectory("binA")
        let binB = try makeDirectory("binB")
        let realExecutable = try makeExecutable(in: binA)
        let link = binB.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: realExecutable.path)

        let detected = CLIExecutableDiscovery.detectExecutables(
            named: "codex",
            inDirectories: [binA.path, binB.path]
        )

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.path, realExecutable.path)
        XCTAssertEqual(detected.first?.resolvedPath, CLIExecutableDiscovery.resolvedRealPath(realExecutable.path))

        // The link still wins when it sorts first: dedupe keeps the first resolved hit.
        let linkFirst = CLIExecutableDiscovery.detectExecutables(
            named: "codex",
            inDirectories: [binB.path, binA.path]
        )
        XCTAssertEqual(linkFirst.count, 1)
        XCTAssertEqual(linkFirst.first?.path, link.path)
        XCTAssertEqual(linkFirst.first?.resolvedPath, detected.first?.resolvedPath)
    }

    func testDetectExecutablesSkipsNonExecutableMissingAndDirectories() throws {
        let nonExecutableBin = try makeDirectory("nonexec")
        let plainFile = nonExecutableBin.appendingPathComponent("codex")
        FileManager.default.createFile(atPath: plainFile.path, contents: Data("nope".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plainFile.path)

        let containerBin = try makeDirectory("container")
        try FileManager.default.createDirectory(
            at: containerBin.appendingPathComponent("codex", isDirectory: true),
            withIntermediateDirectories: true
        )

        let missingBin = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)

        let detected = CLIExecutableDiscovery.detectExecutables(
            named: "codex",
            inDirectories: [nonExecutableBin.path, containerBin.path, missingBin.path]
        )

        XCTAssertTrue(detected.isEmpty)
    }

    func testDetectExecutablesSkipsSpecialFiles() throws {
        let bin = try makeDirectory("fifo-bin")
        let fifo = bin.appendingPathComponent("codex")
        XCTAssertEqual(mkfifo(fifo.path, 0o755), 0)

        // The fifo satisfies exists + executable but is not a regular file.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: fifo.path))
        let detected = CLIExecutableDiscovery.detectExecutables(
            named: "codex",
            inDirectories: [bin.path]
        )

        XCTAssertTrue(detected.isEmpty)
    }

    func testDetectExecutablesAbsolutizesRelativeSearchDirectories() throws {
        let bin = try makeDirectory("relative-bin")
        let executable = try makeExecutable(in: bin)

        let detected = CLIExecutableDiscovery.detectExecutables(
            named: "codex",
            inDirectories: ["relative-bin", "./relative-bin"],
            baseDirectoryPath: temporaryDirectory.path
        )

        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(detected.first?.path, executable.path)
        XCTAssertEqual(detected.first?.directory, bin.path)
        XCTAssertTrue((detected.first?.path as NSString?)?.isAbsolutePath == true)
    }

    func testDetectExcludesBundledRuntimePath() throws {
        let bundledBin = try makeDirectory("bundled-bin")
        let bundledExecutable = try makeExecutable(in: bundledBin)
        let userBin = try makeDirectory("user-bin")
        let userExecutable = try makeExecutable(in: userBin)
        let environment = ["PATH": "\(bundledBin.path):\(userBin.path)"]

        let detected = CodexExecutableDetection.detect(
            environment: environment,
            bundledExecutablePath: bundledExecutable.path
        )

        let bundledResolved = CLIExecutableDiscovery.resolvedRealPath(bundledExecutable.path)
        XCTAssertFalse(detected.contains { $0.resolvedPath == bundledResolved })
        XCTAssertTrue(detected.contains { $0.path == userExecutable.path })
    }

    func testCodexSearchDirectoriesMergesPathComponentsAndFixedFolders() {
        let environment = [
            "PATH": "/custom/bin:/opt/homebrew/bin:~/.local/bin",
            "HOME": "/fakehome"
        ]

        let directories = CLIExecutableDiscovery.codexSearchDirectories(environment: environment)

        XCTAssertEqual(directories.prefix(3), ["/custom/bin", "/opt/homebrew/bin", "/fakehome/.local/bin"])
        // PATH components already covering fixed roots are not repeated.
        XCTAssertEqual(directories.count(where: { $0 == "/opt/homebrew/bin" }), 1)
        XCTAssertEqual(directories.count(where: { $0 == "/fakehome/.local/bin" }), 1)
        XCTAssertTrue(directories.contains("/usr/local/bin"))
        // Node package manager bins expand against the supplied HOME.
        XCTAssertTrue(directories.contains("/fakehome/.npm-global/bin"))
    }

    func testMenuMapsDetectedAndCustomSelections() throws {
        let binA = try makeDirectory("menu-binA")
        let binB = try makeDirectory("menu-binB")
        let realExecutable = try makeExecutable(in: binA)
        let link = binB.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: realExecutable.path)

        let detected = [
            CLIExecutableDiscovery.DetectedExecutable(
                path: link.path,
                resolvedPath: CLIExecutableDiscovery.resolvedRealPath(link.path),
                directory: binB.path
            )
        ]

        // A selection pointing at the resolved target still matches the detected link item.
        XCTAssertTrue(
            CodexExecutableDetection.isSelected(externalPath: realExecutable.path, detected: detected[0])
        )
        XCTAssertTrue(
            CodexExecutableDetection.isSelected(externalPath: link.path, detected: detected[0])
        )
        XCTAssertFalse(CodexExecutableDetection.isSelected(externalPath: nil, detected: detected[0]))
        XCTAssertFalse(
            CodexExecutableDetection.isSelected(externalPath: "/elsewhere/codex", detected: detected[0])
        )

        // A detected pending path needs no extra custom menu item, either by found path or real path.
        XCTAssertNil(
            CodexExecutableDetection.undetectedCustomPath(pendingExternalPath: link.path, detected: detected)
        )
        XCTAssertNil(
            CodexExecutableDetection.undetectedCustomPath(pendingExternalPath: realExecutable.path, detected: detected)
        )

        // A custom path outside the detected set keeps its own item; a bundled (nil) selection never does.
        let customPath = temporaryDirectory.appendingPathComponent("elsewhere/codex").path
        XCTAssertEqual(
            CodexExecutableDetection.undetectedCustomPath(pendingExternalPath: customPath, detected: detected),
            customPath
        )
        XCTAssertNil(CodexExecutableDetection.undetectedCustomPath(pendingExternalPath: nil, detected: detected))
        XCTAssertNil(CodexExecutableDetection.undetectedCustomPath(pendingExternalPath: nil, detected: []))
    }

    func testMenuItemTitleAbbreviatesHome() {
        XCTAssertEqual(
            CodexExecutableDetection.abbreviatedPath("/home/user/.local/bin/codex", homePath: "/home/user"),
            "~/.local/bin/codex"
        )
        XCTAssertEqual(
            CodexExecutableDetection.abbreviatedPath("/opt/homebrew/bin/codex", homePath: "/home/user"),
            "/opt/homebrew/bin/codex"
        )
        XCTAssertEqual(
            CodexExecutableDetection.abbreviatedPath("/home/user", homePath: "/home/user"),
            "~"
        )
    }

    func testFilePanelStartDirectoryPrefersDetectedThenLocalBinThenPending() throws {
        let detectedBin = try makeDirectory("panel-detected")
        let localBin = try makeDirectory("panel-local-bin")
        let detected = [
            CLIExecutableDiscovery.DetectedExecutable(
                path: detectedBin.appendingPathComponent("codex").path,
                resolvedPath: detectedBin.appendingPathComponent("codex").path,
                directory: detectedBin.path
            )
        ]

        XCTAssertEqual(
            CodexExecutableDetection.filePanelStartDirectory(
                detected: detected,
                pendingExternalPath: nil,
                localBinPath: localBin.path
            ),
            URL(fileURLWithPath: detectedBin.path, isDirectory: true)
        )

        // No detection result: fall back to ~/.local/bin when it exists.
        XCTAssertEqual(
            CodexExecutableDetection.filePanelStartDirectory(
                detected: [],
                pendingExternalPath: nil,
                localBinPath: localBin.path
            ),
            URL(fileURLWithPath: localBin.path, isDirectory: true)
        )

        // Without detection or ~/.local/bin, keep the previous pending-path folder behavior.
        let pendingBin = try makeDirectory("panel-pending")
        let pendingPath = pendingBin.appendingPathComponent("codex").path
        XCTAssertEqual(
            CodexExecutableDetection.filePanelStartDirectory(
                detected: [],
                pendingExternalPath: pendingPath,
                localBinPath: temporaryDirectory.appendingPathComponent("no-local-bin").path
            ),
            URL(fileURLWithPath: pendingBin.path, isDirectory: true)
        )

        XCTAssertNil(
            CodexExecutableDetection.filePanelStartDirectory(
                detected: [],
                pendingExternalPath: nil,
                localBinPath: temporaryDirectory.appendingPathComponent("no-local-bin").path
            )
        )
    }

    @MainActor
    func testConfigureExecutablePanelShowsHiddenFilesAndStartDirectory() throws {
        let detectedBin = try makeDirectory("configure-detected")
        let detected = [
            CLIExecutableDiscovery.DetectedExecutable(
                path: detectedBin.appendingPathComponent("codex").path,
                resolvedPath: detectedBin.appendingPathComponent("codex").path,
                directory: detectedBin.path
            )
        ]

        let panel = NSOpenPanel()
        CodexExecutableDetection.configureExecutablePanel(
            panel,
            detected: detected,
            pendingExternalPath: nil
        )

        XCTAssertTrue(panel.showsHiddenFiles)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(panel.directoryURL, URL(fileURLWithPath: detectedBin.path, isDirectory: true))
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("codex")
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
