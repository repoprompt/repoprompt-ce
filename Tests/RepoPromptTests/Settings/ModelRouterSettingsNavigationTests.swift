import AppKit
import Foundation
@testable import RepoPromptApp
@testable import RepoPromptFileSystem
import RepoPromptSecureStorage
import SwiftUI
import XCTest

final class ModelRouterSettingsNavigationTests: XCTestCase {
    func testAgentDecisionsBelongsToAgentModeWithoutSeparateRouterSection() {
        XCTAssertEqual(SettingsView.sidebarSectionOrder.first, .agentMode)
        XCTAssertFalse(SettingsView.sidebarSectionOrder.map(\.title).contains("Router"))
        XCTAssertEqual(SettingsTab.modelRouter.section, .agentMode)
        XCTAssertEqual(SettingsTab.modelRouter.title, "Agent Decisions")
        XCTAssertTrue(SettingsTab.modelRouter.searchTags.contains("agent decisions"))
    }

    func testRouterDeepLinkNotificationHasDedicatedIdentity() {
        XCTAssertEqual(Notification.Name.showModelRouterSettingsTab.rawValue, "showModelRouterSettingsTab")
        XCTAssertNotEqual(Notification.Name.showModelRouterSettingsTab, .showAgentModeSettingsTab)
    }

    @MainActor
    func testAgentDecisionsSectionRequestsUseFreshTokensAndConsumeOnlyMatchingToken() throws {
        let coordinator = SettingsWindowCoordinator.shared
        if let pending = coordinator.pendingAgentDecisionsSectionRequest {
            _ = coordinator.consumeAgentDecisionsSectionRequest(token: pending.token)
        }

        coordinator.publishAgentDecisionsSectionRequest(.modelRouter)
        let first = try XCTUnwrap(coordinator.pendingAgentDecisionsSectionRequest)
        coordinator.publishAgentDecisionsSectionRequest(.autoEffort)
        let latest = try XCTUnwrap(coordinator.pendingAgentDecisionsSectionRequest)

        XCTAssertNotEqual(first.token, latest.token)
        XCTAssertNil(coordinator.consumeAgentDecisionsSectionRequest(token: first.token))
        XCTAssertEqual(coordinator.consumeAgentDecisionsSectionRequest(token: latest.token), .autoEffort)
        XCTAssertNil(coordinator.pendingAgentDecisionsSectionRequest)
        XCTAssertNil(coordinator.consumeAgentDecisionsSectionRequest(token: latest.token))
    }
}

@MainActor
final class RouterAccordionNativeFocusTests: XCTestCase {
    func testNativeFirstResponderProbeRejectsUnrelatedTextField() throws {
        let fixture = try RouterAccordionFocusFixture()
        defer { fixture.tearDown() }

        guard let unrelatedField = fixture.unrelatedField else {
            XCTFail("Unrelated synthetic field was not mounted. \(fixture.focusDiagnostic)")
            return
        }
        guard fixture.window.makeFirstResponder(unrelatedField) else {
            XCTFail("Could not focus unrelated synthetic field. \(fixture.focusDiagnostic)")
            return
        }
        guard fixture.waitFor("unrelated-field ownership without target-field ownership", until: {
            fixture.unrelatedFieldOwnsFirstResponder
                && !fixture.secureFieldOwnsFirstResponder
                && fixture.assignments.keyboardFocus == .unrelatedField
        }) else { return }
    }
}

@MainActor
private func waitForFocusCondition(
    _ description: String,
    timeout: TimeInterval = 1,
    file: StaticString = #filePath,
    line: UInt = #line,
    update: () -> Void,
    diagnostic: () -> String,
    until condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        update()
        if condition() { return true }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { break }
        RunLoop.main.run(until: Date().addingTimeInterval(min(0.01, remaining)))
    }
    XCTFail("Timed out waiting for \(description). \(diagnostic())", file: file, line: line)
    return false
}

@MainActor
private final class RouterAccordionFocusFixture {
    enum Target: Hashable {
        case secureField
        case unrelatedField
    }

    let window: NSWindow
    private let hostingView: NSHostingView<FocusHarness>
    let assignments: FocusAssignments

