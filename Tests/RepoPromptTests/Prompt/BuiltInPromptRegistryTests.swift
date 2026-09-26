import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

/// Guards the migration of built-in prompt bodies from Swift literals to
/// `AppResources/Prompts`. The pinned hashes were captured from the pre-migration
/// literals and production render paths; they must only change together with an
/// intentional prompt edit (which must also record the previous canonical text for
/// stored-prompt upgrades).
@MainActor
final class BuiltInPromptRegistryTests: XCTestCase {
    private enum Pinned {
        static let oraclePlanText = "37b0dad309399ab1cc3bba78ecc2336e8d9337ed70b83d63e5aeb28bb8ecca73"
        static let oracleReviewText = "80d17ed6e6863c9eae7dff113394d5ff39577e2a4a07e25a229c9bb27b417921"
        static let oracleChatText = "dc1af204a687ae1ec2060249aacc0812d6b277e83122b449e5137101bd7fbcb8"
        static let oracleChatNoRootsText = "f0e22cc6c07d7cab886ba40ba783b001a036de10f6cb4b30639bf8e179bcc8c9"

        static let planSystemBuiltIn = "b0fae79a60bb3597be4290a02cdabf306e68fd7f52ff2757fdfc91c7572e6347"
        static let planSystemCustomOverride = "c4c89876839b7f69ebdfe16ec8191ffb37588dc7b7e672c5ba5f47674e5e23eb"
        static let reviewSystemBuiltIn = "66d38fc3c8fecd4b64a31b925a2f32383835badc2ac2374d8a7fd53681d49e8b"
        static let reviewSystemUserEdited = "57023a514361a35dad2c1ec991ff72cd1aed5334bdc2c873f3e0225d63c8924e"
        static let chatSystemNoRoots = oracleChatNoRootsText
    }

