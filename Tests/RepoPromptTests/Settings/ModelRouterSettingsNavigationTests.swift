import AppKit
import Foundation
@testable import RepoPromptApp
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