    var secureField: NSSecureTextField? {
        descendants(of: hostingView).compactMap { $0 as? NSSecureTextField }.first
    }

    var unrelatedField: NSSecureTextField? {
        descendants(of: hostingView)
            .compactMap { $0 as? NSSecureTextField }
            .first { $0 !== secureField }
    }

    var secureFieldOwnsFirstResponder: Bool {
        secureField.map(ownsFirstResponder) ?? false
    }

    var unrelatedFieldOwnsFirstResponder: Bool {
        unrelatedField.map(ownsFirstResponder) ?? false
    }

    var focusDiagnostic: String {
        let responderName = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "firstResponder=\(responderName), secureMounted=\(secureField != nil), unrelatedMounted=\(unrelatedField != nil), secureOwns=\(secureFieldOwnsFirstResponder), unrelatedOwns=\(unrelatedFieldOwnsFirstResponder), focus=\(String(describing: assignments.keyboardFocus))"
    }

    func waitFor(_ description: String, until condition: () -> Bool) -> Bool {
        waitForFocusCondition(
            description,
            update: updateHostedLayout,
            diagnostic: { focusDiagnostic },
            until: condition
        )
    }

    init() throws {
        let assignments = FocusAssignments()
        self.assignments = assignments
        let hostingView = NSHostingView(rootView: FocusHarness(assignments: assignments))
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 180)
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        self.window = window

        _ = waitFor(
            "synthetic target and unrelated SecureFields to mount",
            until: { secureField != nil && unrelatedField != nil }
        )
    }

    func updateHostedLayout() {
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        window.contentView = nil
        hostingView.removeFromSuperview()
    }

    private func ownsFirstResponder(_ field: NSTextField) -> Bool {
        if window.firstResponder === field { return true }
        guard let fieldEditor = window.firstResponder as? NSTextView else { return false }
        return fieldEditor.delegate === field
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }
}

@MainActor
private final class FocusAssignments {
    var keyboardFocus: RouterAccordionFocusFixture.Target?
}

@MainActor
final class RouterAccordionProductionCardFocusFixture {
    private let hostingView: NSHostingView<ProductionCardFocusHarness>
    private let viewState = RouterSettingsViewState()
    private let expansionState = RouterOpenAIServiceExpansionState()
    private let assignments = ProductionCardFocusAssignments()
    let window: NSWindow

    var focusedHeaderID: DecisionServiceID? {
        assignments.focusedHeaderID
    }

    var focusedConfigurationInputID: DecisionServiceID? {
        assignments.focusedConfigurationInputID
    }

    var secureField: NSSecureTextField? {
        descendants(of: hostingView).compactMap { $0 as? NSSecureTextField }.first
    }

    var secureFieldOwnsFirstResponder: Bool {
        secureField.map(ownsFirstResponder) ?? false
    }

    var fittingHeight: CGFloat {
        hostingView.fittingSize.height
    }

    var focusDiagnostic: String {
        let responderName = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "firstResponder=\(responderName), secureMounted=\(secureField != nil), secureOwns=\(secureFieldOwnsFirstResponder), headerBinding=\(String(describing: focusedHeaderID))"
    }

    func waitFor(_ description: String, until condition: () -> Bool) -> Bool {
        waitForFocusCondition(
            description,
            update: updateHostedLayout,
            diagnostic: { focusDiagnostic },
            until: condition
        )
    }

