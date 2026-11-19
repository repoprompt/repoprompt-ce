import Foundation
import XCTest

final class BundleIdentityDefaultsStartupTests: XCTestCase {
    func testMigrationPersistsBeforeStartupCanReadItAndSurvivesAbruptExit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("StartupFixture.app/Contents")
        let executable = app.appendingPathComponent("MacOS/StartupFixture")
        let domain = "com.repoprompt.ce.tests.defaults.\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": domain,
            "CFBundleExecutable": "StartupFixture",
            "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try info.write(to: app.appendingPathComponent("Info.plist"))

        let main = root.appendingPathComponent("main.swift")
        try Self.fixture.write(to: main, atomically: true, encoding: .utf8)
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RepoPromptSecureStorage")
        let migrationSources = [
            "BundleIdentityDefaultsMigration.swift", "RuntimeCodeSigningPolicy.swift",
            "RuntimeCodeSigningDetector.swift", "LocalSigningIdentityRegistry.swift"
        ]
        try run(URL(fileURLWithPath: "/usr/bin/swiftc"), [
            "-package-name", "RepoPromptCE", "-module-cache-path", root.appendingPathComponent("cache").path,
            "-o", executable.path, main.path
        ] + migrationSources.map { sources.appendingPathComponent($0).path })

        defer { try? run(executable, ["cleanup", domain]) }
        try run(executable, ["seed", domain])
        try run(executable, ["migrate", domain])
        try run(executable, ["restart", domain])
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let diagnostics = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [
                NSLocalizedDescriptionKey: String(decoding: diagnostics, as: UTF8.self)
            ])
        }
    }

    private static let fixture = #"""
    import CoreFoundation
    import Darwin
    import Foundation

    let successor = CommandLine.arguments[2]
    precondition(successor.hasPrefix("com.repoprompt.ce.tests.defaults."))
    precondition(Bundle.main.bundleIdentifier == successor)
    let legacy = successor + ".legacy"
    let defaults = UserDefaults.standard
    let customPath = "/opt/homebrew/bin/codex"
    let marker = BundleIdentityDefaultsMigration.completionMarker
    // Older SwiftUI windows used their nested view type as the frame autosave name.
    let frameKey = "NSWindow Frame " + String(repeating: "Nested<Content>", count: 90)
    let frame = "0 0 1280 900 0 0 3840 2135"
    let legacySettings: [String: Any] = [
        "CodexCLIConnected": true, "ClaudeCodeConnected": true, "agentOnboardingHasSeen": true,
        "codexRuntimeSelectionMode": "bundled", "overlap": "legacy",
        frameKey: frame,
        marker: true
    ]
    let successorSettings: [String: Any] = [
        "codexRuntimeSelectionMode": "external", "codexRuntimeExecutablePath": customPath,
        "overlap": "successor", "successorOnly": ["selected", "retained"]
    ]

    func flush(_ domain: String) {
        precondition(CFPreferencesSynchronize(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
    }

    func seed(_ settings: [String: Any], domain: String) {
        for (key, value) in settings {
            CFPreferencesSetValue(key as CFString, value as CFPropertyList, domain as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        flush(domain)
    }

    func verifySettings() {
        precondition(defaults.bool(forKey: marker))
        precondition(defaults.bool(forKey: "CodexCLIConnected"))
        precondition(defaults.bool(forKey: "ClaudeCodeConnected"))
        precondition(defaults.bool(forKey: "agentOnboardingHasSeen"))
        precondition(defaults.string(forKey: "codexRuntimeSelectionMode") == "external")
        precondition(defaults.string(forKey: "codexRuntimeExecutablePath") == customPath)
        precondition(defaults.string(forKey: "overlap") == "successor")
        precondition(defaults.stringArray(forKey: "successorOnly") == ["selected", "retained"])
        precondition(defaults.string(forKey: frameKey) == frame)
        precondition(NSDictionary(dictionary: legacySettings).isEqual(to: defaults.persistentDomain(forName: legacy) ?? [:]))
    }

    switch CommandLine.arguments[1] {
    case "seed":
        seed(legacySettings, domain: legacy)
        seed(successorSettings, domain: successor)
    case "migrate", "restart":
        let firstLaunch = CommandLine.arguments[1] == "migrate"
        precondition(defaults.bool(forKey: marker) != firstLaunch)
        precondition(defaults.string(forKey: "overlap") == "successor")
        let report = BundleIdentityDefaultsMigration.migrateIfNeeded(
            bundleIdentifier: RuntimeCodeSigningPolicy.successorDeveloperIDBundleIdentifier,
            legacyDomainName: legacy,
            successorDomainName: successor
        )
        precondition(report.outcome == (firstLaunch ? .migrated : .alreadyCompleted))
        precondition(report.copiedKeyCount == (firstLaunch ? 4 : 0))
        verifySettings()
        _exit(EXIT_SUCCESS)
    case "cleanup":
        for domain in [legacy, successor] {
            let keys = defaults.persistentDomain(forName: domain)?.keys.map { $0 } ?? []
            for key in keys {
                CFPreferencesSetValue(key as CFString, nil, domain as CFString,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            flush(domain)
        }
    default:
        preconditionFailure("Unexpected fixture command")
    }
    """#
}