    private let reviewID = UUID(uuidString: "D7F1B2E4-3C5A-6B8D-CF8E-1F5D0E2A4C6B")!
    private let architectID = UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9")!
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
        super.tearDown()
    }

    // MARK: Resource identity

    func testTestsLoadCheckedInAppResourcesPrompts() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 4 {
            repositoryRoot.deleteLastPathComponent()
        }
        let expected = repositoryRoot.appendingPathComponent("AppResources/Prompts", isDirectory: true)
        let actual = try XCTUnwrap(BuiltInPromptRegistry.shared.promptsDirectory)
        XCTAssertEqual(actual.standardizedFileURL.path, expected.standardizedFileURL.path)

        let directories = try FileManager.default.contentsOfDirectory(atPath: expected.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
        XCTAssertEqual(directories, BuiltInPromptID.allCases.map(\.rawValue).sorted())
    }

    func testResourceTextsMatchPreMigrationLiterals() throws {
        let expected: [BuiltInPromptID: String] = [
            .oraclePlan: Pinned.oraclePlanText,
            .oracleReview: Pinned.oracleReviewText,
            .oracleChat: Pinned.oracleChatText,
            .oracleChatNoRoots: Pinned.oracleChatNoRootsText
        ]
        for id in BuiltInPromptID.allCases {
            let resource = try BuiltInPromptRegistry.shared.resource(id)
            XCTAssertEqual(sha256(resource.text), expected[id], id.rawValue)
            XCTAssertEqual(resource.sha256, sha256(resource.text + "\n"), id.rawValue)
        }
    }

    // MARK: Production render snapshots

    func testBuiltInProductionPromptsMatchPreMigrationSnapshots() throws {
        let vm = try makePromptViewModel()
        XCTAssertEqual(sha256(vm.architectPrompt.content), Pinned.oraclePlanText)
        XCTAssertEqual(try sha256(XCTUnwrap(vm.storedPrompts.first { $0.id == reviewID }).content), Pinned.oracleReviewText)
        XCTAssertEqual(try sha256(systemPrompt(vm, .plan)), Pinned.planSystemBuiltIn)
        XCTAssertEqual(try sha256(systemPrompt(vm, .review)), Pinned.reviewSystemBuiltIn)
        XCTAssertEqual(try sha256(systemPrompt(vm, .chat)), Pinned.chatSystemNoRoots)
        XCTAssertEqual(sha256(vm.getChatPrompt()), Pinned.chatSystemNoRoots)
    }

    func testUserEditedAndCustomOverridePromptsStillWin() throws {
        let vm = try makePromptViewModel(
            seed: [StoredPromptRecord(id: reviewID, title: "[Review]", content: "USER EDITED REVIEW", isUserEdited: true)],
            customPlanningPrompt: "CUSTOM PLAN OVERRIDE"
        )
        XCTAssertEqual(try sha256(systemPrompt(vm, .plan)), Pinned.planSystemCustomOverride)
        XCTAssertEqual(try sha256(systemPrompt(vm, .review)), Pinned.reviewSystemUserEdited)
        XCTAssertEqual(try XCTUnwrap(vm.storedPrompts.first { $0.id == reviewID }).content, "USER EDITED REVIEW")
    }

    func testKnownPreviousCanonicalPromptsUpgradeToResourceBaseline() throws {
        let architectV1 = """
        Analyze the requested changes and break them down into clear, actionable steps
        Create a detailed implementation plan that includes:
        Highlight critical architectural decisions that need to be made
        """
        let reviewV1 = "Acknowledge what's done particularly well\nAre the commit boundaries logical?"
        let vm = try makePromptViewModel(
            seed: [
                StoredPromptRecord(id: architectID, title: "[Architect]", content: architectV1),
                StoredPromptRecord(id: reviewID, title: "[Review]", content: reviewV1, isUserEdited: true)
            ],
            customPlanningPrompt: architectV1
        )
        XCTAssertEqual(vm.customPlanningPrompt, vm.architectPrompt.content)
        XCTAssertEqual(try sha256(XCTUnwrap(vm.storedPrompts.first { $0.id == architectID }).content), Pinned.oraclePlanText)
        XCTAssertEqual(try sha256(systemPrompt(vm, .plan)), Pinned.planSystemBuiltIn)
        XCTAssertEqual(try sha256(systemPrompt(vm, .review)), Pinned.reviewSystemBuiltIn)
    }

    // MARK: Override scoping

    func testOverrideIsScopedToOneRenderAndOnePrompt() throws {
        let registry = BuiltInPromptRegistry.shared
        let baseline = try registry.resource(.oraclePlan)
        let override = BuiltInPromptOverride(promptID: .oraclePlan, text: "CANDIDATE")

        let rendered = try registry.render(.oraclePlan, override: override)
        XCTAssertEqual(rendered.text, "CANDIDATE")
        XCTAssertTrue(rendered.isOverridden)
        XCTAssertEqual(rendered.baselineSHA256, baseline.sha256)

        let production = try registry.render(.oraclePlan)
        XCTAssertEqual(production.text, baseline.text)
        XCTAssertFalse(production.isOverridden)
        XCTAssertEqual(registry.text(.oraclePlan), baseline.text)

        XCTAssertThrowsError(try registry.render(.oracleReview, override: override)) { error in
            XCTAssertEqual(
                error as? BuiltInPromptRegistryError,
                .overridePromptMismatch(expected: .oracleReview, actual: .oraclePlan)
            )
        }
    }

    // MARK: Loading rules

    func testLoaderStripsExactlyOneTrailingNewline() throws {
        let root = try makePromptsDirectory([.oraclePlan: Data("line\n\n".utf8)])
        let resource = try BuiltInPromptRegistry(promptsDirectory: root).resource(.oraclePlan)
        XCTAssertEqual(resource.text, "line\n")
        XCTAssertEqual(resource.sha256, sha256("line\n\n"))
    }

    func testLoaderRejectsMissingEmptySymlinkedAndNonUTF8Resources() throws {
        let root = try makePromptsDirectory([
            .oracleReview: Data("\n".utf8),
            .oracleChat: Data([0xFF, 0xFE, 0x00])
        ])
        let target = root.appendingPathComponent("target.md")
        try Data("linked".utf8).write(to: target)
        let linkDirectory = root.appendingPathComponent(BuiltInPromptID.oracleChatNoRoots.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        let link = linkDirectory.appendingPathComponent(BuiltInPromptID.promptFileName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let registry = BuiltInPromptRegistry(promptsDirectory: root)
        let planPath = root.appendingPathComponent("oracle-plan/prompt.md").path
        XCTAssertThrowsError(try registry.resource(.oraclePlan)) {
            XCTAssertEqual($0 as? BuiltInPromptRegistryError, .resourceUnreadable(.oraclePlan, path: planPath))
        }
        XCTAssertThrowsError(try registry.resource(.oracleReview)) {
            XCTAssertEqual($0 as? BuiltInPromptRegistryError, .emptyResource(.oracleReview))
        }
        XCTAssertThrowsError(try registry.resource(.oracleChat)) {
            XCTAssertEqual($0 as? BuiltInPromptRegistryError, .invalidUTF8(.oracleChat))
        }
        XCTAssertThrowsError(try registry.resource(.oracleChatNoRoots)) {
            XCTAssertEqual($0 as? BuiltInPromptRegistryError, .resourceNotRegularFile(.oracleChatNoRoots, path: link.path))
        }
        XCTAssertThrowsError(try BuiltInPromptRegistry(promptsDirectory: nil).resource(.oraclePlan)) {
            XCTAssertEqual($0 as? BuiltInPromptRegistryError, .resourcesDirectoryUnavailable)
        }
    }

    // MARK: Helpers

    private func systemPrompt(_ vm: PromptViewModel, _ mode: OracleMode) throws -> String {
        let preset = switch mode {
        case .plan: ChatPreset.BuiltIn.plan
        case .review: ChatPreset.BuiltIn.review
        case .chat: ChatPreset.BuiltIn.chat
        }
        return try vm.captureOraclePromptConfiguration(chatPreset: preset, mode: mode).systemPrompt
    }

    private func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func makePromptsDirectory(_ files: [BuiltInPromptID: Data]) throws -> URL {
        let root = try makeTemporaryRoot()
        for (id, data) in files {
            let directory = root.appendingPathComponent(id.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(BuiltInPromptID.promptFileName))
        }
        return root
    }

    private func makePromptViewModel(
        seed: [StoredPromptRecord] = [],
        customPlanningPrompt: String? = nil
    ) throws -> PromptViewModel {
        let root = try makeTemporaryRoot()
        let promptsURL = root.appendingPathComponent("SavedPrompts.json")
        if !seed.isEmpty {
            try JSONEncoder().encode(seed).write(to: promptsURL)
        }
        let suite = "BuiltInPromptRegistryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = GlobalSettingsStore(
            defaults: defaults,
            fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("globalSettings.json"))
        )
        if let customPlanningPrompt {
            store.setCustomPlanningPrompt(customPlanningPrompt)
        }
        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let apiSettings = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )
        return PromptViewModel(
            fileManager: WorkspaceFilesViewModel(),
            apiSettingsViewModel: apiSettings,
            windowID: -7301,
            settingsManager: WindowSettingsManager(windowID: -7301, store: store),
            storedPromptPersistence: StoredPromptPersistenceService(storage: PromptStorage(fileURL: promptsURL)),
            refreshAvailableModelsOnInit: false
        )
    }
}