    init(
        viewModel: RouterSettingsViewModel,
        row: RouterSettingsViewModel.ServiceRow,
        initiallyExpanded: Bool = true
    ) throws {
        expansionState.setExpanded(initiallyExpanded)
        let hostingView = NSHostingView(
            rootView: ProductionCardFocusHarness(
                viewModel: viewModel,
                viewState: viewState,
                expansionState: expansionState,
                row: row,
                assignments: assignments
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        self.window = window
        if initiallyExpanded {
            _ = waitFor(
                "actual OpenAI card SecureField to mount",
                until: { secureField != nil }
            )
        }
    }

    func setExpanded(_ expanded: Bool) {
        expansionState.setExpanded(expanded)
    }

    func assignOpenAIHeaderFocus() {
        assignments.assignOpenAIHeaderFocus?()
    }

    func assignOpenAIConfigurationInputFocus() {
        assignments.assignOpenAIConfigurationInputFocus?()
    }

    func updateHostedLayout() {
        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        assignments.assignOpenAIHeaderFocus = nil
        assignments.assignOpenAIConfigurationInputFocus = nil
        window.contentView = nil
        hostingView.removeFromSuperview()
    }

    func fieldOwnsFirstResponder(_ field: NSTextField) -> Bool {
        ownsFirstResponder(field)
    }

    private func ownsFirstResponder(_ field: NSTextField) -> Bool {
        if window.firstResponder === field { return true }
        guard let fieldEditor = window.firstResponder as? NSTextView else { return false }
        return fieldEditor.delegate === field
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }
}

@MainActor
private final class ProductionCardFocusAssignments {
    var focusedHeaderID: DecisionServiceID?
    var focusedConfigurationInputID: DecisionServiceID?
    var assignOpenAIHeaderFocus: (() -> Void)?
    var assignOpenAIConfigurationInputFocus: (() -> Void)?
}

private struct ProductionCardFocusHarness: View {
    @ObservedObject var viewModel: RouterSettingsViewModel
    @ObservedObject var viewState: RouterSettingsViewState
    @ObservedObject var expansionState: RouterOpenAIServiceExpansionState
    let row: RouterSettingsViewModel.ServiceRow
    let assignments: ProductionCardFocusAssignments

    @FocusState private var focusedHeaderID: DecisionServiceID?
    @AccessibilityFocusState private var accessibilityFocusedHeaderID: DecisionServiceID?
    @FocusState private var focusedConfigurationInputID: DecisionServiceID?
    @AccessibilityFocusState private var accessibilityFocusedConfigurationInputID: DecisionServiceID?

    var body: some View {
        OpenAIDecisionsRouterServiceSettingsCard(
            expansionState: expansionState,
            viewModel: viewModel,
            viewState: viewState,
            secretDraftState: viewState.secretDraftState(for: row.id),
            row: row,
            usageLabels: [],
            configurationInputAnchorID: "openai-configuration-input",
            serviceHeaderFocus: $focusedHeaderID,
            serviceHeaderAccessibilityFocus: $accessibilityFocusedHeaderID,
            configurationInputFocus: $focusedConfigurationInputID,
            configurationInputAccessibilityFocus: $accessibilityFocusedConfigurationInputID
        )
        .onChange(of: focusedHeaderID) { _, newValue in
            assignments.focusedHeaderID = newValue
        }
        .onChange(of: focusedConfigurationInputID) { _, newValue in
            assignments.focusedConfigurationInputID = newValue
        }
        .onAppear {
            let headerFocusBinding = $focusedHeaderID
            assignments.assignOpenAIHeaderFocus = {
                headerFocusBinding.wrappedValue = .openAIDecisions
            }
            let configurationInputFocusBinding = $focusedConfigurationInputID
            assignments.assignOpenAIConfigurationInputFocus = {
                configurationInputFocusBinding.wrappedValue = .openAIDecisions
            }
        }
    }
}

private struct FocusHarness: View {
    let assignments: FocusAssignments
    @FocusState private var keyboardFocus: RouterAccordionFocusFixture.Target?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField("Synthetic test value", text: .constant("synthetic-only"))
                .focused($keyboardFocus, equals: .secureField)
            SecureField("Unrelated synthetic field", text: .constant("synthetic-only"))
                .focused($keyboardFocus, equals: .unrelatedField)
            Text("Keyboard focus: \(String(describing: keyboardFocus))")
                .hidden()
        }
        .padding()
        .onChange(of: keyboardFocus) { _, newValue in
            // Store only an enum describing ownership; never retain or log the field contents.
            assignments.keyboardFocus = newValue
        }
    }
}

final class RouterServiceSettingsPresentationTests: XCTestCase {
    func testJevDeclaresCapabilitiesAndCredentialActions() {
        let controller = JevRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend())
        )
        let presentation = JevDecisionService.settingsRegistration(controller: controller).presentation

        XCTAssertEqual(presentation.capabilities.map(\.id), ["model-router", "auto-effort"])
        XCTAssertNil(presentation.productStatus)
        XCTAssertEqual(
            presentation.supportedCredentialActions,
            [.validateAndSaveSecret, .revalidateStoredSecret, .removeStoredSecret]
        )
        XCTAssertEqual(presentation.secretFieldLabel, "TypeSafe API key")
        XCTAssertEqual(presentation.links.map(\.title), ["TypeSafe API documentation", "TypeSafe privacy policy"])
        XCTAssertEqual(presentation.links.map(\.url.absoluteString), [
            "https://docs.typesafe.ai/api",
            "https://typesafe.ai/legal/privacy-policy"
        ])
        XCTAssertEqual(presentation.links.map(\.disclosureID), ["jev-technical", "jev-privacy"])
    }

    func testDecisionsKeepsDedicatedKeyPolicyInStructuredMetadata() {
        let controller = OpenAIDecisionsRouterCredentialService(
            secureKeys: SecureKeysService(secureStorage: TestSecureStorageBackend()),
            decide: { _, _ in throw CancellationError() }
        )
        let presentation = OpenAIDecisionsDecisionService.settingsRegistration(controller: controller).presentation

        XCTAssertNil(presentation.productStatus)
        XCTAssertEqual(presentation.capabilities.map(\.id), ["model-router", "auto-effort"])
        XCTAssertTrue(presentation.summary.contains("supported decisions when selected"))
        let privacyCopy = presentation.disclosures[0].paragraphs[0]
        XCTAssertTrue(privacyCopy.contains("available effort choices"))
        XCTAssertTrue(privacyCopy.contains("masked excerpt of the current user turn"))
        XCTAssertTrue(privacyCopy.contains("built-in workflow category"))
        XCTAssertEqual(presentation.secretFieldLabel, "API key for Decisions by OpenAI")
        XCTAssertEqual(
            presentation.disclosures.map(\.category),
            [.privacy, .pricing, .technical]
        )
        XCTAssertEqual(presentation.notices.map(\.id), [
            "decisions-dedicated-project",
            "decisions-validation-charge"
        ])
        XCTAssertTrue(presentation.notices[0].text.contains("not a hard budget boundary"))
        XCTAssertTrue(presentation.notices[1].text.contains("fixed test request"))
        XCTAssertTrue(presentation.notices[1].text.contains("confirms access only at the time of validation"))
        let pricing = presentation.disclosures.first { $0.category == .pricing }
        XCTAssertEqual(
            pricing?.paragraphs,
            ["OpenAI sets Decisions API pricing, which may change and can vary with factors such as context length or processing region. Review OpenAI's current pricing before enabling the service."]
        )
        XCTAssertEqual(presentation.links.map(\.title), [
            "Decisions documentation",
            "OpenAI API pricing",
            "OpenAI data controls"
        ])
        XCTAssertEqual(presentation.links.map(\.url.absoluteString), [
            "https://developers.openai.com/api/docs/guides/decisions",
            "https://developers.openai.com/api/docs/pricing",
            "https://developers.openai.com/api/docs/guides/your-data"
        ])
        XCTAssertEqual(presentation.links.map(\.disclosureID), [
            "decisions-technical",
            "decisions-pricing",
            "decisions-privacy"
        ])
    }

    func testUnassignedAndUnknownDisclosureLinksFallBackToLastDisclosure() throws {
        let first = DecisionServiceSettingsPresentation.DisclosureSection(
            id: "first", category: .privacy, title: "Privacy", paragraphs: []
        )
        let last = DecisionServiceSettingsPresentation.DisclosureSection(
            id: "last", category: .technical, title: "Technical", paragraphs: []
        )
        let presentation = try DecisionServiceSettingsPresentation(
            title: "Service",
            summary: "Summary",
            notices: [],
            disclosures: [first, last],
            productStatus: nil,
            capabilities: [],
            secretFieldLabel: nil,
            supportedCredentialActions: [],
            links: [
                .init(title: "First", url: XCTUnwrap(URL(string: "https://example.com/first")), disclosureID: "first"),
                .init(title: "Legacy", url: XCTUnwrap(URL(string: "https://example.com/legacy"))),
                .init(
                    title: "Unknown",
                    url: XCTUnwrap(URL(string: "https://example.com/unknown")),
                    disclosureID: "missing"
                )
            ]
        )

        XCTAssertEqual(presentation.links(for: first, isLastDisclosure: false).map(\.title), ["First"])
        XCTAssertEqual(presentation.links(for: last, isLastDisclosure: true).map(\.title), ["Legacy", "Unknown"])
    }
}

final class WindowActivityLedgerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now: UInt64 = 0
    }

    func testOverlappingRootsCountUnionAndRetainAmbiguityUntilIdle() throws {
        let clock = Clock()
        let ledger = WindowActivityLedger(clock: { clock.now })
        ledger.registerWindow(1)
        ledger.record(windowID: 1, phase: .began, root: "A")
        clock.now = 2_000_000_000
        ledger.record(windowID: 1, phase: .began, root: "B")
        clock.now = 3_000_000_000
        ledger.record(windowID: 1, phase: .ended)
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first).root, "Multiple roots")
        clock.now = 5_000_000_000
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first).busyTotal, 5_000_000_000)
        ledger.record(windowID: 1, phase: .ended)
        clock.now = 9_000_000_000
        let idle = try XCTUnwrap(ledger.snapshot().first)
        XCTAssertEqual(idle.busyTotal, 5_000_000_000)
        XCTAssertEqual(idle.lastEnded, 5_000_000_000)
        XCTAssertNil(idle.busySince)
        ledger.record(windowID: 1, phase: .began, root: "C")
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first).root, "C")
    }

    func testRegistrationBoundaryAndLateEventsCannotClearAnotherScope() throws {
        let ledger = WindowActivityLedger(clock: { 10 })
        let acceptedA = ledger.record(windowID: 1, phase: .began)
        ledger.registerWindow(1)
        ledger.registerWindow(1)
        XCTAssertTrue(ledger.record(windowID: 1, phase: .began, root: "B"))
        if acceptedA { ledger.record(windowID: 1, phase: .ended) }
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first).busySince, 10)
        ledger.removeWindow(1)
        ledger.removeWindow(1)
        XCTAssertFalse(ledger.record(windowID: 1, phase: .ended))
        XCTAssertFalse(ledger.record(windowID: 1, phase: .began))
        XCTAssertTrue(ledger.snapshot().isEmpty)
    }

    func testWatcherBatchBracketsWorkAndHonorsRejectedBegin() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let ledger = WindowActivityLedger(clock: { clock.now })
        let service = try await FileSystemService(
            path: directory.path, testIgnoreRules: IgnoreRules(policy: .nonGitRoot), isTestMode: true,
            watcherActivityObserver: { phase in
                let accepted = ledger.record(windowID: 1, phase: phase == .began ? .began : .ended, root: "hidden (session worktree)")
                if phase == .began { clock.now += 100 }
                return accepted
            }
        )
        await service.processWatcherBatch(PendingFSEventBatch(), token: 1)
        ledger.registerWindow(1)
        await service.processWatcherBatch(PendingFSEventBatch(), token: 2)
        let result = try XCTUnwrap(ledger.snapshot().first)
        XCTAssertEqual(result.busyTotal, 100)
        XCTAssertNil(result.busySince)
        XCTAssertEqual(result.root, "hidden (session worktree)")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await service.processWatcherBatch(PendingFSEventBatch(), token: 3)
        }
        await cancelled.value
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first).busyTotal, 100)
    }

    func testSnapshotsAreReadOnlyAndWindowsAreIsolated() throws {
        let clock = Clock()
        let ledger = WindowActivityLedger(clock: { clock.now })
        ledger.registerWindow(1)
        ledger.registerWindow(2)
        clock.now = 100
        ledger.record(windowID: 1, phase: .began)
        clock.now = 50
        ledger.record(windowID: 1, phase: .ended)
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first { $0.windowID == 1 }).busyTotal, 0)
        clock.now = 100
        ledger.record(windowID: 1, phase: .began)
        clock.now = 1_000_000_100
        XCTAssertEqual(
            ledger.snapshot().sorted { $0.windowID < $1.windowID },
            ledger.snapshot().sorted { $0.windowID < $1.windowID }
        )
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first { $0.windowID == 1 }).busyTotal, 1_000_000_000)
        XCTAssertEqual(try XCTUnwrap(ledger.snapshot().first { $0.windowID == 2 }).busyTotal, 0)
    }
}

final class ActivitySettingsTests: XCTestCase {
    func testProcessCPUUsesTaskTotalsTimebaseAndResetsInvalidBaseline() {
        var sampler = ActivityProcessSampler(numer: 3, denom: 2)
        XCTAssertEqual(sampler.cpuText(.init(user: 0, system: 0, now: 0)), "Measuring…")
        XCTAssertEqual(sampler.cpuText(.init(user: 600_000_000, system: 400_000_000, now: 1_000_000_000)), "150.0%")
        XCTAssertEqual(sampler.cpuText(.init(user: 1, system: 1, now: 2_000_000_000)), "Unavailable")
        XCTAssertEqual(sampler.cpuText(.init(user: 2, system: 2, now: 3_000_000_000)), "Measuring…")
        XCTAssertEqual(sampler.cpuText(nil), "Unavailable")
        XCTAssertEqual(sampler.cpuText(.init(user: 3, system: 3, now: 4_000_000_000)), "Measuring…")
        var invalid = ActivityProcessSampler(numer: 1, denom: 0)
        XCTAssertEqual(invalid.cpuText(.init(user: 0, system: 0, now: 0)), "Unavailable")
    }

    func testVisibleIntervalRateDoesNotDoubleCountLiveEpisodeAndReopenResetsRate() {
        let previous = WindowActivityLedger.Snapshot(
            windowID: 1,
            sampledAt: 3_000_000_000,
            busyTotal: 2_000_000_000,
            busySince: 1_000_000_000,
            lastEnded: nil,
            root: "repo (session worktree)"
        )
        let now = WindowActivityLedger.Snapshot(
            windowID: 1,
            sampledAt: 4_000_000_000,
            busyTotal: 3_000_000_000,
            busySince: 1_000_000_000,
            lastEnded: nil,
            root: "repo (session worktree)"
        )
        let row = ActivityDisplay.Row(id: 1, title: "repo", snapshot: now, previous: previous)
        XCTAssertEqual(row.rate, "1.00")
        XCTAssertEqual(row.total, "3.0 s")
        XCTAssertEqual(row.status, "running for 3.0 s")
        XCTAssertEqual(row.root, "repo (session worktree)")
        XCTAssertEqual(ActivityDisplay.Row(id: 1, title: "repo", snapshot: now, previous: nil).rate, "Measuring…")
        let idle = ActivityDisplay.Row(id: 2, title: "", snapshot: nil, previous: nil)
        XCTAssertEqual(idle.window, "Window 2")
        XCTAssertEqual(idle.status, "No activity recorded")
        XCTAssertEqual(idle.total, "0.0 s")
    }

    func testReportUsesDisplayedValuesAndSanitizedLabels() {
        let snapshot = WindowActivityLedger.Snapshot(
            windowID: 1,
            sampledAt: 65_000_000_000,
            busyTotal: 64_000_000_000,
            busySince: 1_000_000_000,
            lastEnded: nil,
            root: "repo\nroot"
        )
        let display = ActivityDisplay(cpu: "150.0%", memory: "2400 MiB", rows: [
            .init(id: 1, title: "repo\twindow", snapshot: snapshot, previous: nil)
        ], capturedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(display.report, """
        RepoPrompt CE — Activity
        Captured: 1970-01-01T00:00:00Z
        Process CPU: 150.0%
        Memory (resident): 2400 MiB
        100% CPU = one core. Window job time includes waits, not CPU; drawing and other work are unattributed.
        Window 1 — repo window
          File watching: Measuring… (s/s, last interval)
          Root: repo root
          Status: running for 1 m 04 s
          Busy total since window opened: 1 m 04 s
        """)
        XCTAssertEqual(ActivityDisplay.label(String(repeating: "a", count: 100)).count, 80)
        XCTAssertEqual(ActivityDisplay.duration(3_840_000_000_000), "1 h 04 m")
        XCTAssertEqual(ActivityDisplay.duration(100_800_000_000_000), "1 d 04 h")
        XCTAssertTrue(SettingsTab.advanced.searchTags.contains("activity"))
    }
}
