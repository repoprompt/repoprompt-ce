import AppKit
import Combine
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import SwiftUI
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

/// Handoff must not expose a child tab before the child is durable and its direct oversight grants
/// have been inherited. A failed first save remains recoverable, but cannot authorize inheritance.
@MainActor
final class AgentSessionLinkHandoffInheritanceTests: XCTestCase {
    func testHandoffDurablySavesBeforeInheritanceAndActivation() async throws {
        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            let parentEndpoint = try XCTUnwrap(
                fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.sourceTabID)
            )
            var events: [String] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                // The source may also persist an adopted default; only the child's save fences inheritance.
                guard session.id != fixture.sourceSession.activeAgentSessionID else {
                    return fixture.rootURL.appendingPathComponent("source-session.json")
                }
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "the child must remain inactive until its first durable save completes"
                )
                events.append("save")
                return fixture.rootURL.appendingPathComponent("handoff-session.json")
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { parent, child in
                XCTAssertEqual(parent, parentEndpoint)
                XCTAssertNotEqual(child, parent)
                XCTAssertEqual(
                    fixture.window.promptManager.activeComposeTabID,
                    fixture.sourceTabID,
                    "inheritance must settle before child activation"
                )
                events.append("inherit")
                return .empty
            }

            let destinationTabID = try await fixture.viewModel.prepareHandoffToNewTab(
                upToItemID: cutoffItemID,
                destinationAgent: fixture.sourceSession.selectedAgent,
                destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
            )

            let destinationSession = try XCTUnwrap(fixture.viewModel.sessions[destinationTabID])
            let bindingToken = try XCTUnwrap(destinationSession.currentRestorationBindingToken)
            XCTAssertEqual(events, ["save", "inherit"])
            XCTAssertEqual(
                destinationSession.restorationReadiness,
                .authoritative(bindingToken, .freshBindingDurablyCreated)
            )
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, destinationTabID)
        }
    }

    func testHandoffSaveFailureRetainsBlockedDestinationUntilExplicitRetry() async throws {
        enum ExpectedSaveFailure: Error { case failed }

        try await withFixture { fixture in
            let cutoffItemID = try XCTUnwrap(fixture.sourceSession.items.last?.id)
            var inheritanceWasCalled = false
            var failedSaveSessionIDs: [UUID] = []

            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                failedSaveSessionIDs.append(session.id)
                throw ExpectedSaveFailure.failed
            }
            fixture.viewModel.test_setAgentSessionLinkInheritanceHandler { _, _ in
                inheritanceWasCalled = true
                return .empty
            }

            var partialFailure: SessionAdminPartialForkError?
            do {
                _ = try await fixture.viewModel.prepareHandoffToNewTab(
                    upToItemID: cutoffItemID,
                    destinationAgent: fixture.sourceSession.selectedAgent,
                    destinationModelRaw: fixture.sourceSession.selectedModelRaw,
                    destinationReasoningEffortRaw: fixture.sourceSession.selectedReasoningEffortRaw
                )
                XCTFail("An unacknowledged first save must not report a completed Handoff.")
            } catch let failure as SessionAdminPartialForkError {
                partialFailure = failure
            }
            let failure = try XCTUnwrap(partialFailure)
            XCTAssertEqual(failure.code, "persist_failed")
            let destination = try XCTUnwrap(fixture.viewModel.sessions.values.first {
                $0.activeAgentSessionID == failure.sessionID
            })
            XCTAssertNotEqual(destination.tabID, fixture.sourceTabID)
            XCTAssertEqual(failedSaveSessionIDs.filter { $0 == failure.sessionID }, [failure.sessionID])
            XCTAssertEqual(
                fixture.window.workspaceManager.activeAgentSessionID(forTabID: destination.tabID),
                failure.sessionID
            )
            XCTAssertFalse(inheritanceWasCalled)
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
            XCTAssertTrue(destination.qualifiedRestorationReadiness.isCreating)
            XCTAssertFalse(destination.permitsBoundOperationAndSave)
            XCTAssertNotNil(destination.operationAdmissionFailureMessage)
            XCTAssertNil(destination.saveDebounceTask, "Generic autosave cannot complete a failed configured creation.")
            let retry = try XCTUnwrap(fixture.viewModel.captureSessionCreationRetry(for: destination))
            XCTAssertTrue(retry.session === destination)
            XCTAssertEqual(retry.bindingToken.bindingIdentity.sessionID, failure.sessionID)
            XCTAssertEqual(retry.bindingToken, destination.currentRestorationBindingToken)
            XCTAssertNotNil(retry.expectedConfigurationStamp)

            let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID)
            let genericSave = await fixture.viewModel.flushSaveRequired(for: destination.tabID, workspaceID: workspaceID)
            guard case .failure = genericSave else {
                return XCTFail("Only the captured creation owner may retry its configured first save.")
            }
            XCTAssertEqual(failedSaveSessionIDs.filter { $0 == failure.sessionID }, [failure.sessionID])
            let retryFile = fixture.rootURL.appendingPathComponent("handoff-retry.json")
            fixture.viewModel.test_setAgentSessionSaver { session, _, _ in
                guard session.id != fixture.sourceSession.activeAgentSessionID else {
                    return fixture.rootURL.appendingPathComponent("source-session.json")
                }
                XCTAssertEqual(session.id, failure.sessionID)
                try JSONEncoder().encode(session).write(to: retryFile, options: .atomic)
                return retryFile
            }
            let retried = await fixture.viewModel.retrySessionInitialSave(retry)
            XCTAssertTrue(retried)
            let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: retryFile))
            XCTAssertEqual(saved.id, failure.sessionID)
            XCTAssertEqual(saved.composeTabID, destination.tabID)
            XCTAssertEqual(saved.toLiveItems().map(\.text), destination.items.map(\.text))
            XCTAssertEqual(destination.qualifiedRestorationReadiness, .authoritative(retry.bindingToken, .freshBindingDurablyCreated))
            XCTAssertNil(fixture.viewModel.captureSessionCreationRetry(for: destination))
            XCTAssertFalse(inheritanceWasCalled, "Retrying persistence cannot manufacture oversight grants.")
            XCTAssertEqual(fixture.window.promptManager.activeComposeTabID, fixture.sourceTabID)
        }
    }

    #if DEBUG
        func testColdClaudePickerActionPresentsReviewBeforeAnyProviderDispatch() async throws {
            _ = NSApplication.shared
            XCTAssertFalse(AppLaunchConfiguration.current.forcesMCPAutoStart)
            let previousPerfOverride = AgentModePerfDiagnostics.debugProcessOverrideEnabled
            AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(true)
            defer { AgentModePerfDiagnostics.setDebugProcessOverrideEnabled(previousPerfOverride) }
            for additionalWindow in [false, true] {
                var providerConstructions = 0
                var fixtures: [Fixture] = []
                do {
                    if additionalWindow {
                        try await fixtures.append(makeFixture(pickerProviderConstruction: { providerConstructions += 1 }))
                    }
                    let fixture = try await makeFixture(pickerProviderConstruction: { providerConstructions += 1 })
                    fixtures.append(fixture)
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .claudeCode
                    session.selectedModelRaw = AgentModel.claudeOpus55.rawValue
                    session.setItemsSilently([.user("Hi", sequenceIndex: 0), .assistant("Hello", sequenceIndex: 1)], reason: .testOverride)
                    session.transcript = .empty
                    session.nextSequenceIndex = 2
                    session.runState = .completed
                    vm.updateBindingsFromSession(session)
                    let sourceModel = session.selectedModelRaw
                    let binding = session.currentRestorationBindingToken
                    let workspaceID = fixture.window.workspaceManager.activeWorkspaceID
                    XCTAssertNotNil(binding)
                    XCTAssertNotNil(workspaceID)
                    XCTAssertTrue(vm.workspaceManager === fixture.window.workspaceManager)
                    XCTAssertTrue(vm.sessions[session.tabID] === session)
                    XCTAssertEqual(vm.currentTabID, session.tabID)
                    XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                    XCTAssertFalse(vm.ui.composer.props.areModelControlsDisabled)
                    let input = AgentInputBar(
                        agentModeVM: vm, composerUI: vm.ui.composer, statusPillsUI: vm.ui.statusPills,
                        openContextDrawerFiles: {}, oracleViewModel: fixture.window.oracleViewModel,
                        promptManager: fixture.window.promptManager, workspaceSearchService: fixture.window.workspaceSearchService,
                        selectionCoordinator: fixture.window.selectionCoordinator, runtimeVM: AgentRuntimeSidebarViewModel(),
                        windowID: fixture.window.windowID, currentTabID: session.tabID,
                        resetTextFieldTrigger: .constant(false), composerBottomInset: .constant(0), transcriptBottomClearance: .constant(0)
                    )
                    // Inspect the real body value, not a copied action or direct preview helper.
                    let composer = try XCTUnwrap(findPickerView(in: input.body, as: AgentComposerView.self))
                    XCTAssertFalse(composer.actions.canSelectAgentInCurrentChat(.codexExec))
                    let destinationModel = AgentModel.gpt6SolHigh.rawValue
                    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.animationBehavior = .none
                    var inputAppeared = false
                    let composerBodiesBeforeMount = (AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 1)["counters"] as? [String: Int])?["ui.body.composer"] ?? 0
                    let host = NSHostingView(rootView: AnyView(
                        input
                            .environment(\.agentModePerfRecorder, AppAgentModePerfRecorder())
                            .onAppear { inputAppeared = true }
                    ))
                    window.contentView = host
                    window.orderFront(nil)
                    host.layoutSubtreeIfNeeded()
                    defer {
                        if let sheet = window.attachedSheet { window.endSheet(sheet) }
                        window.orderOut(nil)
                        window.close()
                    }
                    // A real picker is used only after its composer has mounted. Observe that
                    // lifecycle boundary without priming a sheet or delaying production code.
                    try await AsyncTestWait.waitUntil("production InputBar appeared", timeout: 2) {
                        inputAppeared && host.window === window
                    }
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    try await AsyncTestWait.waitUntil("instrumented composer native editor mounted", timeout: 2) {
                        self.findPickerEditor(in: host)?.window === window
                    }
                    let settled = expectation(description: "Mounted composer render settles")
                    RunLoop.main.perform {
                        MainActor.assumeIsolated {
                            host.layoutSubtreeIfNeeded()
                            host.displayIfNeeded()
                            settled.fulfill()
                        }
                    }
                    await fulfillment(of: [settled], timeout: 2)
                    let composerBodiesBefore = (AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 1)["counters"] as? [String: Int])?["ui.body.composer"] ?? 0
                    XCTAssertGreaterThan(composerBodiesBefore, composerBodiesBeforeMount, "Mounting the real composer must increment the counter.")
                    let composerRevision = vm.ui.composer.revision
                    let publicationCount = 10
                    var sidebarPublications = 0
                    let sidebarObservation = vm.$sessionSidebarSearchText.dropFirst().sink { _ in sidebarPublications += 1 }
                    defer { sidebarObservation.cancel() }
                    for publication in 0 ..< publicationCount {
                        vm.sessionSidebarSearchText = "unrelated sidebar search \(publication)"
                        let rendered = expectation(description: "Sidebar publication \(publication) reaches hosted render")
                        RunLoop.main.perform {
                            MainActor.assumeIsolated {
                                host.layoutSubtreeIfNeeded()
                                host.displayIfNeeded()
                                rendered.fulfill()
                            }
                        }
                        await fulfillment(of: [rendered], timeout: 2)
                    }
                    let composerBodiesAfter = (AgentModePerfDiagnostics.debugStateSnapshot(lineLimit: 1)["counters"] as? [String: Int])?["ui.body.composer"] ?? 0
                    XCTAssertEqual(sidebarPublications, publicationCount, "Distinct writes must really publish on the observed VM.")
                    XCTAssertEqual(vm.ui.composer.revision, composerRevision, "Sidebar searches must not change composer inputs.")
                    XCTContext.runActivity(named: "Unrelated VM publications: \(sidebarPublications); composer bodies: \(composerBodiesBefore) → \(composerBodiesAfter)") { _ in
                        XCTAssertEqual(composerBodiesAfter, composerBodiesBefore, "The observed presentation wrapper must preserve the equatable composer boundary.")
                    }
                    XCTAssertNil(window.attachedSheet)
                    var previewEvents: [String] = []
                    var previewWasInstalled = false
                    let observation = vm.$providerSwitchPreview.sink { preview in
                        if let preview {
                            previewWasInstalled = true
                            previewEvents.append(preview.building ? "building" : "ready")
                        } else { previewEvents.append("nil") }
                    }
                    defer { observation.cancel() }
                    XCTAssertEqual(vm.currentTabID, session.tabID)
                    XCTAssertFalse(vm.ui.composer.props.areModelControlsDisabled)
                    composer.actions.selectAgentModel(.codexExec, destinationModel)
                    XCTAssertEqual(session.selectedAgent, .claudeCode)
                    XCTAssertEqual(session.selectedModelRaw, sourceModel)
                    XCTAssertEqual(session.currentRestorationBindingToken, binding)
                    XCTAssertEqual(fixture.window.workspaceManager.activeWorkspaceID, workspaceID)
                    XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                    XCTAssertEqual(providerConstructions, 0)
                    XCTAssertNil(session.agentTask)
                    XCTAssertNil(session.activeRunOwnership)
                    XCTAssertNil(session.codexController)
                    XCTAssertNil(session.claudeController)
                    var presented = false
                    do {
                        try await AsyncTestWait.waitUntil("production picker review sheet appears", timeout: 2) { window.attachedSheet != nil }
                        presented = true
                    } catch {}
                    let productionEvents = previewEvents
                    let installedInProduction = previewWasInstalled
                    let ownerStillMatches = vm.sessions[session.tabID] === session
                        && session.currentRestorationBindingToken == binding
                        && fixture.window.workspaceManager.activeWorkspaceID == workspaceID
                    if !presented {
                        // Same observation/binding/sheet content with a persistent presentation leaf.
                        // A passing control is necessary before attributing absence to the presenter.
                        host.rootView = AnyView(PickerStablePresentationControl(viewModel: vm, session: session))
                        host.layoutSubtreeIfNeeded()
                        composer.actions.selectAgentModel(.codexExec, destinationModel)
                        try await AsyncTestWait.waitUntil("stable-anchor headless presentation control", timeout: 2) {
                            window.attachedSheet != nil && vm.providerSwitchPreview?.building == false
                        }
                    }
                    XCTAssertTrue(installedInProduction, "The real callback must install its preview; events=\(productionEvents)")
                    XCTAssertTrue(ownerStillMatches)
                    XCTAssertEqual(vm.providerSwitchPreview?.destination, .codexExec)
                    XCTAssertEqual(session.selectedAgent, .claudeCode)
                    XCTAssertEqual(session.selectedModelRaw, sourceModel)
                    XCTAssertEqual(providerConstructions, 0)
                    XCTAssertTrue(presented, "The production InputBar picker must display Review with no pending handover; additionalWindow=\(additionalWindow)")
                    vm.cancelProviderSwitchPreview()
                    try await AsyncTestWait.waitUntil("production picker Review closes", timeout: 2) {
                        vm.providerSwitchPreview == nil && window.attachedSheet == nil
                    }
                } catch {
                    for fixture in fixtures.reversed() {
                        await cleanup(fixture)
                    }
                    throw error
                }
                for fixture in fixtures.reversed() {
                    await cleanup(fixture)
                }
            }
        }

        func testMountedComposerKeepsNativeEditorAcrossSessionLookupTransitions() async throws {
            _ = NSApplication.shared
            var providerConstructions = 0
            let fixture = try await makeFixture(pickerProviderConstruction: { providerConstructions += 1 })
            do {
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_removeSession(tabID: session.tabID)
                XCTAssertNil(vm.sessions[session.tabID])
                let input = AgentInputBar(
                    agentModeVM: vm, composerUI: vm.ui.composer, statusPillsUI: vm.ui.statusPills,
                    openContextDrawerFiles: {}, oracleViewModel: fixture.window.oracleViewModel,
                    promptManager: fixture.window.promptManager, workspaceSearchService: fixture.window.workspaceSearchService,
                    selectionCoordinator: fixture.window.selectionCoordinator, runtimeVM: AgentRuntimeSidebarViewModel(),
                    windowID: fixture.window.windowID, currentTabID: session.tabID,
                    resetTextFieldTrigger: .constant(false), composerBottomInset: .constant(0), transcriptBottomClearance: .constant(0)
                )
                // Render the actual body at each lookup boundary with the same cached composer
                // props/tab ID. Draft restoration may materialize a runtime during mounting.
                let host = NSHostingView(rootView: AnyView(input.body))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil)
                    window.close()
                }
                try await AsyncTestWait.waitUntil("production composer native editor mounted", timeout: 2) {
                    self.findPickerEditor(in: host)?.window === window
                }
                let originalEditor = try XCTUnwrap(findPickerEditor(in: host))
                for sessionPresent in [true, false, true] {
                    if sessionPresent { vm.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: session) }
                    else { vm.test_removeSession(tabID: session.tabID) }
                    XCTAssertEqual(vm.sessions[session.tabID] != nil, sessionPresent)
                    host.rootView = AnyView(input.body)
                    let rendered = expectation(description: "Session lookup render reaches hosted composer")
                    RunLoop.main.perform {
                        MainActor.assumeIsolated {
                            host.layoutSubtreeIfNeeded()
                            host.displayIfNeeded()
                            rendered.fulfill()
                        }
                    }
                    await fulfillment(of: [rendered], timeout: 2)
                    let editor = try XCTUnwrap(findPickerEditor(in: host))
                    XCTAssertTrue(editor === originalEditor, "Session lookup presence=\(sessionPresent) must not replace the native composer")
                    XCTAssertTrue(editor.window === window)
                    XCTAssertNil(window.attachedSheet, "Absent preview must never present, including nil session/nil preview")
                    XCTAssertNil(vm.providerSwitchPreview)
                    XCTAssertEqual(providerConstructions, 0)
                }
            } catch {
                await cleanup(fixture)
                throw error
            }
            await cleanup(fixture)
        }

        private func findPickerEditor(in view: NSView) -> AttachmentAwareTextView? {
            if let editor = view as? AttachmentAwareTextView { return editor }
            for child in view.subviews {
                if let editor = findPickerEditor(in: child) { return editor }
            }
            return nil
        }

        private struct PickerStablePresentationControl: View {
            @ObservedObject var viewModel: AgentModeViewModel
            @ObservedObject var session: AgentTabSession

            var body: some View {
                Color.clear.sheet(isPresented: Binding(
                    get: { viewModel.providerSwitchPreview?.session === session },
                    set: { if !$0 { viewModel.cancelProviderSwitchPreview() } }
                )) { AgentProviderSwitchPreview(viewModel: viewModel) }
            }
        }

        private func findPickerView<T>(in value: Any, as type: T.Type, depth: Int = 0) -> T? {
            if let result = value as? T { return result }
            guard depth < 12 else { return nil }
            let mirror = Mirror(reflecting: value)
            guard mirror.displayStyle != .class else { return nil }
            for child in mirror.children {
                if let result = findPickerView(in: child.value, as: type, depth: depth + 1) { return result }
            }
            return nil
        }

        @MainActor
        private final class SwitchGate {
            private var released = false
            private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
            private(set) var entries = 0
            private(set) var returns = 0
            var entered: Bool {
                entries > 0
            }

            /// Completion includes cancellation of an individual waiter.
            var returned: Bool {
                returns > 0
            }

            var waiting: Int {
                waiters.count
            }

            func wait() async {
                entries += 1
                if !released {
                    let id = UUID()
                    let (stream, continuation) = AsyncStream<Void>.makeStream()
                    waiters[id] = continuation
                    for await _ in stream {}
                    waiters.removeValue(forKey: id)
                }
                returns += 1
            }

            func open() {
                released = true
                let pending = Array(waiters.values)
                waiters.removeAll()
                for waiter in pending {
                    waiter.finish()
                }
            }
        }

        func testSwitchGateCancellationDoesNotReleaseOtherWaiters() async throws {
            let gate = SwitchGate()
            let first = Task { await gate.wait() }
            let second = Task { await gate.wait() }
            defer { gate.open()
                first.cancel()
                second.cancel()
            }
            try await AsyncTestWait.waitUntil("both independent gate waiters entered") { gate.waiting == 2 }
            first.cancel()
            await first.value
            XCTAssertEqual(gate.returns, 1)
            XCTAssertEqual(gate.waiting, 1)
            gate.open()
            await second.value
            await gate.wait()
            XCTAssertEqual(gate.returns, 3)
            XCTAssertEqual(gate.waiting, 0)
        }

        func testSwitchPreviewExpiryAndCloseFenceLateCatalogPublication() async throws {
            for close in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let catalog = vm.test_providerSwitchSkillCatalog
                    vm.storeDraftText(for: fixture.sourceSession.tabID, "preview lookup requires skill discovery")
                    let discovery = SwitchGate()
                    let deadline = SwitchGate()
                    catalog.test_beforePublish = { await discovery.wait() }
                    catalog.markDirty(reason: "exercise preview discovery publication")
                    vm.test_providerSwitchDeadlineGates[.previewAugmentation] = { await deadline.wait() }
                    defer { discovery.open()
                        deadline.open()
                        catalog.test_beforePublish = nil
                    }
                    let build = Task { await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: fixture.sourceSession.tabID) }
                    try await AsyncTestWait.waitUntil("preview catalog discovery suspended") { discovery.entered }
                    if close {
                        vm.cancelProviderSwitchPreview()
                    }
                    deadline.open()
                    _ = await build.value
                    if close {
                        XCTAssertNil(vm.providerSwitchPreview)
                    } else {
                        XCTAssertFalse(try XCTUnwrap(vm.providerSwitchPreview).building)
                        XCTAssertNotNil(vm.providerSwitchPreview?.failure)
                        XCTAssertTrue(vm.providerSwitchPreview?.choices.isEmpty == true)
                    }
                    discovery.open()
                    try await AsyncTestWait.waitUntil("late discovery drained") { discovery.returned }
                    if close {
                        XCTAssertNil(vm.providerSwitchPreview)
                    } else {
                        XCTAssertTrue(vm.providerSwitchPreview?.choices.isEmpty == true)
                    }
                }
            }
        }

        func testSwitchIdleDeadlineReleasesGenerateAndApplyWithoutLateMutation() async throws {
            for generate in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    let probe = SwitchGate()
                    let deadline = SwitchGate()
                    vm.test_providerSwitchIdleProbe = { _ in await probe.wait() }
                    vm.test_providerSwitchDeadlineGates[.idleProbe] = { await deadline.wait() }
                    var retirements = 0
                    vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                    let rows = session.items.map(\.id)
                    let original = session.selectedAgent
                    defer { probe.open()
                        deadline.open()
                    }
                    let operation = Task {
                        if generate {
                            await vm.generateProviderSwitchHandover(id)
                            return false
                        }
                        return await vm.applyProviderSwitch(id)
                    }
                    try await AsyncTestWait.waitUntil("idle probe suspended") { probe.entered }
                    deadline.open()
                    let result = await operation.value
                    XCTAssertFalse(result)
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                    XCTAssertNil(vm.providerSwitchMutation)
                    XCTAssertEqual(session.items.map(\.id), rows)
                    XCTAssertNotNil(vm.providerSwitchPreview?.failure)
                    probe.open()
                    try await AsyncTestWait.waitUntil("late idle probe drained") { probe.returned }
                    XCTAssertEqual(retirements, 0)
                    XCTAssertEqual(session.selectedAgent, original)
                    XCTAssertEqual(session.items.map(\.id), rows)
                }
            }
        }

        func testSwitchCloseBeforeDetachCancelsAndDoesNotRestoreForeignChanges() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let probe = SwitchGate()
                vm.test_providerSwitchIdleProbe = { _ in await probe.wait() }
                defer { probe.open() }
                var retirements = 0
                vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                let operation = Task { await vm.applyProviderSwitch(id) }
                try await AsyncTestWait.waitUntil("apply preparing") { probe.entered }
                session.codexRolloutPath = "/foreign/change"
                vm.cancelProviderSwitchPreview()
                XCTAssertNil(vm.providerSwitchMutation)
                XCTAssertNil(vm.providerSwitchPreview)
                probe.open()
                let result = await operation.value
                XCTAssertFalse(result)
                XCTAssertEqual(retirements, 0)
                XCTAssertEqual(session.codexRolloutPath, "/foreign/change")
                XCTAssertNil(session.activeComposerSubmitAttempt)
            }
        }

        func testSwitchCloseAfterDetachCompletesAndLateTailCannotOverwriteSuccessor() async throws {
            for expires in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.codexComputerUseArmingRequestID = UUID()
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    let tail = SwitchGate()
                    let deadline = SwitchGate()
                    vm.test_providerSwitchRetirement = { _ in await tail.wait() }
                    vm.test_providerSwitchDeadlineGates[.retirementTail] = { await deadline.wait() }
                    defer { tail.open()
                        deadline.open()
                    }
                    var saves = 0
                    vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                        return fixture.rootURL.appendingPathComponent("switch.json")
                    }
                    let operation = Task { await vm.applyProviderSwitch(id) }
                    try await AsyncTestWait.waitUntil("detached tail suspended") { tail.entered }
                    XCTAssertEqual(vm.providerSwitchMutation?.phase, .detached)
                    XCTAssertNil(session.codexComputerUseArmingRequestID)
                    vm.storeDraftText(for: session.tabID, "draft edited after detach")
                    vm.cancelProviderSwitchPreview()
                    XCTAssertTrue(vm.providerSwitchIsCompletingInBackground(session))
                    XCTAssertNotNil(session.activeComposerSubmitAttempt)
                    if expires {
                        deadline.open()
                    } else {
                        tail.open()
                    }
                    let result = await operation.value
                    XCTAssertTrue(result)
                    XCTAssertEqual(saves, 1)
                    XCTAssertEqual(session.selectedAgent, .openCode)
                    XCTAssertEqual(session.draftText, "draft edited after detach")
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                    XCTAssertNil(vm.providerSwitchMutation)
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                    XCTAssertNil(vm.providerSwitchPreview)
                    XCTAssertNil(vm.providerSwitchBackgroundOutcome)
                    session.providerSessionID = "successor"
                    let slot = session.pendingHandoff
                    tail.open()
                    try await AsyncTestWait.waitUntil("late detached cleanup returned") { tail.returned }
                    XCTAssertEqual(session.providerSessionID, "successor")
                    XCTAssertEqual(session.pendingHandoff, slot)
                }
            }
        }

        func testSwitchCloseDuringRequiredSaveKeepsSingleWriterAndClaim() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let writer = SwitchGate()
                defer { writer.open() }
                var writes = 0
                vm.test_setAgentSessionSaver { _, _, _ in
                    writes += 1
                    await writer.wait()
                    return fixture.rootURL.appendingPathComponent("saved.json")
                }
                let operation = Task { await vm.applyProviderSwitch(id) }
                try await AsyncTestWait.waitUntil("required writer suspended") { writer.entered }
                vm.cancelProviderSwitchPreview()
                XCTAssertNil(vm.providerSwitchPreview)
                XCTAssertEqual(vm.providerSwitchMutation?.phase, .staged)
                XCTAssertTrue(vm.providerSwitchIsCompletingInBackground(session))
                XCTAssertNotNil(session.activeComposerSubmitAttempt)
                XCTAssertNil(vm.makeComposerSubmitTarget(tabID: session.tabID, session: session))
                let competing = await vm.openProviderSwitchPreview(agent: .openCode, model: "other", tabID: session.tabID)
                XCTAssertNil(competing)
                XCTAssertEqual(writes, 1)
                writer.open()
                let result = await operation.value
                XCTAssertTrue(result)
                XCTAssertEqual(writes, 1)
                XCTAssertNil(session.activeComposerSubmitAttempt)
                XCTAssertNil(vm.providerSwitchMutation)
            }
        }

        func testSwitchCloseSerializesCompetingUserSaveBehindRequiredWriter() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let writer = SwitchGate()
                defer { writer.open() }
                var writes = 0
                var activeWriters = 0
                var maximumWriters = 0
                var savedNames: [String] = []
                vm.test_setAgentSessionSaver { saved, _, _ in
                    writes += 1
                    activeWriters += 1
                    maximumWriters = max(maximumWriters, activeWriters)
                    defer { activeWriters -= 1 }
                    savedNames.append(saved.name)
                    await writer.wait()
                    return fixture.rootURL.appendingPathComponent("serialized.json")
                }
                let operation = Task { await vm.applyProviderSwitch(id) }
                try await AsyncTestWait.waitUntil("required writer held") { writer.entered }
                vm.cancelProviderSwitchPreview()
                vm.renameSession(tabID: session.tabID, to: "User title while writer is held")
                let userSave = try XCTUnwrap(session.saveDebounceTask)
                await userSave.value
                XCTAssertEqual(writes, 1, "The user save must defer, not enter another writer")
                XCTAssertEqual(activeWriters, 1)
                XCTAssertNotNil(session.activeComposerSubmitAttempt)
                XCTAssertEqual(vm.providerSwitchMutation?.phase, .staged)
                writer.open()
                let applied = await operation.value
                XCTAssertFalse(applied, "A changed committing snapshot retains the existing may-commit failure policy")
                await session.saveDebounceTask?.value
                XCTAssertEqual(writes, 2, "The existing user request resumes once after the required writer returns")
                XCTAssertEqual(maximumWriters, 1)
                XCTAssertEqual(savedNames.last, "User title while writer is held")
                XCTAssertEqual(session.selectedAgent, .openCode)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                XCTAssertNil(session.activeComposerSubmitAttempt)
                XCTAssertNotNil(vm.providerSwitchBackgroundOutcome)
            }
        }

        func testSwitchCloseAndTabChangeKeepOtherTabsPresentationOwned() async throws {
            for beforeWriteFailure in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let source = fixture.sourceSession
                    let sourceAgent = source.selectedAgent
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: source.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    let tail = SwitchGate()
                    defer { tail.open()
                        source.isInstallingHandoffWorktreeBindings = false
                    }
                    vm.test_providerSwitchRetirement = { _ in await tail.wait() }
                    vm.test_providerSwitchBeforeSave = { session in
                        if beforeWriteFailure { session.isInstallingHandoffWorktreeBindings = true }
                    }
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("inactive-source.json") }
                    let operation = Task { await vm.applyProviderSwitch(id) }
                    try await AsyncTestWait.waitUntil("source retired with sheet still open") { tail.entered }
                    vm.cancelProviderSwitchPreview()
                    _ = await fixture.window.promptManager.createBlankComposeTab()
                    let otherID = try XCTUnwrap(vm.currentTabID)
                    XCTAssertNotEqual(otherID, source.tabID)
                    let other = vm.session(for: otherID)
                    other.selectedAgent = .codexExec
                    XCTAssertNotEqual(other.selectedAgent, sourceAgent)
                    let marker = AgentChatItem.user("Other tab remains visible", sequenceIndex: other.nextSequenceIndex)
                    other.appendItem(marker)
                    // Finish this new tab's own first-save binding transition before comparing
                    // its presentation across the still-suspended source transaction.
                    await other.saveDebounceTask?.value
                    vm.updateBindingsFromSession(other)
                    let presentation = vm.activeTranscriptPresentation
                    XCTAssertEqual(presentation.tabID, otherID)
                    XCTAssertEqual(presentation.visibleRows.map(\.id), [marker.id])
                    tail.open()
                    let applied = await operation.value
                    XCTAssertEqual(applied, !beforeWriteFailure)
                    XCTAssertEqual(source.selectedAgent, beforeWriteFailure ? sourceAgent : .openCode)
                    XCTAssertEqual(source.pendingHandoff.providerSwitchDelivery, beforeWriteFailure ? nil : .ready)
                    XCTAssertEqual(vm.currentTabID, otherID)
                    XCTAssertEqual(vm.selectedAgent, other.selectedAgent)
                    XCTAssertEqual(vm.selectedModelRaw, other.selectedModelRaw)
                    XCTAssertEqual(vm.activeTranscriptPresentation.tabID, otherID)
                    XCTAssertEqual(vm.activeTranscriptPresentation.visibleRows, presentation.visibleRows)
                    XCTAssertEqual(vm.activeTranscriptPresentation.workingRows, presentation.workingRows)
                    XCTAssertEqual(vm.activeTranscriptPresentation.visibleBlocks, presentation.visibleBlocks)
                    XCTAssertEqual(vm.activeTranscriptPresentation.workingBlocks, presentation.workingBlocks)
                    XCTAssertEqual(vm.activeTranscriptPresentation.hydratedPersistentBinding, other.authoritativeHydratedBinding)
                    XCTAssertEqual(other.items.last?.text, "Other tab remains visible")
                    XCTAssertNil(source.activeComposerSubmitAttempt)
                }
            }
        }

        func testSwitchClosedSheetSaveFailurePreservesBeforeWritePolicyWithoutErrorRows() async throws {
            enum Fault: Error { case mayCommit }
            for beforeWrite in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    let source = session.selectedAgent
                    session.providerSessionID = "source-reference"
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    vm.test_providerSwitchBeforeSave = { outgoing in
                        vm.cancelProviderSwitchPreview()
                        if beforeWrite {
                            outgoing.isInstallingHandoffWorktreeBindings = true
                        }
                    }
                    defer { session.isInstallingHandoffWorktreeBindings = false }
                    vm.test_setAgentSessionSaver { _, _, _ in throw Fault.mayCommit }
                    let errors = session.items.count(where: { $0.kind == .error })
                    let result = await vm.applyProviderSwitch(id)
                    XCTAssertFalse(result)
                    XCTAssertNotNil(vm.providerSwitchBackgroundOutcome)
                    XCTAssertEqual(session.items.count(where: { $0.kind == .error }), errors)
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                    XCTAssertEqual(session.selectedAgent, beforeWrite ? source : .openCode)
                    XCTAssertEqual(session.providerSessionID, beforeWrite ? "source-reference" : nil)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, beforeWrite ? nil : .ready)
                }
            }
        }

        func testRepromptRewriteAndAuditSurvivePendingProviderSwitch() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                try installSwitch(fixture)
                let original = "Original request"
                let approved = "Reviewed replacement brief"
                vm.storeDraftText(for: session.tabID, approved)
                let claim = try composerClaim(fixture, text: approved)
                vm.repromptDispatchOriginals[claim.attempt.id] = original
                vm.repromptDispatchTexts[claim.attempt.id] = approved
                vm.repromptAudits[claim.attempt.id] = .init(outcome: .approved)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("reprompt-switch.json") }
                var dispatched: String?
                vm.test_providerSwitchStart = { _, user, _ in dispatched = user }

                let result = await vm.executeComposerSubmitAttempt(text: approved, claim: claim)
                XCTAssertEqual(result, .submitted)
                try await AsyncTestWait.waitUntil("rewritten switched turn dispatches") { dispatched != nil }
                let sent = try XCTUnwrap(dispatched)
                XCTAssertTrue(sent.contains(approved))
                XCTAssertFalse(sent.contains(original))
                XCTAssertEqual(session.items.last(where: { $0.kind == .user })?.text, approved)
                XCTAssertEqual(session.automationTurnAudit.last?.reprompt?.outcome, .approved)
                XCTAssertNil(session.activeComposerSubmitAttempt)
            }
        }

        func testProviderSwitchHandoverAugmentationHonorsLiteralRepromptText() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                let directory = fixture.rootURL.appendingPathComponent(".agents/skills/literal", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let skillBody = "SKILL_EXPANSION_MUST_NOT_REPLACE_REPROMPT"
                try "---\nname: literal\ndescription: Fixture\n---\n\(skillBody)".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                try installSwitch(fixture)
                let approved = "/literal reviewed brief"
                guard case let .success(expanded) = await vm.providerSwitchSendAdmission(session: session, input: approved),
                      let expanded else { return XCTFail("Ordinary skill input must be admitted") }
                XCTAssertTrue(expanded.augmentedInput.contains(skillBody), "Control must exercise real skill expansion")

                guard case let .success(literal) = await vm.providerSwitchSendAdmission(session: session, input: approved, skipsSlashExpansion: true),
                      let literal else { return XCTFail("Literal re-prompt input must be admitted") }
                XCTAssertTrue(literal.augmentedInput.contains(approved))
                XCTAssertFalse(literal.augmentedInput.contains(skillBody))
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("literal-switch.json") }
                let preparedHandover = await vm.prepareProviderSwitchHandoverForSend(literal, session: session, stopFence: .init(session: session))
                let handover = try XCTUnwrap(preparedHandover)
                XCTAssertTrue(handover.user.contains(approved))
                XCTAssertFalse(handover.user.contains(skillBody))
            }
        }

        func testSwitchExpandedSkillAndTaggedFileRefusalsRetainClaimedComposer() async throws {
            for skill in [true, false] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    session.selectedAgent = .openCode
                    session.selectedModelRaw = "unknown-window"
                    let content = String(repeating: "expanded context ", count: 1000) + "END_FIXTURE"
                    let text: String
                    if skill {
                        let directory = fixture.rootURL.appendingPathComponent(".agents/skills/large", isDirectory: true)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try "---\nname: large\ndescription: Fixture\n---\n\(content)".write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                        text = "/large short"
                    } else {
                        let file = fixture.rootURL.appendingPathComponent("large.txt")
                        try content.write(to: file, atomically: true, encoding: .utf8)
                        session.pendingTaggedFileAttachments = [.init(relativePath: file.path, displayName: "large.txt")]
                        session.selectedWorkflow = .init(customID: UUID(), displayName: "Keep workflow")
                        text = "short"
                    }
                    let initial = await fixture.viewModel.buildInitialThreadMessageIfNeeded(tabID: session.tabID, session: session, initialMessage: text)
                    let budget = AgentProviderHandover.Budget(catalogWindow: nil, instructions: fixture.viewModel.providerSwitchInstructionStrings(session), composedInput: initial, isPreview: false)
                    let empty = try switchCarrier()
                    let padding = Int((budget.remainingCarrierTokens - 1000) * 4 / 1.05) - empty.utf8.count
                    try installSwitch(fixture, padding: padding)
                    // Raw text fits; the actual existing skill/file expansion must be measured instead.
                    guard case .success = await fixture.viewModel.providerSwitchSendAdmission(session: session, input: text, skipsAugmentation: true) else { return XCTFail("Raw input should fit") }
                    let expanded = await fixture.viewModel.augmentUserMessageForProviderSend(text, taggedFileAttachments: session.pendingTaggedFileAttachments, session: session, ignoresPendingHandoff: true)
                    XCTAssertTrue(expanded.contains(content), "The fixture must really expand the skill/tagged file")
                    fixture.viewModel.storeDraftText(for: session.tabID, text)
                    let workflow = session.selectedWorkflow
                    let files = session.pendingTaggedFileAttachments
                    let rows = session.items
                    let claim = try composerClaim(fixture, text: text)
                    let result = await fixture.viewModel.executeComposerSubmitAttempt(text: text, claim: claim)
                    XCTAssertEqual(result, .blocked(message: "Too long to send with the handover."))
                    XCTAssertEqual(session.draftText, text)
                    XCTAssertEqual(session.selectedWorkflow, workflow)
                    XCTAssertEqual(session.pendingTaggedFileAttachments, files)
                    XCTAssertEqual(session.items.map(\.id), rows.map(\.id))
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                    XCTAssertNil(session.agentTask)
                    XCTAssertNil(session.acpController)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                }
            }
        }

        func testSwitchCompositionAwaitsStopAndBindingCurrencyBeforeAcceptance() async throws {
            for drift in ["stop", "binding", "owner"] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    session.selectedAgent = .openCode
                    try installSwitch(fixture)
                    fixture.viewModel.storeDraftText(for: session.tabID, "keep draft")
                    var didEnterAugmentation = false
                    let release = AgentSessionLinkStopSignal<Void>()
                    defer { release.finish(()) }
                    fixture.viewModel.test_afterProviderInputAugmentation = { didEnterAugmentation = true
                        await release.value()
                    }
                    defer { fixture.viewModel.test_afterProviderInputAugmentation = nil }
                    let rows = session.items.map(\.id)
                    let claim = try composerClaim(fixture, text: "keep draft")
                    var completed: AgentModeViewModel.UserTurnSubmissionResult?
                    let submission = Task {
                        let result = await fixture.viewModel.executeComposerSubmitAttempt(text: "keep draft", claim: claim)
                        completed = result
                        return result
                    }
                    defer { submission.cancel() }
                    try await AsyncTestWait.waitUntil("composition enters its gate or refuses") { didEnterAugmentation || completed != nil }
                    guard didEnterAugmentation else { return XCTFail("Expected asynchronous composition, received \(String(describing: completed))") }
                    XCTAssertNotNil(session.activeComposerSubmitAttempt)
                    XCTAssertEqual(session.draftText, "keep draft")
                    if drift == "stop" {
                        session.stopState.invalidateScheduledStarts()
                    } else if drift == "binding" {
                        session.testInstallPersistentSessionBinding(sessionID: UUID())
                    } else {
                        fixture.viewModel.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: .init(tabID: session.tabID))
                    }
                    release.finish(())
                    let result = await submission.value
                    guard case .blocked = result else { return XCTFail("Drift during composition must refuse") }
                    XCTAssertEqual(session.items.map(\.id), rows)
                    XCTAssertEqual(session.draftText, "keep draft")
                    XCTAssertNil(session.agentTask)
                    XCTAssertNil(session.acpController)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                }
            }
        }

        func testSwitchSendingSaveAndVMOnlyReadyResaveFaults() async throws {
            enum Fault: Error { case save }
            for fault in ["sending", "ready", "none"] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    let payload = session.pendingHandoff.payload
                    let accepted = AgentChatItem.user("accepted but not dispatched", sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(accepted)
                    let fence = AgentRunStartStopFence(session: session)
                    var saves: [AgentProviderSwitchDelivery?] = []
                    fixture.viewModel.test_setAgentSessionSaver { saved, _, _ in
                        saves.append(saved.pendingHandoffProviderSwitchDelivery)
                        XCTAssertEqual(saved.pendingHandoffPayload, payload)
                        if fault == "sending" || (fault == "ready" && saves.count == 2) {
                            throw Fault.save
                        }
                        if saves.count == 1 {
                            session.stopState.invalidateScheduledStarts()
                        }
                        return fixture.rootURL.appendingPathComponent("switch.json")
                    }
                    let messages = await fixture.viewModel.prepareProviderSwitchHandoverForSend(preparation.accepting(accepted.id, session: session), session: session, stopFence: fence)
                    XCTAssertNil(messages)
                    XCTAssertEqual(saves, fault == "sending" ? [.sending] : [.sending, .ready])
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, fault == "none" ? .ready : .sending)
                    XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                    XCTAssertEqual(session.pendingHandoff.payload, payload)
                    let later = await fixture.viewModel.providerSwitchSendAdmission(session: session, input: "a later input")
                    guard case let .failure(refusal) = later else { return XCTFail("A later input cannot spend the accepted row's carrier") }
                    XCTAssertEqual(refusal, fault == "none" ? .providerHandoverNeedsReview : .providerSwitchUnconfirmed)
                    XCTAssertTrue(session.items.contains { $0.id == accepted.id })
                    XCTAssertNil(session.agentTask)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                }
            }
        }

        func testReturnedPredispatchSendingAndReadyWritesWithholdDispatchAsReadyNeedsReview() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                let handoff = session.pendingHandoff
                let accepted = AgentChatItem.user("accepted input must not be replayed", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(accepted)
                let sessionID = session.activeAgentSessionID
                let sendingRelease = AgentSessionLinkStopSignal<Void>()
                let readyRelease = AgentSessionLinkStopSignal<Void>()
                var sendingEntered = false
                var readyEntered = false
                var isAttemptUnderTest = true
                var writes: [AgentProviderSwitchDelivery?] = []
                let file = fixture.rootURL.appendingPathComponent("returned-predispatch-ready.json")
                defer {
                    isAttemptUnderTest = false
                    sendingRelease.finish(())
                    readyRelease.finish(())
                }
                vm.test_setAgentSessionSaver { saved, _, _ in
                    guard isAttemptUnderTest, saved.id == sessionID else { return file }
                    writes.append(saved.pendingHandoffProviderSwitchDelivery)
                    XCTAssertEqual(saved.pendingHandoffPayload, handoff.payload)
                    try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                    if writes.count == 1 {
                        sendingEntered = true
                        await sendingRelease.value()
                    } else if writes.count == 2 {
                        readyEntered = true
                        await readyRelease.value()
                    } else { XCTFail("Only the sending write and VM-owned ready re-save are expected") }
                    return file
                }
                var completed = false
                let attempt = Task {
                    let messages = await vm.prepareProviderSwitchHandoverForSend(preparation.accepting(accepted.id, session: session), session: session, stopFence: .init(session: session))
                    completed = true
                    return messages
                }
                defer { attempt.cancel() }
                try await AsyncTestWait.waitUntil("sending write enters or preparation settles") { sendingEntered || completed }
                guard sendingEntered else { return XCTFail("Expected the actual sending write") }
                await vm.flushSave(for: session.tabID) // Invalidate the in-flight token without invoking a runner.
                sendingRelease.finish(())
                try await AsyncTestWait.waitUntil("ready re-save enters or preparation settles") { readyEntered || completed }
                guard readyEntered else { return XCTFail("A returned sending write with no runner must enter the existing ready re-save") }
                await vm.flushSave(for: session.tabID) // The ready write also returns before stale-token refusal.
                readyRelease.finish(())
                let messages = await attempt.value
                isAttemptUnderTest = false
                XCTAssertNil(messages)
                XCTAssertEqual(writes, [.sending, .ready])
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                XCTAssertEqual(session.pendingHandoff.payload, handoff.payload)
                XCTAssertEqual(session.pendingHandoff.sourceItemID, handoff.sourceItemID)
                XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                XCTAssertNil(session.pendingHandoff.providerSwitchDispatch)
                XCTAssertNil(session.activeRunOwnership)
                XCTAssertNil(session.agentTask)
                XCTAssertTrue(session.items.contains { $0.id == accepted.id })
                XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
                let saved = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
                XCTAssertEqual(saved.pendingHandoffProviderSwitchDelivery, .ready)
                XCTAssertTrue(saved.toLiveItems().contains { $0.id == accepted.id })
                guard case .failure(.providerHandoverNeedsReview) = await vm.providerSwitchSendAdmission(session: session, input: "later input") else {
                    return XCTFail("Known no-dispatch recovery must use existing M4c, never resend")
                }
            }
        }

        func testThrownPredispatchReadyResaveRetainsSendingUncertaintyAndAcceptedInput() async throws {
            enum Fault: Error { case readyWrite }
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                let payload = session.pendingHandoff.payload
                let accepted = AgentChatItem.user("accepted input remains history only", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(accepted)
                let sessionID = session.activeAgentSessionID
                let sendingRelease = AgentSessionLinkStopSignal<Void>()
                var sendingEntered = false
                var isAttemptUnderTest = true
                var writes: [AgentProviderSwitchDelivery?] = []
                let file = fixture.rootURL.appendingPathComponent("unconfirmed-ready-resave.json")
                defer {
                    isAttemptUnderTest = false
                    sendingRelease.finish(())
                }
                vm.test_setAgentSessionSaver { saved, _, _ in
                    guard isAttemptUnderTest, saved.id == sessionID else { return file }
                    writes.append(saved.pendingHandoffProviderSwitchDelivery)
                    XCTAssertEqual(saved.pendingHandoffPayload, payload)
                    try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                    if writes.count == 1 {
                        sendingEntered = true
                        await sendingRelease.value()
                        return file
                    }
                    XCTAssertEqual(saved.pendingHandoffProviderSwitchDelivery, .ready)
                    throw Fault.readyWrite // Even an actual write is unacknowledged when its saver throws.
                }
                var completed = false
                let attempt = Task {
                    let messages = await vm.prepareProviderSwitchHandoverForSend(preparation.accepting(accepted.id, session: session), session: session, stopFence: .init(session: session))
                    completed = true
                    return messages
                }
                defer { attempt.cancel() }
                try await AsyncTestWait.waitUntil("sending write enters or preparation settles") { sendingEntered || completed }
                guard sendingEntered else { return XCTFail("Expected the actual sending write") }
                await vm.flushSave(for: session.tabID)
                sendingRelease.finish(())
                let messages = await attempt.value
                isAttemptUnderTest = false
                XCTAssertNil(messages)
                XCTAssertEqual(writes, [.sending, .ready])
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                XCTAssertEqual(session.pendingHandoff.payload, payload)
                XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                XCTAssertNil(session.pendingHandoff.providerSwitchDispatch)
                XCTAssertNil(session.activeRunOwnership)
                XCTAssertNil(session.agentTask)
                XCTAssertTrue(session.items.contains { $0.id == accepted.id })
                XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
                guard case .failure(.providerSwitchUnconfirmed) = await vm.providerSwitchSendAdmission(session: session, input: "later input") else {
                    return XCTFail("A thrown ready re-save must remain existing M4a uncertainty")
                }
            }
        }

        func testSwitchExactStagedPhysicalSendClearsOnceAndClearSaveFailureRestoresUncertainty() async throws {
            enum Fault: Error { case clear }
            for clearFails in [false, true] {
                try await withFixture { fixture in
                    let session = fixture.sourceSession
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    let payload = try XCTUnwrap(session.pendingHandoff.payload)
                    var saves: [AgentSession] = []
                    fixture.viewModel.test_setAgentSessionSaver { saved, _, _ in
                        saves.append(saved)
                        if clearFails, saved.pendingHandoffProviderSwitchDelivery == nil {
                            throw Fault.clear
                        }
                        return fixture.rootURL.appendingPathComponent("switch.json")
                    }
                    let messages = await fixture.viewModel.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertEqual(messages?.user, payload + "\n\n" + preparation.augmentedInput)
                    XCTAssertEqual(messages?.initial, payload + "\n\n" + preparation.initialThreadInput)
                    XCTAssertEqual(saves.map(\.pendingHandoffProviderSwitchDelivery), [.sending])
                    XCTAssertEqual(fixture.viewModel.prependPendingHandoffIfNeeded("ordinary", session: session), "ordinary")
                    let runID = UUID()
                    session.installRunID(runID)
                    session.beginRunAttempt(source: "test.switch.physical")
                    let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: runID)
                    XCTAssertTrue(fixture.viewModel.providerSwitchAcquirePhysicalDispatch(session: session, dispatchID: dispatch))
                    let other = AgentSessionLinkDispatchContext(session: session, dispatchID: .headlessRun(runID: UUID()))
                    fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: other)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    let context = AgentSessionLinkDispatchContext(session: session, dispatchID: dispatch)
                    fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
                    fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
                    try await AsyncTestWait.waitUntil("clear save settles") {
                        saves.count >= 2 && (clearFails ? session.pendingHandoff.providerSwitchDelivery == .sending : session.pendingHandoff.providerSwitchDelivery == nil)
                    }
                    session.saveDebounceTask?.cancel()
                    session.saveDebounceTask = nil
                    XCTAssertEqual(session.items.filter { $0.recoveryDiagnostic?.reason == "providerSwitch" }.map(\.text), ["Handover sent to \(session.selectedAgent.displayName) / \(fixture.viewModel.inputBarModelDisplayName(rawModel: session.selectedModelRaw, agentKind: session.selectedAgent))."])
                    XCTAssertEqual(session.pendingHandoff.payload, clearFails ? payload : nil)
                    XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                    XCTAssertNil(session.agentTask)
                }
            }
        }

        func testSwitchAcceptedClearKeepsSuccessfulWriteDespitePostWriteDeferral() async throws {
            enum Fault: Error { case afterWrite }
            for drift in ["saveRequest", "transcript", "throwAfterWrite"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    vm.test_setSuppressesAgentSessionPersistence(false)
                    defer {
                        session.saveDebounceTask?.cancel()
                        session.saveDebounceTask = nil
                        vm.test_setSuppressesAgentSessionPersistence(nil)
                    }
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    let payload = try XCTUnwrap(session.pendingHandoff.payload)
                    let file = fixture.rootURL.appendingPathComponent("accepted-clear.json")
                    let release = AgentSessionLinkStopSignal<Void>()
                    defer { release.finish(()) }
                    var writes: [AgentSession] = []
                    var clearWriteEntered = false
                    vm.test_setAgentSessionSaver { saved, _, _ in
                        try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                        writes.append(saved)
                        if writes.count == 2 {
                            XCTAssertNil(saved.pendingHandoffProviderSwitchDelivery)
                            XCTAssertNil(saved.pendingHandoffPayload)
                            clearWriteEntered = true
                            await release.value()
                            if drift == "throwAfterWrite" { throw Fault.afterWrite }
                        }
                        return file
                    }
                    let messages = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertNotNil(messages)
                    let runID = UUID()
                    session.installRunID(runID)
                    session.beginRunAttempt(source: "test.switch.postWriteClear")
                    let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: runID)
                    XCTAssertTrue(vm.providerSwitchAcquirePhysicalDispatch(session: session, dispatchID: dispatch))
                    let context = AgentSessionLinkDispatchContext(session: session, dispatchID: dispatch)
                    vm.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
                    try await AsyncTestWait.waitUntil("accepted clear reaches the saver gate") { clearWriteEntered }
                    let writtenClear = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
                    XCTAssertNil(writtenClear.pendingHandoffPayload)
                    XCTAssertEqual(writtenClear.toLiveItems().count(where: { $0.recoveryDiagnostic?.outcome == "sent" }), 1)
                    if drift == "transcript" {
                        session.appendItem(.assistant("Later streaming output", sequenceIndex: session.nextSequenceIndex))
                    } else {
                        // A real concurrent save request invalidates the in-flight commit token.
                        await vm.flushSave(for: session.tabID)
                    }
                    release.finish(())
                    try await AsyncTestWait.waitUntil("existing fresh-save owner persists the settled carrier") { writes.count >= 3 && !session.isDirty }
                    let latest = try JSONDecoder().decode(AgentSession.self, from: Data(contentsOf: file))
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, drift == "throwAfterWrite" ? .sending : nil, drift)
                    XCTAssertEqual(latest.pendingHandoffProviderSwitchDelivery, drift == "throwAfterWrite" ? .sending : nil, drift)
                    XCTAssertEqual(session.pendingHandoff.payload, drift == "throwAfterWrite" ? payload : nil, drift)
                    XCTAssertEqual(latest.pendingHandoffPayload, drift == "throwAfterWrite" ? payload : nil, drift)
                    XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                    XCTAssertNil(session.pendingHandoff.providerSwitchDispatch)
                    XCTAssertEqual(latest.toLiveItems().count(where: { $0.recoveryDiagnostic?.outcome == "sent" }), 1)
                    if drift == "transcript" {
                        XCTAssertTrue(latest.toLiveItems().contains { $0.text == "Later streaming output" })
                    }
                }
            }
        }

        func testSwitchLatePhysicalAcceptanceCannotClearReboundSlot() async throws {
            try await withFixture { fixture in
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                fixture.viewModel.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("switch.json") }
                _ = await fixture.viewModel.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                let runID = UUID()
                session.installRunID(runID)
                session.beginRunAttempt(source: "test.switch.latePhysical")
                let dispatch = AgentSessionLinkPromptDispatchID.headlessRun(runID: runID)
                XCTAssertTrue(fixture.viewModel.providerSwitchAcquirePhysicalDispatch(session: session, dispatchID: dispatch))
                let context = AgentSessionLinkDispatchContext(session: session, dispatchID: dispatch)
                let staged = session.pendingHandoff
                let rows = session.items.map(\.id)
                session.testInstallPersistentSessionBinding(sessionID: UUID())
                fixture.viewModel.providerSwitchRecordPhysicalAcceptance(session: session, context: context)
                XCTAssertEqual(session.pendingHandoff, staged)
                XCTAssertEqual(session.items.map(\.id), rows)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
            }
        }

        func testSwitchSaveEvidenceDistinguishesPrewriteFromPossibleCommit() async throws {
            enum Fault: Error { case write }
            try await withFixture { fixture in
                let session = fixture.sourceSession
                let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID)
                var phases: [AgentModeViewModel.RequiredSavePhase] = []
                let prewrite = await fixture.viewModel.flushSaveRequired(for: session.tabID, workspaceID: UUID(), observingSavePhase: { phases.append($0) })
                guard case .failure = prewrite else { return XCTFail("Wrong workspace must refuse before write") }
                XCTAssertEqual(phases, [.beforeWrite])
                fixture.viewModel.test_setAgentSessionSaver { _, _, _ in throw Fault.write }
                phases = []
                session.isDirty = true
                let write = await fixture.viewModel.flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: { phases.append($0) })
                guard case .failure = write else { return XCTFail("Scripted write must fail") }
                XCTAssertEqual(phases, [.beforeWrite, .writeMayHaveCommitted])

                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                var entered = false
                fixture.viewModel.test_setAgentSessionSaver { saved, _, _ in
                    let file = fixture.rootURL.appendingPathComponent("returned-write.json")
                    try JSONEncoder().encode(saved).write(to: file, options: .atomic)
                    entered = true
                    await release.value()
                    return file
                }
                phases = []
                let deferred = Task {
                    await fixture.viewModel.flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: { phases.append($0) })
                }
                defer { deferred.cancel() }
                try await AsyncTestWait.waitUntil("required save reaches its frozen write") { entered }
                await fixture.viewModel.flushSave(for: session.tabID)
                release.finish(())
                guard case .failure = await deferred.value else { return XCTFail("A successful write with stale currency must still defer the generic required flush") }
                XCTAssertEqual(phases, [.beforeWrite, .writeMayHaveCommitted, .writeReturned])
                XCTAssertTrue(session.isDirty)

                phases = []
                let saved = await fixture.viewModel.flushSaveRequired(for: session.tabID, workspaceID: workspaceID, observingSavePhase: { phases.append($0) })
                guard case .success = saved else { return XCTFail("An unchanged write must retain ordinary required-save success") }
                XCTAssertEqual(phases, try [.beforeWrite, .writeMayHaveCommitted, .writeReturned, .durablySaved(XCTUnwrap(session.currentRestorationBindingToken))])
            }
        }

        func testSwitchLinkedPostAuthorizationFitDriftAndOrphanIngressRefuseBeforeAcceptance() async throws {
            try await withFixture { fixture in
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
                let candidate = try XCTUnwrap(fixture.viewModel.agentSessionLinkCandidate(tabID: session.tabID, sessionID: endpoint.sessionID, tabName: "Target", isWindowClosing: false))
                let request = AgentSessionLinkSendRequest(linkID: UUID(), linkGeneration: 1, observerEndpoint: endpoint, observerDisplayName: "Observer", message: "assigned task", workflow: nil)
                let rows = session.items.map(\.id)
                var commits = 0
                let refused = await fixture.viewModel.agentSessionLinkPerformSend(to: candidate, request: request, liveness: {
                    .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false)
                }, commitAuthorization: {
                    commits += 1
                    session.pendingHandoff.payload = String(repeating: "x", count: AgentProviderHandover.maximumBytes + 1)
                    return .committed
                })
                XCTAssertEqual(refused, .blocked(.providerHandoverDoesNotFit))
                XCTAssertEqual(commits, 1)
                XCTAssertEqual(session.items.map(\.id), rows)
                XCTAssertNil(session.activeComposerSubmitAttempt)
                session.pendingHandoff.providerSwitchDelivery = .sending
                fixture.viewModel.storeDraftText(for: session.tabID, "retained")
                XCTAssertEqual(fixture.viewModel.submitUserTurn(text: "retained", tabID: session.tabID), .blocked(message: AgentSessionLinkSendFailure.providerSwitchUnconfirmed.message))
                let recorder = AgentRunStartOutcomeRecorder()
                _ = await fixture.viewModel.startAgentRun(tabID: session.tabID, initialMessage: "forbidden", startOutcome: recorder)
                XCTAssertFalse(recorder.outcome.didStart)
                let orphan = await fixture.viewModel.agentSessionLinkPerformSend(to: candidate, request: request, liveness: {
                    .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false)
                }, commitAuthorization: { commits += 1
                    return .committed
                })
                XCTAssertEqual(orphan, .blocked(.providerSwitchUnconfirmed))
                XCTAssertEqual(commits, 1)
                XCTAssertEqual(session.items.map(\.id), rows)
                XCTAssertEqual(session.draftText, "retained")
                XCTAssertNil(session.agentTask)
                XCTAssertNil(session.claudeController)
            }
        }

        func testSwitchAutoWakeContinuationAndPeriodicRefuseOnceWithoutDispatchOrRows() async throws {
            for periodic in [false, true] {
                for unconfirmed in [false, true] {
                    try await withFixture { fixture in
                        let session = fixture.sourceSession
                        session.selectedAgent = .openCode
                        try installSwitch(fixture)
                        if unconfirmed {
                            session.pendingHandoff.providerSwitchDelivery = .sending
                        } else {
                            session.appendItem(.user("accepted after cutoff", sequenceIndex: session.nextSequenceIndex))
                        }
                        session.installRunID(UUID())
                        let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: session.tabID))
                        var rows = session.items.map(\.id)
                        var settlements = 0
                        var sawAttempt = false
                        let observation = session.monitorReadinessChangePublisher.sink { _ in
                            MainActor.assumeIsolated {
                                if session.oversight.pendingAutoWake != nil {
                                    sawAttempt = true
                                } else if sawAttempt {
                                    settlements += 1
                                    sawAttempt = false
                                }
                            }
                        }
                        defer { observation.cancel() }
                        if periodic {
                            let attempt = AgentSessionLinkAutoWakeAttempt(
                                wakeID: UUID(), observerEndpoint: endpoint, queueEpoch: nil, queueRevision: 0,
                                wakeFingerprint: nil, admissionBasis: .periodic, attemptedFingerprint: nil,
                                physicalOutcome: .notAttempted, phase: .scheduled, task: nil,
                                stopFence: .init(session: session)
                            )
                            session.oversight.pendingAutoWake = attempt
                            sawAttempt = true
                            await fixture.viewModel.agentSessionLinkRunPeriodicAttempt(attempt, session: session)
                            // A stale scheduled callback cannot reserve another attempt or start a loop.
                            fixture.viewModel.agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
                        } else {
                            let waiting = Task { try await fixture.viewModel.waitForNextUserInstruction(tabID: session.tabID, timeoutSeconds: 10) }
                            try await AsyncTestWait.waitUntil("waiting continuation installed") { session.instructionContinuation != nil }
                            // The existing wait owner publishes its prompt row before wake admission.
                            rows = session.items.map(\.id)
                            defer {
                                session.instructionTimeoutTask?.cancel()
                                session.instructionTimeoutTask = nil
                                session.instructionContinuation?.resume(throwing: CancellationError())
                                session.instructionContinuation = nil
                                session.instructionWaitID = nil
                                session.waitingPrompt = nil
                                waiting.cancel()
                            }
                            try publishSwitchWake(fixture, endpoint: endpoint)
                            let attempt = try XCTUnwrap(session.oversight.pendingAutoWake)
                            sawAttempt = true
                            await attempt.task?.value
                            XCTAssertNotNil(session.instructionContinuation, "Refusal must not resume the provider's held input")
                            fixture.viewModel.agentSessionLinkScheduleAutoWakeReevaluation(wakeID: attempt.wakeID, endpoint: endpoint)
                            session.oversight.autoWakeOnUpdates = false
                            session.instructionTimeoutTask?.cancel()
                            session.instructionTimeoutTask = nil
                            let continuation = session.instructionContinuation
                            session.instructionContinuation = nil
                            session.instructionWaitID = nil
                            continuation?.resume(throwing: CancellationError())
                            _ = try? await waiting.value
                        }
                        XCTAssertEqual(settlements, 1)
                        XCTAssertNil(session.oversight.pendingAutoWake)
                        XCTAssertEqual(session.items.map(\.id), rows)
                        XCTAssertNil(session.agentTask)
                        XCTAssertNil(session.acpController)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testIdleAutoWakeOwnsSendingPreparationUntilUnacceptedTerminalSettlement() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                try installSwitch(fixture)
                let payload = session.pendingHandoff.payload
                session.installRunID(UUID())
                let endpoint = try XCTUnwrap(vm.agentSessionLinkObserverEndpoint(tabID: session.tabID))
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                var saving = false
                var started = false
                vm.test_setAgentSessionSaver { saved, _, _ in
                    if saved.pendingHandoffProviderSwitchDelivery == .sending, !saving {
                        saving = true
                        await release.value()
                    }
                    return fixture.rootURL.appendingPathComponent("wake-sending.json")
                }
                vm.test_providerSwitchStart = { outgoing, _, _ in
                    outgoing.beginRunAttempt(source: "test.switch.autoWake.unaccepted")
                    outgoing.runState = .running
                    started = true // No physical acceptance: exercise the real terminal owner below.
                }
                try publishSwitchWake(fixture, endpoint: endpoint)
                let wake = try XCTUnwrap(session.oversight.pendingAutoWake)
                try await AsyncTestWait.waitUntil("actual idle wake reaches its sending save") { saving || session.oversight.pendingAutoWake == nil }
                guard saving else { return XCTFail("Fitting idle wake must reach the sending save") }
                XCTAssertEqual(session.oversight.pendingAutoWake?.phase, .preparingDispatch)
                XCTAssertNil(session.activeComposerSubmitAttempt)
                XCTAssertNil(session.activeRunOwnership)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDispatch?.autoWakeID, wake.wakeID)
                XCTAssertFalse(AgentModeViewModel.providerSwitchUnconfirmed(session))
                let busy = AgentSessionLinkDeliveryReadiness.failure(snapshot: AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(session: session, endpointMatchesGrant: true, isClosing: false))
                XCTAssertEqual(busy, .targetNotIdle, "An exact preparing wake is owned busy, not an orphan")
                guard case .failure(.targetNotIdle) = await vm.providerSwitchSendAdmission(session: session, input: "unrelated new input") else { return XCTFail("Concurrent input must see existing busy") }
                let preparing = try XCTUnwrap(session.oversight.pendingAutoWake)
                session.oversight.pendingAutoWake = .init(wakeID: UUID(), observerEndpoint: endpoint, queueEpoch: preparing.queueEpoch, queueRevision: 0, wakeFingerprint: preparing.wakeFingerprint, admissionBasis: preparing.admissionBasis, attemptedFingerprint: nil, physicalOutcome: .notAttempted, phase: .preparingDispatch, task: nil, stopFence: preparing.stopFence)
                XCTAssertTrue(AgentModeViewModel.providerSwitchUnconfirmed(session), "An unrelated preparing wake cannot mask this proof's orphan state")
                session.oversight.pendingAutoWake = preparing
                release.finish(())
                try await AsyncTestWait.waitUntil("wake reaches replaced transport after sending save") { started || session.oversight.pendingAutoWake == nil }
                guard started else { return XCTFail("The owned wake must continue after its save") }
                XCTAssertFalse(AgentModeViewModel.providerSwitchUnconfirmed(session))
                await vm.test_publishNaturalCompletion(session)
                await wake.task?.value
                XCTAssertNil(session.oversight.pendingAutoWake)
                XCTAssertNil(session.pendingHandoff.providerSwitchDispatch)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                XCTAssertEqual(session.pendingHandoff.payload, payload)
                XCTAssertTrue(AgentModeViewModel.providerSwitchUnconfirmed(session))
                let settled = AgentSessionLinkDeliveryReadiness.failure(snapshot: AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(session: session, endpointMatchesGrant: true, isClosing: false))
                XCTAssertEqual(settled, .providerSwitchUnconfirmed)
                XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
                XCTAssertNil(session.acpController)
            }
        }

        func testSwitchReviewRefreshesAcceptedUndispatchedInputAndNextCarrierConsumesItOnce() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let original = session.pendingHandoff
                let preparation = try await switchPreparation(fixture)
                let attributed = AgentChatItem.user(
                    "accepted linked request, never executed",
                    sequenceIndex: session.nextSequenceIndex,
                    crossSessionAttribution: .init(sourceSessionID: UUID(), sourceName: "Observer", linkID: UUID())
                )
                session.appendItem(attributed)
                let fence = AgentRunStartStopFence(session: session)
                vm.test_setAgentSessionSaver { _, _, _ in
                    session.stopState.invalidateScheduledStarts()
                    return fixture.rootURL.appendingPathComponent("source.json")
                }
                let withheld = await vm.prepareProviderSwitchHandoverForSend(preparation.accepting(attributed.id, session: session), session: session, stopFence: fence)
                XCTAssertNil(withheld)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                guard case .failure(.providerHandoverNeedsReview) = await vm.providerSwitchSendAdmission(session: session, input: "later input") else { return XCTFail("A later input cannot consume the old carrier") }
                vm.test_setAgentSessionSaver { saved, _, _ in
                    XCTAssertTrue(saved.pendingHandoffPayload?.contains("accepted linked request, never executed") == true)
                    return fixture.rootURL.appendingPathComponent("source.json")
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let review = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(review.cutoff, attributed.id)
                XCTAssertEqual(try XCTUnwrap(review.source).provider, "source")
                vm.providerSwitchPreview?.selected = .history
                let applied = await vm.applyProviderSwitch(review.id)
                XCTAssertTrue(applied)
                XCTAssertEqual(session.pendingHandoff.sourceItemID, attributed.id)
                XCTAssertNotEqual(session.pendingHandoff.payload, original.payload)
                XCTAssertNil(session.providerSessionID)
                XCTAssertNil(session.codexConversationID)
                let next = try await switchPreparation(fixture)
                let inserted = await vm.prepareProviderSwitchHandoverForSend(next, session: session, stopFence: .init(session: session))
                let user = try XCTUnwrap(inserted?.user)
                XCTAssertEqual(user.components(separatedBy: "<repoprompt_provider_handover ").count - 1, 1)
                XCTAssertTrue(user.contains("accepted linked request, never executed"))
                XCTAssertTrue(user.hasSuffix("\n\nordinary input"))
                XCTAssertNil(session.agentTask)
            }
        }

        func testOrphanReviewCancelThenSwitchStartsFreshWithUncertainInputOnlyAsHistory() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                session.pendingHandoff.providerSwitchDelivery = .sending
                session.providerSessionID = "uncertain-native"
                session.codexConversationID = "stale-other-family"
                session.codexRolloutPath = "/retained/native.jsonl"
                let uncertain = AgentChatItem.user("uncertain previous input", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(uncertain)
                let slot = session.pendingHandoff
                await vm.openProviderSwitchPreview(agent: session.selectedAgent, model: session.selectedModelRaw, tabID: session.tabID)
                vm.cancelProviderSwitchPreview()
                XCTAssertEqual(session.pendingHandoff, slot)
                XCTAssertTrue(AgentModeViewModel.providerSwitchUnconfirmed(session))
                await vm.openProviderSwitchPreview(agent: session.selectedAgent, model: session.selectedModelRaw, tabID: session.tabID)
                let review = try XCTUnwrap(vm.providerSwitchPreview)
                vm.providerSwitchPreview?.selected = .history
                var retirements = 0
                vm.test_providerSwitchRetirement = { outgoing in
                    XCTAssertEqual(outgoing.providerSessionID, "uncertain-native")
                    retirements += 1
                }
                var saves = 0
                vm.test_setAgentSessionSaver { saved, _, _ in
                    saves += 1
                    XCTAssertNil(saved.providerSessionID)
                    XCTAssertNil(saved.codexConversationID)
                    XCTAssertNil(saved.codexRolloutPath)
                    XCTAssertEqual(saved.pendingHandoffProviderSwitchDelivery, saves == 1 ? .ready : .sending)
                    return fixture.rootURL.appendingPathComponent("fresh.json")
                }
                let applied = await vm.applyProviderSwitch(review.id)
                XCTAssertTrue(applied)
                XCTAssertEqual(retirements, 1)
                XCTAssertEqual(session.pendingHandoff.sourceItemID, uncertain.id)
                XCTAssertTrue(session.pendingHandoff.payload?.contains("<message role=\"user\">uncertain previous input</message>") == true)
                let next = try await switchPreparation(fixture)
                let payload = await vm.prepareProviderSwitchHandoverForSend(next, session: session, stopFence: .init(session: session))
                XCTAssertTrue(payload?.user.hasSuffix("\n\nordinary input") == true)
                XCTAssertFalse(payload?.user.hasSuffix("\n\nuncertain previous input") == true)
                XCTAssertNil(session.agentTask)
            }
        }

        func testSwitchApplyPreservesAllKindIdentityAndSavesCompleteTupleOnce() async throws {
            for kind in ["standalone", "overseer", "linked"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    if kind == "linked" { session.parentSessionID = UUID()
                        session.createdByOverseerSessionID = UUID()
                        session.isMCPOriginated = true
                    }
                    session.organizationalParentID = UUID()
                    session.delegationScopeID = UUID()
                    let parent = session.parentSessionID
                    let creator = session.createdByOverseerSessionID
                    let organization = session.organizationalParentID
                    let delegation = session.delegationScopeID
                    let endpoint = vm.agentSessionLinkObserverEndpoint(tabID: session.tabID)
                    let worktrees = session.worktreeBindings
                    let merges = session.worktreeMergeOperations
                    let usage = session.providerTokenUsageByTurn
                    let audit = session.automationTurnAudit
                    let binding = session.currentRestorationBindingToken
                    session.providerSessionID = "source-native"
                    session.codexConversationID = "old-codex"
                    session.codexRolloutPath = "/unchanged-on-disk/rollout"
                    session.codexModel = "old"
                    session.codexReasoningEffort = "high"
                    session.contextUsageSnapshot = .init(used: 123, window: 200_000, confidence: .exact, source: .claudeUsageEvent)
                    var saves = 0
                    vm.test_setAgentSessionSaver { saved, _, _ in
                        saves += 1
                        XCTAssertEqual(saved.pendingHandoffProviderSwitchDelivery, .ready)
                        XCTAssertNotNil(saved.pendingHandoffPayload)
                        XCTAssertNil(saved.providerSessionID)
                        XCTAssertNil(saved.codexConversationID)
                        return fixture.rootURL.appendingPathComponent("applied.json")
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let preview = try XCTUnwrap(vm.providerSwitchPreview)
                    let applied = await vm.applyProviderSwitch(preview.id)
                    XCTAssertTrue(applied)
                    XCTAssertEqual(saves, 1)
                    XCTAssertEqual(session.currentRestorationBindingToken, binding)
                    XCTAssertEqual(vm.agentSessionLinkObserverEndpoint(tabID: session.tabID), endpoint)
                    XCTAssertEqual(session.parentSessionID, parent)
                    XCTAssertEqual(session.createdByOverseerSessionID, creator)
                    XCTAssertEqual(session.organizationalParentID, organization)
                    XCTAssertEqual(session.delegationScopeID, delegation)
                    XCTAssertEqual(session.worktreeBindings, worktrees)
                    XCTAssertEqual(session.worktreeMergeOperations, merges)
                    XCTAssertEqual(session.providerTokenUsageByTurn, usage)
                    XCTAssertEqual(session.automationTurnAudit, audit)
                    XCTAssertNil(session.contextUsageSnapshot)
                    XCTAssertNil(session.vouchedContextCount)
                    XCTAssertNil(session.codexRolloutPath)
                    XCTAssertNil(session.codexModel)
                    XCTAssertNil(session.codexReasoningEffort)
                    let notices = session.items.filter { $0.recoveryDiagnostic?.reason == "providerSwitch" }
                    XCTAssertEqual(notices.count, 1)
                    XCTAssertEqual(notices[0].text, try "Provider changed from \(XCTUnwrap(preview.source).provider) / \(XCTUnwrap(preview.source).model) to OpenCode / unknown-window; handover: Full history.")
                    XCTAssertNil(session.agentTask)
                }
            }
        }

        func testSwitchRollbackRequiresPrewriteEvidenceAndRetirementCannotSaveEmptyContext() async throws {
            enum Fault: Error { case possibleWrite }
            for fault in ["prewrite", "possibleWrite"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.providerSessionID = "restore-source"
                    session.codexConversationID = "restore-codex"
                    session.codexRolloutPath = "/restore/path"
                    session.codexModel = "restore-model"
                    session.codexReasoningEffort = "high"
                    session.contextUsageSnapshot = .init(used: 4321, window: 200_000, confidence: .exact, source: .claudeUsageEvent)
                    session.noteLiveContextUsageReport(contextUsedTokens: 4321, promptTokens: nil, modelContextWindow: 200_000)
                    let countVouch = session.vouchedContextCount
                    let windowVouch = session.vouchedContextWindow
                    let context = session.contextUsageSnapshot
                    let rows = session.items.map(\.id)
                    let workspaceID = try XCTUnwrap(fixture.window.workspaceManager.activeWorkspaceID)
                    var saves = 0
                    vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                        throw Fault.possibleWrite
                    }
                    vm.test_providerSwitchRetirement = { outgoing in
                        let result = await vm.flushSaveRequired(for: outgoing.tabID, workspaceID: workspaceID)
                        guard case .failure = result else { return XCTFail("Retirement must gate all incidental saves") }
                        XCTAssertEqual(outgoing.providerSessionID, "restore-source")
                        XCTAssertEqual(saves, 0)
                    }
                    vm.test_providerSwitchBeforeSave = { outgoing in
                        if fault == "prewrite" { outgoing.isInstallingHandoffWorktreeBindings = true }
                    }
                    defer { session.isInstallingHandoffWorktreeBindings = false }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    let applied = await vm.applyProviderSwitch(id)
                    XCTAssertFalse(applied)
                    if fault == "prewrite" {
                        XCTAssertEqual(saves, 0)
                        XCTAssertEqual(session.providerSessionID, "restore-source")
                        XCTAssertEqual(session.codexConversationID, "restore-codex")
                        XCTAssertEqual(session.codexRolloutPath, "/restore/path")
                        XCTAssertEqual(session.codexModel, "restore-model")
                        XCTAssertEqual(session.codexReasoningEffort, "high")
                        XCTAssertEqual(session.contextUsageSnapshot, context)
                        XCTAssertEqual(session.vouchedContextCount, countVouch)
                        XCTAssertEqual(session.vouchedContextWindow, windowVouch)
                        XCTAssertNil(session.pendingHandoff.payload)
                        XCTAssertEqual(session.items.map(\.id), rows)
                    } else {
                        XCTAssertEqual(saves, 1)
                        XCTAssertEqual(session.selectedAgent, .openCode)
                        XCTAssertNil(session.providerSessionID)
                        XCTAssertNotNil(session.pendingHandoff.payload)
                        XCTAssertEqual(session.items.count(where: { $0.recoveryDiagnostic?.reason == "providerSwitch" }), 1)
                    }
                }
            }
        }

        func testSwitchBusyPreviewPendingPickerAndDiscardAreExplicitOnly() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let agent = session.selectedAgent
                session.mcpFollowUpRunPending = true
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let busy = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertNotNil(vm.providerSwitchPreviewBlocker(busy))
                let applied = await vm.applyProviderSwitch(busy.id)
                XCTAssertFalse(applied)
                XCTAssertEqual(session.selectedAgent, agent)
                vm.cancelProviderSwitchPreview()
                session.mcpFollowUpRunPending = false
                XCTAssertTrue(vm.canSelectAgentInCurrentChat(.claudeCodeGLM), "Existing Claude-family continuity remains allowed")
                try installSwitch(fixture)
                XCTAssertTrue(vm.providerSwitchPickerRequiresPreview(agent, session: session))
                XCTAssertTrue(vm.providerSwitchPickerRequiresPreview(.claudeCodeGLM, session: session))
                let slot = session.pendingHandoff
                await vm.openProviderSwitchPreview(agent: agent, model: session.selectedModelRaw, tabID: session.tabID)
                XCTAssertNil(vm.providerSwitchPreview?.wordLimit)
                let oldID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                await vm.generateProviderSwitchHandover(oldID)
                XCTAssertEqual(session.pendingHandoff, slot)
                vm.cancelProviderSwitchPreview()
                XCTAssertEqual(session.pendingHandoff, slot)
                let firstOpen = await vm.openProviderSwitchPreview(agent: agent, model: session.selectedModelRaw, tabID: session.tabID)
                let replacementOpen = await vm.openProviderSwitchPreview(agent: agent, model: session.selectedModelRaw, tabID: session.tabID)
                let staleDiscard = try await vm.applyProviderSwitch(XCTUnwrap(firstOpen), discard: true)
                XCTAssertFalse(staleDiscard, "A banner click's captured ID cannot discard a newer preview")
                XCTAssertEqual(session.pendingHandoff, slot)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("discard.json") }
                let discarded = try await vm.applyProviderSwitch(XCTUnwrap(replacementOpen), discard: true)
                XCTAssertTrue(discarded)
                XCTAssertNil(session.pendingHandoff.payload)
                XCTAssertEqual(session.items.last?.text, "Pending handover discarded; chat history unchanged.")
                XCTAssertEqual(session.selectedAgent, agent)
            }
        }

        func testCursorModelMenuVariantsStayTransientUntilSwitchAndRollbackWithTuple() async throws {
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
            defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
            let model = "grok-4.6"
            let definition = ACPModelParameterDefinition(
                kind: .thinking, configID: "effort", displayName: "Effort",
                choices: [.init(rawValue: "low", displayName: "Low"), .init(rawValue: "high", displayName: "High")],
                currentValueRaw: "low"
            )
            _ = AgentACPModelRegistry.shared.updateDiscoveredModels(.init(
                options: [.init(rawValue: model, displayName: "Grok 4.6", description: nil, isDefault: false)],
                currentModelRaw: model, modelParameterSets: [.init(baseModelRaw: model, parameters: [definition])]
            ), for: .cursor)
            let low = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: "low")
            let high = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: "high")
            for clear in [false, true] {
                for prewrite in [false, true] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        try installSwitch(fixture)
                        session.acpModelParameterSelections = [low]
                        let sourceAgent = session.selectedAgent
                        let sourceModel = session.selectedModelRaw
                        let slot = session.pendingHandoff
                        let intent: AgentModeViewModel.ProviderSwitchCursorParameterIntent = clear ? .clear(low.identity) : .select(high)
                        XCTAssertTrue(vm.requestProviderSwitchSelection(agent: .cursor, model: model, tabID: session.tabID, cursorParameterIntent: intent))
                        try await AsyncTestWait.waitUntil("Cursor variant Review prepared") { vm.providerSwitchPreview?.building == false }
                        XCTAssertEqual(session.acpModelParameterSelections, [low])
                        XCTAssertEqual(session.selectedAgent, sourceAgent)
                        XCTAssertEqual(vm.providerSwitchPreview?.model, model)
                        vm.cancelProviderSwitchPreview()
                        XCTAssertEqual(session.pendingHandoff, slot)
                        XCTAssertEqual(session.acpModelParameterSelections, [low], "Cancel never writes variant intent")
                        await vm.openProviderSwitchPreview(agent: .cursor, model: model, tabID: session.tabID, cursorParameterIntent: intent)
                        vm.providerSwitchPreview?.selected = .history
                        let expected = clear ? [] : [high]
                        var savedTuples: [AgentSession] = []
                        let saveURL = fixture.rootURL.appendingPathComponent("cursor-variant.json")
                        vm.test_setAgentSessionSaver { saved, _, _ in
                            savedTuples.append(saved)
                            return saveURL
                        }
                        // Teardown may save the restored source after a prewrite refusal. Retire
                        // this assertion/capture boundary before fixture teardown can suspend.
                        defer { vm.test_setAgentSessionSaver { _, _, _ in saveURL } }
                        vm.test_providerSwitchBeforeSave = { if prewrite { $0.isInstallingHandoffWorktreeBindings = true } }
                        defer { session.isInstallingHandoffWorktreeBindings = false }
                        let applied = try await vm.applyProviderSwitch(XCTUnwrap(vm.providerSwitchPreview?.id))
                        XCTAssertEqual(applied, !prewrite)
                        XCTAssertEqual(savedTuples.count, prewrite ? 0 : 1)
                        if !prewrite {
                            let saved = try XCTUnwrap(savedTuples.first)
                            XCTAssertEqual(saved.agentKind, AgentProviderKind.cursor.rawValue)
                            XCTAssertEqual(saved.agentModel, model)
                            XCTAssertEqual(saved.acpModelParameterSelections, expected)
                        }
                        XCTAssertEqual(session.acpModelParameterSelections, prewrite ? [low] : expected)
                        if prewrite {
                            XCTAssertEqual(session.selectedAgent, sourceAgent)
                            XCTAssertEqual(session.selectedModelRaw, sourceModel)
                            XCTAssertEqual(session.pendingHandoff, slot)
                        } else {
                            let ready = session.pendingHandoff
                            vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("separate-parameter.json") }
                            vm.selectACPModelParameter(low)
                            XCTAssertEqual(session.acpModelParameterSelections, [low], "Separate ACP control keeps its existing immediate behavior")
                            XCTAssertNil(vm.providerSwitchPreview)
                            XCTAssertEqual(session.pendingHandoff, ready)
                        }
                    }
                }
            }
        }

        func testSourceGenerationCompletionNeverRetargetsReboundSession() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation-drift.json") }
                vm.test_providerSwitchGeneration = { outgoing, _, _ in
                    outgoing.appendItem(.assistant("late source result", sequenceIndex: outgoing.nextSequenceIndex))
                    outgoing.runState = .completed
                    outgoing.testInstallPersistentSessionBinding(sessionID: UUID())
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                await vm.generateProviderSwitchHandover(preview.id)
                // The synchronous terminal guard must refuse before scheduling a rebuild.
                XCTAssertFalse(vm.providerSwitchPreview?.generationFinished ?? true)
                XCTAssertEqual(vm.providerSwitchPreview?.id, preview.id)
                XCTAssertEqual(vm.providerSwitchPreview?.binding, preview.binding)
                XCTAssertNil(vm.providerSwitchPreview?.choices.first { $0.mode == .summary }?.carrier)
                XCTAssertNotNil(vm.providerSwitchPreviewBlocker(preview))
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testSwitchSourceGenerationUsesOrdinaryUnauthoredTurnWithoutConsumingComposer() async throws {
            for tools in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.draftText = "keep composer"
                    session.selectedWorkflow = .init(customID: UUID(), displayName: "Keep workflow")
                    let workflow = session.selectedWorkflow
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation.json") }
                    vm.test_providerSwitchGeneration = { outgoing, rowID, request in
                        guard let row = outgoing.items.first(where: { $0.id == rowID }) else { return XCTFail("Generation row missing") }
                        XCTAssertEqual(row.text, request)
                        XCTAssertNil(row.userInputOrigin)
                        XCTAssertNil(row.crossSessionAttribution)
                        if tools { outgoing.appendItem(.init(kind: .toolCall, text: "effect", toolName: "read_file", sequenceIndex: outgoing.nextSequenceIndex)) }
                        outgoing.appendItem(.assistant("source-written summary", sequenceIndex: outgoing.nextSequenceIndex))
                        outgoing.runState = .completed
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    await vm.generateProviderSwitchHandover(id)
                    try await AsyncTestWait.waitUntil("source generation has a measured preview") {
                        vm.providerSwitchPreview?.id != id && vm.providerSwitchPreview?.building == false
                    }
                    let summary = try XCTUnwrap(vm.providerSwitchPreview?.choices.first { $0.mode == .summary })
                    if tools { XCTAssertEqual(summary.unavailable, "the model used tools")
                        XCTAssertNil(summary.carrier)
                    } else { XCTAssertNil(summary.unavailable)
                        XCTAssertNotNil(summary.carrier)
                    }
                    XCTAssertEqual(session.draftText, "keep composer")
                    XCTAssertEqual(session.selectedWorkflow, workflow)
                    XCTAssertNil(session.pendingHandoff.payload, "Generate must never auto-apply")
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                }
            }
        }

        func testSwitchCutoffUsesCanonicalTailAndSurvivesActualSaveRestore() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let durableTail = try XCTUnwrap(session.items.last?.id)
                let meta = AgentChatItem(kind: .toolCall, text: "filtered harness status", toolName: "set_status", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(meta)
                vm.test_setAgentSessionSaver { saved, workspace, _ in
                    try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                try await AsyncTestWait.waitUntil("canonical cutoff preview settled") { vm.providerSwitchPreview?.building == false }
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(preview.cutoff, durableTail)
                XCTAssertNotEqual(preview.cutoff, meta.id)
                let applied = await vm.applyProviderSwitch(preview.id)
                XCTAssertTrue(applied)
                session.hasLoadedPersistedState = false
                let restored = await vm.ensureSessionReady(tabID: session.tabID, reconnectActiveProviders: false)
                XCTAssertTrue(restored === session)
                XCTAssertFalse(restored.items.contains { $0.id == meta.id })
                XCTAssertEqual(restored.pendingHandoff.sourceItemID, durableTail)
                XCTAssertFalse(AgentModeViewModel.providerSwitchNeedsReview(restored))
                guard case .success(.some) = await vm.providerSwitchSendAdmission(session: restored, input: "new ordinary input") else {
                    return XCTFail("A canonical tail must not become stale after normalization and restore")
                }
            }
        }

        func testReviewNoticeFilteringKeepsEarlierCompactedEventsAndExcludesOwnEmptyHistoryNotice() async throws {
            for empty in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.setItemsSilently([], reason: .testOverride)
                    session.transcript = .empty
                    session.nextSequenceIndex = 0
                    var cutoff: UUID?
                    if !empty {
                        let olderApplied = AgentTranscriptRecoveryDiagnostic(sequenceIndex: 2, reason: "providerSwitch", outcome: "applied", text: "older completed switch applied")
                        let olderSent = AgentTranscriptRecoveryDiagnostic(sequenceIndex: 3, reason: "providerSwitch", outcome: "sent", text: "older completed switch sent")
                        let anchor = AgentTranscriptRecoveryDiagnostic(sequenceIndex: 10, reason: "resume", outcome: "freshThreadStarted", text: "retained cutoff event")
                        cutoff = anchor.id
                        let request = AgentChatItem.user("compacted original task", sequenceIndex: 0)
                        var turn = AgentTranscriptTurn(request: .init(from: request), responseSpans: [], conclusionActivityID: nil, terminalState: .completed, startedAt: request.timestamp, completedAt: request.timestamp)
                        turn.retentionTier = .condensed
                        turn.summary = .init(requestText: nil, conclusionText: "retained conclusion", compactConclusionText: nil, middleSummaryText: "retained middle", toolCount: 0, notableToolNames: [], keyPaths: [], compactedActivityCount: 0, hadWarning: false, hadError: false, recoveryDiagnostics: [olderApplied, olderSent, anchor])
                        session.transcript = AgentTranscript(turns: [turn])
                    }
                    session.pendingHandoff = try .init(payload: switchCarrier(), createdAt: Date(), sourceItemID: cutoff, providerSwitchDelivery: .ready)
                    session.nextSequenceIndex = empty ? 0 : 11
                    session.appendItem(.system("own pending switch notice", sequenceIndex: empty ? 0 : 11, recoveryDiagnostic: .init(reason: "providerSwitch", outcome: "applied", text: "own pending switch notice")))
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    try await AsyncTestWait.waitUntil("pending notice review settled") { vm.providerSwitchPreview?.building == false }
                    let preview = try XCTUnwrap(vm.providerSwitchPreview)
                    let payload = await vm.providerSwitchPayload(preview.id, mode: .newestTurns)
                    let recent = try XCTUnwrap(payload)
                    XCTAssertFalse(recent.contains("own pending switch notice"))
                    if !empty {
                        XCTAssertTrue(recent.contains("older completed switch applied"))
                        XCTAssertTrue(recent.contains("older completed switch sent"))
                        XCTAssertTrue(recent.contains("retained cutoff event"))
                    }
                    XCTAssertEqual(session.pendingHandoff.sourceItemID, cutoff)
                }
            }
        }

        func testGeneratedSummaryKeepsReadableHistoryAndRefitsOnlyDraftOrWorkflowChanges() async throws {
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
            for drift in ["input", "reasoning", "claude", "parameters"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    if drift == "reasoning" { session.selectedAgent = .codexExec }
                    if drift == "claude" { session.selectedAgent = .claudeCode }
                    if drift == "parameters" { session.selectedAgent = .cursor }
                    session.selectedModelRaw = vm.defaultModelRaw(for: session.selectedAgent)
                    vm.updateBindingsFromSession(session)
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("readable-summary.json") }
                    var generations = 0
                    vm.test_providerSwitchGeneration = { outgoing, _, _ in
                        generations += 1
                        outgoing.appendItem(.assistant("validated source summary", sequenceIndex: outgoing.nextSequenceIndex))
                        outgoing.runState = .completed
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let originalID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    await vm.generateProviderSwitchHandover(originalID)
                    try await AsyncTestWait.waitUntil("generated readable summary") { vm.providerSwitchPreview?.generatedSummary != nil && vm.providerSwitchPreview?.building == false }
                    var preview = try XCTUnwrap(vm.providerSwitchPreview)
                    let sourceRevision = preview.sourceRevision
                    let cutoff = preview.cutoff
                    let summary = try XCTUnwrap(preview.choices.first(where: { $0.mode == .summary })?.carrier)
                    XCTAssertEqual(summary.historyReference?.sessionID, session.activeAgentSessionID)
                    let rendered = AgentProviderHandover.render(summary)
                    XCTAssertTrue(rendered.contains("availability=\"readable\""))
                    XCTAssertTrue(rendered.contains("validated source summary"))
                    for workflowChange in [false, true] {
                        let oldID = preview.id
                        if workflowChange {
                            vm.selectWorkflow(.init(customID: UUID(), displayName: "New workflow", template: String(repeating: "wrapper ", count: 2000) + "$ARGUMENTS"))
                        } else {
                            vm.storeDraftText(for: session.tabID, String(repeating: "draft ", count: 2000))
                            vm.updateBindingsFromSession(session)
                        }
                        try await AsyncTestWait.waitUntil("composition-only summary refit") { vm.providerSwitchPreview?.id != oldID && vm.providerSwitchPreview?.building == false }
                        let current = try XCTUnwrap(vm.providerSwitchPreview)
                        XCTAssertEqual(current.sourceRevision, sourceRevision)
                        XCTAssertEqual(current.cutoff, cutoff)
                        XCTAssertEqual(current.generatedSummary?.text, "validated source summary")
                        XCTAssertEqual(current.choices.first(where: { $0.mode == .summary })?.carrier?.historyReference?.sessionID, session.activeAgentSessionID)
                        XCTAssertNotNil(current.choices.first(where: { $0.mode == .summary })?.carrier)
                        XCTAssertGreaterThan(try XCTUnwrap(current.budget).inputTokens, 2048)
                        XCTAssertEqual(generations, 1, "Refitting must never rerun Generate")
                        preview = current
                    }
                    switch drift {
                    case "reasoning":
                        session.selectedReasoningEffortRaw = session.selectedReasoningEffortRaw == "high" ? "low" : "high"
                    case "claude":
                        session.selectedClaudeEffortRaw = session.selectedClaudeEffortRaw == "high" ? "low" : "high"
                    case "parameters":
                        let selection = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: session.selectedModelRaw, kind: .thinking, configID: "effort", valueRaw: "high")
                        session.recordAcceptedACPModelParameterWrite([selection])
                        session.acpModelParameterSelections = [selection]
                    default:
                        session.appendItem(.user("later accepted source input", sequenceIndex: session.nextSequenceIndex))
                    }
                    // Exercise the held source configuration written by the existing effort/ACP owners,
                    // not global preference writes or another hand-built expected summary predicate.
                    vm.updateBindingsFromSession(session)
                    try await AsyncTestWait.waitUntil("source \(drift) change invalidates summary") { vm.providerSwitchPreview?.id != preview.id && vm.providerSwitchPreview?.building == false }
                    let invalidated = try XCTUnwrap(vm.providerSwitchPreview)
                    if drift != "input" {
                        XCTAssertEqual(invalidated.sourceRevision, sourceRevision)
                        XCTAssertEqual(invalidated.cutoff, cutoff)
                        XCTAssertEqual(invalidated.sourceAgent, preview.sourceAgent)
                        XCTAssertEqual(invalidated.sourceModel, preview.sourceModel)
                    }
                    XCTAssertNil(invalidated.generatedSummary)
                    XCTAssertNil(invalidated.choices.first(where: { $0.mode == .summary })?.carrier)
                    XCTAssertEqual(generations, 1, "Source configuration drift must not automatically Generate")
                    XCTAssertNil(session.pendingHandoff.payload)
                }
            }
        }

        func testGeneratedSummarySurvivesOwedNoticeReceiptAndLaterNoticeRefit() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let (endpoint, lane) = try summaryMonitorContext(fixture)
                var notices = AgentSessionLinkPassiveStatusNotices(observerEndpoint: endpoint)
                notices.enable(samples: [lane], linkSetRevision: 1)
                let finished = AgentSessionLinkPassiveStatusNotices.Sample(reference: lane.reference, targetEndpoint: lane.targetEndpoint, targetSessionID: lane.targetSessionID, displayName: lane.displayName, status: .idle, idleForSend: true, latestVisibleAssistantPreview: "First lane result")
                notices.reconcile(samples: [finished], linkSetRevision: 1, deliverable: true)
                XCTAssertEqual(notices.snapshot.entries.count, 1)
                vm.agentSessionLinkPublishPassiveStatusNotices(notices.snapshot, to: endpoint)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("owed-summary.json") }
                var generations = 0
                vm.test_providerSwitchGeneration = { [unowned vm] outgoing, _, request in
                    generations += 1
                    let decorated = vm.agentSessionLinkDecoratedProviderText(request, session: outgoing, dispatchID: .claudeNativeSend(UUID()))
                    do {
                        let receipt = try XCTUnwrap(decorated.claim?.passive?.receipt)
                        XCTAssertTrue(decorated.text.contains("First lane result"))
                        vm.acceptAgentSessionLinkPromptClaim(decorated.claim)
                        notices.apply(receipt)
                        XCTAssertTrue(notices.snapshot.entries.isEmpty, "Apply the actually rendered receipt through the existing reducer")
                        vm.agentSessionLinkPublishPassiveStatusNotices(notices.snapshot, to: endpoint)
                    } catch { XCTFail("Missing ordinary notice claim: \(error)") }
                    outgoing.appendItem(.assistant("summary remains valid after normal notice delivery", sequenceIndex: outgoing.nextSequenceIndex))
                    outgoing.runState = .completed
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let original = try XCTUnwrap(vm.providerSwitchPreview)
                await vm.generateProviderSwitchHandover(original.id)
                try await AsyncTestWait.waitUntil("summary rebuild after receipt") { vm.providerSwitchPreview?.id != original.id && vm.providerSwitchPreview?.building == false }
                let settled = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(settled.generatedSummary?.text, "summary remains valid after normal notice delivery")
                XCTAssertNotNil(settled.choices.first { $0.mode == .summary }?.carrier)
                XCTAssertLessThan(try XCTUnwrap(settled.budget).instructionTokens, try XCTUnwrap(original.budget).instructionTokens)
                notices.reconcile(samples: [lane], linkSetRevision: 1, deliverable: true)
                notices.reconcile(samples: [finished], linkSetRevision: 1, deliverable: true)
                XCTAssertEqual(notices.snapshot.entries.count, 1)
                vm.agentSessionLinkPublishPassiveStatusNotices(notices.snapshot, to: endpoint)
                vm.updateBindingsFromSession(session)
                try await AsyncTestWait.waitUntil("summary refit for newly owed notice") { vm.providerSwitchPreview?.id != settled.id && vm.providerSwitchPreview?.building == false }
                let current = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(current.generatedSummary?.text, settled.generatedSummary?.text)
                XCTAssertEqual(current.cutoff, settled.cutoff)
                XCTAssertEqual(current.sourceRevision, settled.sourceRevision)
                XCTAssertNotNil(current.choices.first { $0.mode == .summary }?.carrier)
                XCTAssertGreaterThan(try XCTUnwrap(current.budget).instructionTokens, try XCTUnwrap(settled.budget).instructionTokens)
                XCTAssertEqual(notices.snapshot.entries.count, 1, "Refitting must not acknowledge newly owed content")
                XCTAssertEqual(generations, 1)
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testParkedFrameRemainsInFullPreviewInstructionsButNotSummaryProvenance() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let baseline = try XCTUnwrap(vm.providerSwitchPreview)
                var state = AgentSelfCompactState()
                _ = state.reserve(note: "parked continuation evidence", idempotencyKey: "preview-frame", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes)
                state.active?.phase = .parked
                session.selfCompactState = state
                let frame = try XCTUnwrap(session.selfCompactState.parkedNote?.frame)
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let parked = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertTrue(parked.instructions.contains(frame))
                XCTAssertEqual(parked.instructions.filter { $0 != frame }, baseline.instructions)
                XCTAssertEqual(parked.instructionProvenance, baseline.instructionProvenance)
                XCTAssertFalse(parked.instructionProvenance.contains(frame))
                XCTAssertNotNil(vm.providerSwitchPreviewBlocker(parked), "A parked note still blocks Generate")
            }
        }

        func testGeneratedSummaryDropsOnStableMonitorInstructionChanges() async throws {
            for drift in ["membership", "grant", "reference"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    let (endpoint, lane) = try summaryMonitorContext(fixture)
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("stable-instructions.json") }
                    var generations = 0
                    vm.test_providerSwitchGeneration = { outgoing, _, _ in
                        generations += 1
                        outgoing.appendItem(.assistant("summary for original monitor authority", sequenceIndex: outgoing.nextSequenceIndex))
                        outgoing.runState = .completed
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let originalID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    await vm.generateProviderSwitchHandover(originalID)
                    try await AsyncTestWait.waitUntil("summary before stable instruction change") { vm.providerSwitchPreview?.id != originalID && vm.providerSwitchPreview?.building == false }
                    let settled = try XCTUnwrap(vm.providerSwitchPreview)
                    XCTAssertNotNil(settled.generatedSummary)
                    vm.agentSessionLinkPublishPromptInventory(.init(
                        observerSessionID: endpoint.sessionID, linkSetRevision: 2,
                        items: drift == "membership" ? [] : [.init(targetSessionID: lane.targetSessionID, displayName: lane.displayName, capabilityNames: drift == "grant" ? ["poll"] : ["poll", "read"], reference: drift == "reference" ? .init(linkID: lane.reference.linkID, generation: lane.reference.generation + 1) : lane.reference)]
                    ), to: endpoint)
                    vm.updateBindingsFromSession(session)
                    try await AsyncTestWait.waitUntil("summary invalidated by stable \(drift)") { vm.providerSwitchPreview?.id != settled.id && vm.providerSwitchPreview?.building == false }
                    let current = try XCTUnwrap(vm.providerSwitchPreview)
                    XCTAssertNotEqual(current.instructions, settled.instructions)
                    XCTAssertEqual(current.sourceRevision, settled.sourceRevision)
                    XCTAssertEqual(current.cutoff, settled.cutoff)
                    XCTAssertNil(current.generatedSummary, drift)
                    XCTAssertNil(current.choices.first { $0.mode == .summary }?.carrier, drift)
                    XCTAssertEqual(generations, 1)
                    XCTAssertTrue(session.items.contains { $0.kind == .assistant && $0.text == "summary for original monitor authority" })
                }
            }
        }

        func testGeneratedSummaryRefitBudgetsFullOwedInstructionsAndWithholdsOversizedCarrier() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let (endpoint, lane) = try summaryMonitorContext(fixture)
                var notices = AgentSessionLinkPassiveStatusNotices(observerEndpoint: endpoint)
                notices.enable(samples: [lane], linkSetRevision: 1)
                vm.agentSessionLinkPublishPassiveStatusNotices(notices.snapshot, to: endpoint)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("summary-full-budget.json") }
                var generations = 0
                vm.test_providerSwitchGeneration = { outgoing, _, _ in
                    generations += 1
                    outgoing.appendItem(.assistant("bounded summary", sequenceIndex: outgoing.nextSequenceIndex))
                    outgoing.runState = .completed
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let originalID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                await vm.generateProviderSwitchHandover(originalID)
                try await AsyncTestWait.waitUntil("summary before full instruction boundary") { vm.providerSwitchPreview?.id != originalID && vm.providerSwitchPreview?.building == false }
                let settled = try XCTUnwrap(vm.providerSwitchPreview)
                let carrier = try XCTUnwrap(settled.choices.first { $0.mode == .summary }?.carrier)
                let budget = try XCTUnwrap(settled.budget)
                let inputAllowance = budget.inputTokens + budget.remainingCarrierTokens - AgentProviderHandover.estimate(AgentProviderHandover.render(carrier)) - 32
                vm.storeDraftText(for: session.tabID, String(repeating: "d", count: Int(inputAllowance / AgentProviderHandover.estimate("d"))))
                vm.updateBindingsFromSession(session)
                try await AsyncTestWait.waitUntil("summary near capacity without notice") { vm.providerSwitchPreview?.id != settled.id && vm.providerSwitchPreview?.building == false }
                let fitting = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertNotNil(fitting.choices.first { $0.mode == .summary }?.carrier)
                XCTAssertTrue(try XCTUnwrap(fitting.budget).fits(carrier))
                let finished = AgentSessionLinkPassiveStatusNotices.Sample(reference: lane.reference, targetEndpoint: lane.targetEndpoint, targetSessionID: lane.targetSessionID, displayName: lane.displayName, status: .idle, idleForSend: true, latestVisibleAssistantPreview: String(repeating: "N", count: 280))
                notices.reconcile(samples: [finished], linkSetRevision: 1, deliverable: true)
                XCTAssertEqual(notices.snapshot.entries.count, 1)
                vm.agentSessionLinkPublishPassiveStatusNotices(notices.snapshot, to: endpoint)
                vm.updateBindingsFromSession(session)
                try await AsyncTestWait.waitUntil("summary exceeds full current instruction budget") { vm.providerSwitchPreview?.id != fitting.id && vm.providerSwitchPreview?.building == false }
                let current = try XCTUnwrap(vm.providerSwitchPreview)
                let currentBudget = try XCTUnwrap(current.budget)
                XCTAssertGreaterThan(currentBudget.instructionTokens, try XCTUnwrap(fitting.budget).instructionTokens)
                XCTAssertFalse(currentBudget.fits(carrier))
                XCTAssertEqual(current.generatedSummary?.text, "bounded summary", "Keep existing internal retention semantics")
                XCTAssertNil(current.choices.first { $0.mode == .summary }?.carrier)
                XCTAssertEqual(current.choices.first { $0.mode == .summary }?.unavailable, "the summary is too large")
                vm.providerSwitchPreview?.selected = .summary
                let applied = await vm.applyProviderSwitch(current.id)
                XCTAssertFalse(applied)
                XCTAssertNil(session.pendingHandoff.payload, "No overbudget carrier may become sendable")
                XCTAssertTrue(session.items.contains { $0.kind == .assistant && $0.text == "bounded summary" })
                XCTAssertEqual(generations, 1)
            }
        }

        func testGenerationSettlementInvalidatesSourceConfigurationDriftWithoutAutomaticRetry() async throws {
            GlobalSettingsStore.installApplicationModelIdentityPolicy()
            for timing in ["during", "queued"] {
                for drift in ["none", "reasoning", "claude", "parameters"] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        if drift == "reasoning" { session.selectedAgent = .codexExec }
                        if drift == "claude" { session.selectedAgent = .claudeCode }
                        if drift == "parameters" { session.selectedAgent = .cursor }
                        session.selectedModelRaw = vm.defaultModelRaw(for: session.selectedAgent)
                        vm.updateBindingsFromSession(session)
                        vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("settlement-config.json") }
                        let binding = session.currentRestorationBindingToken
                        let agent = session.selectedAgent
                        let model = session.selectedModelRaw
                        var generations = 0
                        var conclusionID: UUID?
                        var settledRevision: Int?
                        vm.test_providerSwitchGeneration = { outgoing, _, _ in
                            generations += 1
                            let conclusion = AgentChatItem.assistant("result for the captured source configuration", sequenceIndex: outgoing.nextSequenceIndex)
                            outgoing.appendItem(conclusion)
                            conclusionID = conclusion.id
                            outgoing.runState = .completed
                            if timing == "queued" {
                                // Queue the real settlement task, then change only configuration in
                                // this uninterrupted actor turn, before its replacement preview opens.
                                vm.providerSwitchGenerationSettled(outgoing)
                            }
                            let revision = outgoing.sourceItemsRevision
                            switch drift {
                            case "reasoning":
                                outgoing.selectedReasoningEffortRaw = outgoing.selectedReasoningEffortRaw == "high" ? "low" : "high"
                            case "claude":
                                outgoing.selectedClaudeEffortRaw = outgoing.selectedClaudeEffortRaw == "high" ? "low" : "high"
                            case "parameters":
                                let selection = ACPModelParameterSelection(providerID: .cursor, baseModelRaw: outgoing.selectedModelRaw, kind: .thinking, configID: "effort", valueRaw: "high")
                                outgoing.recordAcceptedACPModelParameterWrite([selection])
                                outgoing.acpModelParameterSelections = [selection]
                            default: break
                            }
                            XCTAssertEqual(outgoing.sourceItemsRevision, revision, "Configuration drift must not be disguised as transcript drift")
                            settledRevision = revision
                            vm.updateBindingsFromSession(outgoing)
                        }
                        await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                        let originalID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                        await vm.generateProviderSwitchHandover(originalID)
                        try await AsyncTestWait.waitUntil("settlement rebuild after \(timing) \(drift) drift") {
                            vm.providerSwitchPreview?.id != originalID && vm.providerSwitchPreview?.building == false
                        }
                        let current = try XCTUnwrap(vm.providerSwitchPreview)
                        XCTAssertEqual(current.binding, binding)
                        XCTAssertEqual(current.sourceAgent, agent)
                        XCTAssertEqual(current.sourceModel, model)
                        XCTAssertEqual(current.sourceRevision, settledRevision)
                        XCTAssertEqual(current.cutoff, conclusionID)
                        XCTAssertNil(current.generationItemID, "Invalidation must not leave Generating stuck")
                        XCTAssertNotNil(current.wordLimit)
                        XCTAssertNil(vm.providerSwitchPreviewBlocker(current), "The next explicit Generate must remain available")
                        if drift == "none" {
                            XCTAssertEqual(current.generatedSummary?.text, "result for the captured source configuration")
                            XCTAssertNotNil(current.choices.first(where: { $0.mode == .summary })?.carrier)
                        } else {
                            XCTAssertNil(current.generatedSummary, "\(timing) \(drift)")
                            XCTAssertNil(current.choices.first(where: { $0.mode == .summary })?.carrier, "\(timing) \(drift)")
                        }
                        XCTAssertTrue(session.items.contains { $0.id == conclusionID }, "The invalidated result remains ordinary retained history")
                        XCTAssertEqual(generations, 1, "Invalidation never automatically Generates")
                        XCTAssertNil(session.pendingHandoff.payload)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testGenerationSettlementRefitsOnlyDraftWorkflowAndRejectsInstructionOrCompositionDrift() async throws {
            for timing in ["during", "queued"] {
                for drift in ["draft", "workflow", "interview", "instructions"] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        // Generate itself supplies this chat's first assistant. Its derived Interview
                        // eligibility changes normally; the independent preference must stay fenced.
                        session.setItemsSilently([.user("Source task", sequenceIndex: 0)], reason: .testOverride)
                        session.transcript = .empty
                        session.nextSequenceIndex = 1
                        vm.interviewFirst = true
                        vm.updateBindingsFromSession(session)
                        vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("settlement-composition.json") }
                        let instructionEndpoint = drift == "instructions" ? try summaryMonitorContext(fixture).0 : nil
                        var generations = 0
                        var conclusionID: UUID?
                        vm.test_providerSwitchGeneration = { [unowned vm] outgoing, _, _ in
                            generations += 1
                            let conclusion = AgentChatItem.assistant("summary under original instructions", sequenceIndex: outgoing.nextSequenceIndex)
                            outgoing.appendItem(conclusion)
                            conclusionID = conclusion.id
                            outgoing.runState = .completed
                            if timing == "queued" { vm.providerSwitchGenerationSettled(outgoing) }
                            let revision = outgoing.sourceItemsRevision
                            switch drift {
                            case "draft":
                                vm.storeDraftText(for: outgoing.tabID, String(repeating: "draft ", count: 2000))
                            case "workflow":
                                vm.selectWorkflow(.init(customID: UUID(), displayName: "New workflow", template: String(repeating: "wrapper ", count: 2000) + "$ARGUMENTS"))
                            case "interview":
                                vm.interviewFirst = false
                            case "instructions":
                                guard let instructionEndpoint else { return XCTFail("Missing stable membership endpoint") }
                                vm.agentSessionLinkPublishPromptInventory(.init(observerSessionID: instructionEndpoint.sessionID, linkSetRevision: 2, items: []), to: instructionEndpoint)
                            default:
                                XCTFail("Unexpected drift case: \(drift)")
                            }
                            XCTAssertEqual(outgoing.sourceItemsRevision, revision)
                            vm.updateBindingsFromSession(outgoing)
                        }
                        await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                        let original = try XCTUnwrap(vm.providerSwitchPreview)
                        XCTAssertTrue(original.composition.includesInterview)
                        await vm.generateProviderSwitchHandover(original.id)
                        try await AsyncTestWait.waitUntil("settlement after \(timing) \(drift)") {
                            vm.providerSwitchPreview?.id != original.id && vm.providerSwitchPreview?.building == false
                        }
                        let current = try XCTUnwrap(vm.providerSwitchPreview)
                        XCTAssertFalse(current.composition.includesInterview)
                        XCTAssertNil(current.generationItemID)
                        XCTAssertEqual(current.cutoff, conclusionID)
                        if drift == "draft" || drift == "workflow" {
                            XCTAssertEqual(current.generatedSummary?.text, "summary under original instructions", "\(timing) \(drift)")
                            let carrier = try XCTUnwrap(current.choices.first { $0.mode == .summary }?.carrier)
                            let budget = try XCTUnwrap(current.budget)
                            XCTAssertGreaterThan(budget.inputTokens, 2048)
                            XCTAssertTrue(budget.fits(carrier), "Allowed refits still measure the current composed input")
                        } else {
                            if drift == "instructions" { XCTAssertNotEqual(current.instructions, original.instructions) }
                            XCTAssertNil(current.generatedSummary, "\(timing) \(drift)")
                            XCTAssertNil(current.choices.first { $0.mode == .summary }?.carrier, "\(timing) \(drift)")
                        }
                        XCTAssertTrue(session.items.contains { $0.id == conclusionID })
                        XCTAssertEqual(generations, 1)
                        XCTAssertNil(session.pendingHandoff.payload)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testMalformedSwitchCarrierStillPermitsDirectClaimedDiscardWithoutSourceOrReset() async throws {
            for malformed in [
                "<repoprompt_provider_handover version=\"1\" mode=\"history\" source_provider=\" \" source_model=\"model\"></repoprompt_provider_handover>",
                "<repoprompt_provider_handover version=\"1\" mode=\"history\" source_provider=\"source\" source_model=\"model\"><omitted kind=\"older_turns\" first=\"0\" last=\"\(Int.max)\" /></repoprompt_provider_handover>"
            ] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.providerSessionID = "native-context-must-survive-discard"
                    session.pendingHandoff = .init(payload: malformed, createdAt: Date(), sourceItemID: session.items.last?.id, providerSwitchDelivery: .sending)
                    let rows = session.items.map(\.id)
                    var retirements = 0
                    var saves = 0
                    vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                    vm.test_setAgentSessionSaver { saved, _, _ in
                        XCTAssertNil(saved.pendingHandoffPayload)
                        XCTAssertNil(saved.pendingHandoffProviderSwitchDelivery)
                        saves += 1
                        return fixture.rootURL.appendingPathComponent("discard-corrupt.json")
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                    let review = try XCTUnwrap(vm.providerSwitchPreview)
                    XCTAssertNil(review.source, "Corrupt source XML must never acquire the selected provider as its author")
                    XCTAssertEqual(vm.providerSwitchPreviewBlocker(review), AgentSessionLinkSendFailure.providerHandoverNeedsReview.message)
                    let switched = await vm.applyProviderSwitch(review.id)
                    XCTAssertFalse(switched)
                    vm.cancelProviderSwitchPreview()
                    let discarded = await vm.discardProviderSwitchHandover(tabID: session.tabID)
                    XCTAssertTrue(discarded)
                    XCTAssertNil(vm.providerSwitchPreview, "Banner Discard must not publish or render a Review")
                    XCTAssertEqual(session.pendingHandoff, .init())
                    XCTAssertEqual(session.providerSessionID, "native-context-must-survive-discard")
                    XCTAssertEqual(retirements, 0)
                    XCTAssertEqual(saves, 1)
                    XCTAssertEqual(Array(session.items.dropLast()).map(\.id), rows)
                    XCTAssertEqual(session.items.last?.text, "Pending handover discarded; chat history unchanged.")
                    XCTAssertEqual(session.items.last?.recoveryDiagnostic?.outcome, "discarded")
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testDirectBannerDiscardPresentsOwnedSaveFailuresWithoutChangingRecoveryPolicy() async throws {
            enum Fault: Error { case write }
            for phase in ["prewrite", "indeterminate"] {
                for drift in ["none", "binding", "slot"] where phase == "indeterminate" || drift == "none" {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        try installSwitch(fixture)
                        let originalHandoff = session.pendingHandoff
                        let originalRows = session.items.map(\.id)
                        let sessionID = session.activeAgentSessionID
                        session.providerSessionID = "discard-must-not-retire-native-context"
                        var isDiscardAttemptUnderTest = true
                        var writes = 0
                        var retirements = 0
                        var successorSlot: AgentModeViewModel.PendingHandoffState?
                        vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                        vm.test_providerSwitchBeforeSave = { outgoing in
                            if phase == "prewrite" { outgoing.isInstallingHandoffWorktreeBindings = true }
                        }
                        defer {
                            isDiscardAttemptUnderTest = false
                            session.isInstallingHandoffWorktreeBindings = false
                            vm.test_providerSwitchBeforeSave = nil
                        }
                        vm.test_setAgentSessionSaver { saved, _, _ in
                            // Window teardown may save again after this operation has settled.
                            // Only the exact Discard under test owns this fault injection.
                            guard isDiscardAttemptUnderTest, saved.id == sessionID else {
                                return fixture.rootURL.appendingPathComponent("outside-discard-attempt.json")
                            }
                            writes += 1
                            XCTAssertNil(saved.pendingHandoffPayload)
                            XCTAssertNil(saved.pendingHandoffProviderSwitchDelivery)
                            try JSONEncoder().encode(saved).write(to: fixture.rootURL.appendingPathComponent("discard-may-have-written.json"), options: .atomic)
                            if drift == "binding" { session.testInstallPersistentSessionBinding(sessionID: UUID()) }
                            if drift == "slot" {
                                let replacement = try AgentModeViewModel.PendingHandoffState(payload: self.switchCarrier(padding: 1), createdAt: Date(), sourceItemID: session.items.last?.id, providerSwitchDelivery: .sending)
                                session.pendingHandoff = replacement
                                successorSlot = replacement
                            }
                            throw Fault.write
                        }
                        let action = try XCTUnwrap(vm.requestProviderSwitchBannerAction(for: session, discard: true))
                        let discarded = await action.value
                        isDiscardAttemptUnderTest = false
                        XCTAssertFalse(discarded)
                        XCTAssertNil(vm.providerSwitchPreview, "Failure reporting cannot open Review")
                        XCTAssertNil(vm.providerSwitchMutation)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                        XCTAssertEqual(retirements, 0)
                        XCTAssertEqual(session.providerSessionID, "discard-must-not-retire-native-context")
                        XCTAssertEqual(writes, phase == "prewrite" ? 0 : 1)
                        XCTAssertEqual(Array(session.items.prefix(originalRows.count)).map(\.id), originalRows)
                        if phase == "prewrite" {
                            XCTAssertEqual(session.pendingHandoff, originalHandoff)
                            XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "discarded" })
                        } else if let successorSlot {
                            XCTAssertEqual(session.pendingHandoff, successorSlot, "A failed older Discard cannot mutate the replacement slot")
                        } else {
                            XCTAssertEqual(session.pendingHandoff, .init(), "Possible-write failure must not roll the discard back")
                            XCTAssertEqual(session.items.count(where: { $0.recoveryDiagnostic?.outcome == "discarded" }), 1)
                        }
                        if drift == "none" {
                            let errors = session.items.filter { $0.kind == .error }
                            XCTAssertEqual(errors.count, 1, "The real banner entry must not silently drop the existing save failure")
                            if let error = errors.last {
                                XCTAssertEqual(error.text, phase == "prewrite" ? "Handoff is still preparing this chat's worktree execution location." : String(describing: Fault.write))
                                XCTAssertTrue(vm.transcriptItems.contains { $0.id == error.id }, "The existing captured-session error row must be visibly published")
                            }
                        } else {
                            XCTAssertFalse(session.items.contains { $0.kind == .error }, "A stale Discard failure must not be presented on a successor binding or slot")
                        }
                    }
                }
            }
        }

        func testDeferredBannerActionsRejectChangedObjectBindingWorkspaceOrSlot() async throws {
            for discard in [false, true] {
                for drift in ["unchanged", "binding", "workspace", "slot", "object"] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        try installSwitch(fixture)
                        session.providerSessionID = "clicked-native-context"
                        let clickedSlot = session.pendingHandoff
                        let manager = vm.workspaceManager
                        defer { vm.workspaceManager = manager }
                        var saves = 0
                        var retirements = 0
                        vm.test_setAgentSessionSaver { _, _, _ in
                            saves += 1
                            return fixture.rootURL.appendingPathComponent("banner-discard.json")
                        }
                        vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                        // This is the synchronous button entry. No await permits its task to
                        // enter before the fixture changes the clicked identity or pending slot.
                        let action = try XCTUnwrap(vm.requestProviderSwitchBannerAction(for: session, discard: discard))
                        let live: AgentTabSession
                        if drift == "object" {
                            live = AgentTabSession(tabID: session.tabID)
                            live.testInstallPersistentSessionBinding(sessionID: UUID())
                            live.pendingHandoff = clickedSlot
                            vm.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: live)
                        } else {
                            live = session
                            if drift == "binding" { session.testInstallPersistentSessionBinding(sessionID: UUID()) }
                            if drift == "workspace" { vm.workspaceManager = nil }
                            if drift == "slot" || drift == "binding" {
                                session.pendingHandoff = try .init(payload: switchCarrier(padding: 1), createdAt: Date(), sourceItemID: session.items.last?.id, providerSwitchDelivery: .sending)
                            }
                        }
                        let sourceSlot = session.pendingHandoff
                        let liveSlot = live.pendingHandoff
                        let sourceRows = session.items.map(\.id)
                        let liveRows = live.items.map(\.id)
                        let applied = await action.value
                        XCTAssertEqual(retirements, 0, "Banner actions never retire a provider")
                        XCTAssertEqual(session.providerSessionID, "clicked-native-context")
                        if drift == "unchanged" {
                            XCTAssertTrue(applied)
                            if discard {
                                XCTAssertEqual(saves, 1)
                                XCTAssertEqual(session.pendingHandoff, .init())
                                XCTAssertNil(vm.providerSwitchPreview, "Direct banner Discard never publishes Review")
                                XCTAssertEqual(Array(session.items.dropLast()).map(\.id), sourceRows)
                                XCTAssertEqual(session.items.last?.text, "Pending handover discarded; chat history unchanged.")
                                XCTAssertEqual(session.items.count(where: { $0.recoveryDiagnostic?.outcome == "discarded" }), 1)
                            } else {
                                XCTAssertEqual(saves, 0)
                                XCTAssertTrue(vm.providerSwitchPreview?.session === session)
                                XCTAssertEqual(vm.providerSwitchPreview?.originalHandoff, clickedSlot)
                                vm.cancelProviderSwitchPreview()
                                XCTAssertEqual(session.pendingHandoff, clickedSlot)
                                XCTAssertEqual(session.items.map(\.id), sourceRows)
                            }
                        } else {
                            XCTAssertFalse(applied, "The deferred \(discard ? "Discard" : "Review") must reject \(drift) drift")
                            XCTAssertEqual(saves, 0)
                            XCTAssertNil(vm.providerSwitchPreview)
                            XCTAssertEqual(session.pendingHandoff, sourceSlot)
                            XCTAssertEqual(live.pendingHandoff, liveSlot)
                            XCTAssertEqual(session.items.map(\.id), sourceRows)
                            XCTAssertEqual(live.items.map(\.id), liveRows)
                            XCTAssertFalse(live.items.contains { $0.recoveryDiagnostic?.outcome == "discarded" })
                        }
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                        XCTAssertNil(live.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testGenerationStartupFailureCannotMutateReplacementBuildingPreview() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation-startup.json") }
                let startEntered = AgentSessionLinkStopSignal<Void>()
                let startRelease = AgentSessionLinkStopSignal<Void>()
                let buildEntered = AgentSessionLinkStopSignal<Void>()
                let buildRelease = AgentSessionLinkStopSignal<Void>()
                defer { startRelease.finish(())
                    buildRelease.finish(())
                    vm.test_providerSwitchGenerationStart = nil
                    vm.test_afterProviderInputAugmentation = nil
                }
                vm.test_providerSwitchGenerationStart = { _, _, _ in
                    startEntered.finish(())
                    await startRelease.value() // Default recorder outcome is the real failed-start branch.
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "first", tabID: session.tabID)
                let first = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let generation = Task { await vm.generateProviderSwitchHandover(first) }
                await startEntered.value()
                vm.cancelProviderSwitchPreview()
                vm.test_afterProviderInputAugmentation = { buildEntered.finish(())
                    await buildRelease.value()
                }
                let replacement = Task { await vm.openProviderSwitchPreview(agent: .openCode, model: "replacement", tabID: session.tabID) }
                await buildEntered.value()
                let replacementID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                XCTAssertTrue(vm.providerSwitchPreview?.choices.isEmpty == true)
                startRelease.finish(())
                await generation.value
                XCTAssertEqual(vm.providerSwitchPreview?.id, replacementID)
                XCTAssertTrue(vm.providerSwitchPreview?.choices.isEmpty == true)
                XCTAssertNil(vm.providerSwitchPreview?.failure)
                XCTAssertNil(vm.providerSwitchPreview?.generationItemID)
                buildRelease.finish(())
                _ = await replacement.value
            }
        }

        func testGenerationSettlementCannotWriteIntoNewerCompletedPreview() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("generation-settlement.json") }
                vm.test_providerSwitchGeneration = { outgoing, _, _ in
                    outgoing.appendItem(.assistant("old generated summary", sequenceIndex: outgoing.nextSequenceIndex))
                    outgoing.runState = .completed
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "first", tabID: session.tabID)
                let first = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let rebuildEntered = AgentSessionLinkStopSignal<Void>()
                let rebuildRelease = AgentSessionLinkStopSignal<Void>()
                let rebuildFinished = AgentSessionLinkStopSignal<Void>()
                defer { rebuildRelease.finish(())
                    vm.test_afterProviderInputAugmentation = nil
                    vm.test_providerSwitchGenerationRebuildDidFinish = nil
                }
                vm.test_providerSwitchGenerationRebuildDidFinish = { rebuildFinished.finish(()) }
                vm.test_afterProviderInputAugmentation = { rebuildEntered.finish(())
                    await rebuildRelease.value()
                }
                await vm.generateProviderSwitchHandover(first)
                await rebuildEntered.value()
                vm.cancelProviderSwitchPreview()
                vm.test_afterProviderInputAugmentation = nil
                await vm.openProviderSwitchPreview(agent: .openCode, model: "newer", tabID: session.tabID)
                let newer = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertFalse(newer.building)
                rebuildRelease.finish(())
                await rebuildFinished.value()
                XCTAssertEqual(vm.providerSwitchPreview?.id, newer.id)
                XCTAssertEqual(vm.providerSwitchPreview?.selected, newer.selected)
                XCTAssertNil(vm.providerSwitchPreview?.generatedSummary)
                XCTAssertNil(vm.providerSwitchPreview?.choices.first(where: { $0.mode == .summary })?.carrier)
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testConfiguredWindowDriftAfterAdmissionRefusesAtPhysicalFence() async throws {
            let store = ClaudeCodeCompatibleBackendStore.shared
            let original = store.config(for: .glmZAI)
            defer { store.saveConfig(original) }
            var config = original
            config.modelBehavior = .claudeSlotMapping(.init(haiku: "glm-5.2", sonnet: "glm-5.2", opus: "glm-5.2[1m]"))
            for drift in [false, true] {
                store.saveConfig(config)
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .claudeCodeGLM
                    session.selectedModelRaw = "opus"
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    XCTAssertEqual(preparation.catalogWindow, 1_000_000)
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("window.json") }
                    let prepared = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertNotNil(prepared)
                    session.installRunID(UUID())
                    session.beginRunAttempt(source: "test.switch.windowFence")
                    let sending = session.pendingHandoff
                    if drift {
                        var changed = config
                        changed.modelBehavior = .claudeSlotMapping(.init(haiku: "glm-5.2", sonnet: "glm-5.2", opus: "glm-5.2"))
                        store.saveConfig(changed)
                        XCTAssertNotEqual(vm.providerSwitchCatalogWindow(agent: session.selectedAgent, model: session.selectedModelRaw), preparation.catalogWindow)
                    }
                    XCTAssertEqual(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: UUID())), !drift)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    XCTAssertEqual(session.pendingHandoff.payload, sending.payload)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
                    if drift { XCTAssertNil(session.pendingHandoff.providerSwitchDispatch?.dispatchID) }
                }
            }
        }

        func testCompositionDriftAfterAdmissionRefusesAtPhysicalFence() async throws {
            for drift in ["unchanged", "computerUse", "taskRole"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    XCTAssertTrue(preparation.historyToolAllowed)
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("physical-policy.json") }
                    let prepared = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertNotNil(prepared)
                    session.installRunID(UUID())
                    session.beginRunAttempt(source: "test.switch.compositionFence")
                    if drift == "computerUse" { session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date()) }
                    if drift == "taskRole" {
                        let id = try XCTUnwrap(session.activeAgentSessionID)
                        let registration = await AgentRunSessionStore.register(sessionID: id)
                        session.mcpControlContext = .init(sessionID: id, activationID: UUID(), registration: registration, currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil, originatingConnectionID: nil, interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil), suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: session.autoEditEnabled, taskLabelKind: .explore)
                        XCTAssertNotEqual(vm.providerSwitchInstructionStrings(session), preparation.instructions)
                        XCTAssertTrue(AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(toolName: "history", taskLabelKind: session.mcpControlContext?.taskLabelKind), "This role change affects composition, not history availability")
                    }
                    XCTAssertEqual(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .codexNativeSend(UUID())), drift == "unchanged")
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
                    if drift != "unchanged" { XCTAssertNil(session.pendingHandoff.providerSwitchDispatch?.dispatchID) }
                }
            }
        }

        func testOwnedSwitchCarryingAttemptIsBusyUntilTerminalSettlementThenOrphan() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: session.tabID, session: session))
                let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: "")
                guard case let .claimed(claim) = vm.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else { return XCTFail("Expected exact composer claim") }
                defer { vm.releaseComposerSubmitClaim(claim) }
                let preparation = try await switchPreparation(fixture)
                let input = AgentChatItem.user("accepted carrying input", sequenceIndex: session.nextSequenceIndex)
                let accepted = preparation.accepting(input.id, session: session)
                session.appendItem(input)
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                vm.test_setAgentSessionSaver { saved, _, _ in
                    if saved.pendingHandoffProviderSwitchDelivery == .sending { entered.finish(())
                        await release.value()
                    }
                    return fixture.rootURL.appendingPathComponent("owned-carrier.json")
                }
                let prepare = Task {
                    let messages = await vm.prepareProviderSwitchHandoverForSend(accepted, session: session, stopFence: .init(session: session))
                    if messages == nil { entered.finish(()) }
                    return messages
                }
                await entered.value()
                @MainActor func failure() -> AgentSessionLinkSendFailure? {
                    AgentSessionLinkDeliveryReadiness.failure(snapshot: AgentModeViewModel.agentSessionLinkDeliveryReadinessSnapshot(session: session, endpointMatchesGrant: true, isClosing: false))
                }
                XCTAssertEqual(failure(), .targetNotIdle, "The owned sending-save gap is ordinary busy, not uncertainty or stale history")
                XCTAssertFalse(AgentModeViewModel.providerSwitchNeedsReview(session))
                release.finish(())
                let messages = await prepare.value
                XCTAssertNotNil(messages)
                session.installRunID(UUID())
                let ownership = session.beginRunAttempt(source: "test.switch.owned")
                session.runState = .running
                vm.releaseComposerSubmitClaim(claim)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDispatch?.runOwnership, ownership)
                XCTAssertEqual(failure(), .targetNotIdle)
                XCTAssertFalse(AgentModeViewModel.providerSwitchUnconfirmed(session))
                XCTAssertFalse(AgentModeViewModel.providerSwitchNeedsReview(session))
                guard case .failure(.targetNotIdle) = await vm.providerSwitchSendAdmission(session: session, input: "later") else { return XCTFail("Owned input must use existing busy refusal") }
                session.appendItem(.user("a genuinely different later accepted input", sequenceIndex: session.nextSequenceIndex))
                XCTAssertEqual(failure(), .providerHandoverNeedsReview, "The exact owned input exception cannot exempt another accepted row")
                guard case .failure(.providerHandoverNeedsReview) = await vm.providerSwitchSendAdmission(session: session, input: "later") else { return XCTFail("Different later input must still be stale") }
                XCTAssertFalse(try vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: XCTUnwrap(session.runID))))
                await vm.test_publishNaturalCompletion(session)
                XCTAssertNil(session.pendingHandoff.providerSwitchDispatch, "Only the existing terminal publication callback retires retained sending proof")
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                XCTAssertEqual(failure(), .providerSwitchUnconfirmed)
                XCTAssertTrue(session.items.contains { $0.id == input.id })
                guard case .failure(.providerSwitchUnconfirmed) = await vm.providerSwitchSendAdmission(session: session, input: "later") else { return XCTFail("Settled retained sending is a true orphan") }
            }
        }

        func testEarlierSwitchProofCannotAssociateOrDispatchSuccessorRun() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("old-proof.json") }
                _ = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                let originalRun = UUID()
                session.installRunID(originalRun)
                let original = session.beginRunAttempt(source: "test.switch.original")
                session.runState = .running
                let proof = try XCTUnwrap(session.pendingHandoff.providerSwitchDispatch)
                XCTAssertEqual(proof.runOwnership, original)
                XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: originalRun)))
                // A foreign successor is installed before the old publication arrives. No new
                // ordinary admission is asserted here: this is the stale-owner transport fence.
                session.endRunAttempt(ifCurrent: original, source: "test.switch.foreignSuccessor")
                let successorRun = UUID()
                session.installRunID(successorRun)
                let successor = session.beginRunAttempt(source: "test.switch.successor")
                XCTAssertNil(proof.associatingRun(successor))
                XCTAssertEqual(session.pendingHandoff.providerSwitchDispatch?.runOwnership, original)
                XCTAssertFalse(session.pendingHandoff.isStagedForSend)
                XCTAssertTrue(AgentModeViewModel.providerSwitchUnconfirmed(session), "An unrelated active run must not mask a true orphan")
                XCTAssertFalse(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .headlessRun(runID: successorRun)))
                XCTAssertEqual(session.pendingHandoff.payload, preparation.handoff.payload)
                XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.outcome == "sent" })
            }
        }

        func testNativeCodexSharedPhysicalBoundaryConfirmsExactlyOnceForNativeAndFallback() async throws {
            for dispatch in [AgentSessionLinkPromptDispatchID.codexNativeSend(UUID()), .codexFallback(queueID: UUID())] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    let preparation = try await switchPreparation(fixture)
                    var saves: [AgentProviderSwitchDelivery?] = []
                    vm.test_setAgentSessionSaver { saved, _, _ in
                        saves.append(saved.pendingHandoffProviderSwitchDelivery)
                        return fixture.rootURL.appendingPathComponent("native.json")
                    }
                    _ = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                    XCTAssertEqual(saves, [.sending])
                    session.installRunID(UUID())
                    session.beginRunAttempt(source: "test.switch.nativePhysical")
                    XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: dispatch))
                    let context = AgentSessionLinkDispatchContext(session: session, dispatchID: dispatch)
                    vm.acceptAgentSessionLinkDispatch(session: session, context: context, claim: nil)
                    vm.acceptAgentSessionLinkDispatch(session: session, context: context, claim: nil)
                    try await AsyncTestWait.waitUntil("native physical acceptance clear save") { saves.count == 2 }
                    XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                    XCTAssertEqual(session.items.count(where: { $0.recoveryDiagnostic?.outcome == "sent" }), 1)
                    guard case .success(nil) = await vm.providerSwitchSendAdmission(session: session, input: "next") else { return XCTFail("Positive native acceptance must not wedge the next input") }
                }
            }
        }

        func testResidentAndFirstIdleDelegationInputCarryReadySeedWithoutReviewingOwnRow() async throws {
            for resident in [true, false] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .openCode
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    session.draftText = "untouched draft"
                    var starts: [String] = []
                    vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("resident.json") }
                    vm.test_providerSwitchStart = { _, user, _ in starts.append(user) }
                    let rows = session.items.count
                    if resident {
                        let target = try XCTUnwrap(try vm.mcpResidentTarget(sessionID: XCTUnwrap(session.activeAgentSessionID), requiringLoadedState: true))
                        let result = try await vm.mcpSubmitResidentTask(target, text: "resident assigned task", workflow: nil, windowIsAvailable: { true })
                        XCTAssertEqual(result, .startedRun)
                    } else {
                        let result = try await vm.submitDelegationDecision(
                            "first idle decision",
                            tabID: session.tabID,
                            expectedSessionID: XCTUnwrap(session.activeAgentSessionID),
                            stopFence: .init(session: session)
                        )
                        XCTAssertEqual(result, .submitted)
                    }
                    XCTAssertEqual(starts.count, 1)
                    XCTAssertTrue(starts[0].hasPrefix("<repoprompt_provider_handover "))
                    XCTAssertTrue(starts[0].contains(resident ? "resident assigned task" : "first idle decision"))
                    XCTAssertEqual(session.items.count, rows + 1)
                    XCTAssertNotNil(session.items.last?.dispatchedProviderText)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                    XCTAssertEqual(session.draftText, "untouched draft")
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testResidentSubmissionSurfacesProviderSwitchRefusalsInsteadOfBusyOrRecorded() async throws {
            // .sending blocks at admission (unconfirmed); an oversized ready carrier refuses inside
            // persistAndStartNoncomposerTurn (does not fit). Neither may fall back to the generic
            // busy or "input was recorded" errors: nothing was recorded and only the user can fix it.
            for (delivery, padding, expected) in [
                (AgentProviderSwitchDelivery.sending, 0, AgentSessionLinkSendFailure.providerSwitchUnconfirmed.message),
                (.ready, Int(AgentProviderHandover.maximumBytes) + 100, AgentSessionLinkSendFailure.providerHandoverDoesNotFit.message)
            ] {
                let expected = "Task input not submitted: provider switch pending. \(expected)"
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .openCode
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture, padding: padding)
                    session.pendingHandoff.providerSwitchDelivery = delivery
                    let rows = session.items.count
                    let target = try XCTUnwrap(try vm.mcpResidentTarget(sessionID: XCTUnwrap(session.activeAgentSessionID), requiringLoadedState: true))
                    do {
                        _ = try await vm.mcpSubmitResidentTask(target, text: "resident task", workflow: nil, windowIsAvailable: { true })
                        XCTFail("A pending provider switch must refuse resident input")
                    } catch let MCPError.invalidParams(message) {
                        XCTAssertEqual(message, expected)
                    }
                    XCTAssertEqual(session.items.count, rows, "Refused input must not leave a transcript row")
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, delivery, "A refused send must not consume or mutate the handover")
                    XCTAssertNil(session.activeComposerSubmitAttempt, "The submit claim must be released for the next input")
                }
            }
        }

        func testNonLocalAcceptedRowKeepsSwitchOwnershipUntilRunAssociation() async throws {
            // Session-link and MCP sends release their composer claim before the spawned run
            // registers ownership; the durably accepted row must carry the attempt across that
            // window or readiness transiently reports unconfirmed/needs-review.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                let item = AgentChatItem.user("non-local input", sequenceIndex: session.nextSequenceIndex)
                session.appendItem(item)
                _ = preparation.accepting(item.id, session: session)
                XCTAssertNil(session.activeComposerSubmitAttempt)
                XCTAssertTrue(AgentModeViewModel.providerSwitchHasOwnedCarryingAttempt(session))
                session.pendingHandoff.providerSwitchDelivery = .sending
                session.pendingHandoff.isStagedForSend = true
                XCTAssertFalse(AgentModeViewModel.providerSwitchUnconfirmed(session))
                let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(
                    tabID: session.tabID, sessionID: XCTUnwrap(session.activeAgentSessionID),
                    tabName: "Target", isWindowClosing: false
                ))
                let inputs = AgentModeViewModel.sendReadinessInputs(session: session, candidate: candidate, status: .idle)
                XCTAssertTrue(inputs.runStateIsActive, "idle_for_send must agree with send admission during the dispatch window")
                _ = try session.removeItem(at: XCTUnwrap(session.items.firstIndex { $0.id == item.id }))
                session.pendingHandoff.providerSwitchDispatch = nil
                XCTAssertFalse(AgentModeViewModel.providerSwitchHasOwnedCarryingAttempt(session))
                XCTAssertTrue(AgentModeViewModel.providerSwitchUnconfirmed(session))
            }
        }

        func testRestoredDifferingNewestTurnsPayloadUnhidesRowInsteadOfMislabelingHistory() async throws {
            // A saved newest-turns carrier that omits older history predates a budget that now fits
            // full history; retaining it on the Full history row would mislabel real omissions.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
                /// The saved payload omits turn 0, which the fresh (short) history would include.
                func tinyTurn(_ text: String, _ index: Int) -> AgentTranscriptTurn {
                    let request = AgentChatItem.user(text, sequenceIndex: index)
                    return AgentTranscriptTurn(
                        request: .init(from: request), responseSpans: [], conclusionActivityID: nil,
                        terminalState: .completed, startedAt: request.timestamp, completedAt: request.timestamp
                    )
                }
                let projection = try AgentProviderHandover.project(AgentTranscript(turns: [
                    tinyTurn(String(repeating: "x", count: 40000), 0), tinyTurn("recent", 1)
                ]))
                let source = try AgentProviderHandover.Source(provider: "source", model: "source-model")
                let budget = AgentProviderHandover.Budget(catalogWindow: 24000, instructions: [], composedInput: "", isPreview: false)
                let carrier = try XCTUnwrap(AgentProviderHandover.newestCompleteTurns(
                    projection, source: source, historyReference: nil, budget: budget
                ))
                let payload = AgentProviderHandover.render(carrier)
                session.pendingHandoff = try .init(
                    payload: payload, createdAt: Date(),
                    sourceItemID: session.items.last?.id, providerSwitchDelivery: .ready
                )
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                try await AsyncTestWait.waitUntil("review settled") { vm.providerSwitchPreview?.building == false }
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertNil(preview.choices.first { $0.mode == .history }?.unavailable, "Precondition: fresh full history fits")
                let recent = try XCTUnwrap(preview.choices.first { $0.mode == .newestTurns })
                XCTAssertFalse(recent.hidden, "A differing restored payload must surface on its own row")
                XCTAssertEqual(recent.retainedPayload, payload)
                XCTAssertNil(preview.choices.first { $0.mode == .history }?.retainedPayload)
                XCTAssertEqual(preview.selected, .newestTurns)
            }
        }

        func testInstructionWaitReplyFlowsDuringOwnedBoundSwitchSend() async throws {
            // While the carrying dispatch is bound and its turn waits for user instruction, only the
            // continuation reply may pass; every other input keeps the retryable busy refusal so no
            // cancel can reach the prompt carrying the handover.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                try installSwitch(fixture)
                let preparation = try await switchPreparation(fixture)
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("wait-switch.json") }
                _ = await vm.prepareProviderSwitchHandoverForSend(preparation, session: session, stopFence: .init(session: session))
                session.installRunID(UUID())
                session.beginRunAttempt(source: "test.switch.waitReply")
                session.runState = .running
                XCTAssertTrue(vm.agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: .codexNativeSend(UUID())))
                let rows = session.items.map(\.id)
                var steerTask: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                XCTAssertEqual(
                    vm.submitUserTurn(
                        text: "steer during flight",
                        tabID: session.tabID,
                        scheduledProviderSwitchSubmission: { steerTask = $0 }
                    ),
                    .submitted
                )
                guard case .blocked = try await (XCTUnwrap(steerTask)).value else {
                    return XCTFail("A steer during the bound in-flight window must stay a busy refusal")
                }
                XCTAssertEqual(session.items.map(\.id), rows, "A refused steer must not append a row that could stale the carrier")
                let waiting = Task { try await vm.waitForNextUserInstruction(tabID: session.tabID, timeoutSeconds: 10) }
                try await AsyncTestWait.waitUntil("continuation installed") { session.instructionContinuation != nil }
                XCTAssertEqual(session.runState, .waitingForUser, "The real wait must own the waiting state the gate keys on")
                defer {
                    session.instructionTimeoutTask?.cancel()
                    session.instructionTimeoutTask = nil
                    session.instructionContinuation?.resume(throwing: CancellationError())
                    session.instructionContinuation = nil
                    session.instructionWaitID = nil
                    session.waitingPrompt = nil
                    waiting.cancel()
                }
                _ = vm.submitUserTurn(text: "the answer", tabID: session.tabID)
                let response = try await waiting.value
                XCTAssertEqual(response.text, "the answer", "The turn's own continuation reply must reach the held input")
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                XCTAssertFalse(AgentModeViewModel.providerSwitchNeedsReview(session), "A bound handover is en route, never stale")
                XCTAssertFalse(AgentModeViewModel.providerSwitchUnconfirmed(session))
            }
        }

        func testSessionLinkSendThroughReadySwitchDeliversHandover() async throws {
            // The send's own accepted row owns the attempt and must not make the send reject itself
            // as stale or busy: the handover-carrying input delivers and the marker reaches .sending.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                try installSwitch(fixture)
                let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(
                    tabID: session.tabID, sessionID: XCTUnwrap(session.activeAgentSessionID),
                    tabName: "Target", isWindowClosing: false
                ))
                let observer = DomainAgentSessionLinkEndpointIdentity(
                    windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
                    persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
                )
                let request = AgentSessionLinkSendRequest(
                    linkID: UUID(), linkGeneration: 1, observerEndpoint: observer,
                    observerDisplayName: "Planning", message: "carry me", workflow: nil
                )
                var starts = 0
                var firstInput: String?
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("link-send.json") }
                vm.test_providerSwitchStart = { _, user, _ in
                    starts += 1
                    firstInput = user
                }
                let outcome = await vm.agentSessionLinkPerformSend(
                    to: candidate, request: request,
                    liveness: { .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false) },
                    commitAuthorization: { .committed }
                )
                guard case .delivered = outcome else {
                    return XCTFail("A send through a ready switch must deliver, got \(outcome)")
                }
                XCTAssertEqual(starts, 1, "The provider switch must drive exactly one start")
                XCTAssertTrue(firstInput?.contains("repoprompt_provider_handover") ?? false, "The carrying input must be prefixed with the handover")
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
            }
        }

        func testForceSwitchAdmissionClassifiesHardAndForceableCauses() async throws {
            // Every blocker the sheet can show is either integrity (hard, unforceable) or the
            // source session's own live state (forceable behind the confirmation).
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                XCTAssertEqual(vm.providerSwitchTransitionAdmission(session), .clear)

                session.isChangingExecutionLocation = true
                XCTAssertEqual(
                    vm.providerSwitchTransitionAdmission(session),
                    .hard(AgentSessionLinkSendFailure.targetNotIdle.message),
                    "A worktree mutation in flight stays hard"
                )
                session.isChangingExecutionLocation = false

                session.pendingHandoff = try .init(payload: "foreign-slot", createdAt: Date())
                XCTAssertEqual(
                    vm.providerSwitchTransitionAdmission(session),
                    .hard(AgentSessionLinkSendFailure.targetBusy.message),
                    "A foreign pending-handoff slot stays hard"
                )
                session.pendingHandoff = .init()

                session.pendingHandoff = try .init(
                    payload: switchCarrier(), createdAt: Date(), providerSwitchDelivery: .ready
                )
                session.items.append(.user("intruder", sequenceIndex: session.nextSequenceIndex))
                if case .hard = vm.providerSwitchTransitionAdmission(session) {} else {
                    XCTFail("A stale pending handover stays hard")
                }
                session.pendingHandoff = .init()

                session.runState = .running
                XCTAssertEqual(vm.providerSwitchTransitionAdmission(session), .forceable(.running))
                session.waitingPrompt = "answer?"
                XCTAssertEqual(vm.providerSwitchTransitionAdmission(session), .forceable(.waitingForInput))
                session.waitingPrompt = nil
                session.runState = .idle
            }
        }

        func testForceSwitchDeclinesPendingInteractionOnceAndStagesHandover() async throws {
            // A confirmed force declines the waiting approval through the ordinary cancel path
            // exactly once, then stages the normal ready handover.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.waitingPrompt = "answer?"
                session.pendingApproval = AgentApprovalRequest(
                    requestID: .codex(.int(1)),
                    method: "item/commandExecution/requestApproval",
                    kind: .commandExecution, threadID: "t", turnID: "t", itemID: "i"
                )
                var saves = 0
                vm.test_setAgentSessionSaver { _, _, _ in
                    saves += 1
                    return fixture.rootURL.appendingPathComponent("forced.json")
                }
                var retirements = 0
                vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                if case .forceable(.waitingForInput) = vm.providerSwitchPreviewAdmission(preview) {} else {
                    return XCTFail("A pending approval must classify as forceable waiting-for-input")
                }
                let refused = await vm.applyProviderSwitch(preview.id)
                XCTAssertFalse(refused, "Without the explicit force confirmation the same state must refuse")
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertTrue(
                    forced,
                    "admission=\(vm.providerSwitchPreviewAdmission(preview)) selected=\(String(describing: preview.selected)) chosen=\(String(describing: preview.chosen?.mode)) failure=\(String(describing: preview.failure)) building=\(preview.building)"
                )
                XCTAssertEqual(saves, 1)
                XCTAssertEqual(retirements, 1)
                XCTAssertNil(session.pendingApproval, "The approval is declined, never accepted")
                XCTAssertNil(session.waitingPrompt)
                XCTAssertEqual(session.selectedAgent, .openCode)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                XCTAssertNotNil(session.pendingHandoff.payload)
            }
        }

        func testForceSwitchRefusesBeforeDetachWhileRunOwnershipRemains() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.installRunID(UUID())
                session.beginRunAttempt(source: "test.unsettled")
                session.runState = .running
                vm.test_providerSwitchForceStop = { s in s.runState = .cancelled
                    s.agentTask = nil
                }
                var retirements = 0
                vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                let source = session.selectedAgent
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let applied = await vm.applyProviderSwitch(id, force: true)
                XCTAssertFalse(applied)
                XCTAssertEqual(retirements, 0)
                XCTAssertEqual(session.selectedAgent, source)
                XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                XCTAssertNotNil(session.activeRunOwnership)
                XCTAssertNil(session.activeComposerSubmitAttempt)
                session.endCurrentRunAttempt(source: "test.cleanup")
            }
        }

        func testForceSwitchStopsTheRunAndProceeds() async throws {
            // A live run is stopped through the ordinary local-Stop path before the handover.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.installRunID(UUID())
                session.beginRunAttempt(source: "test.force")
                session.runState = .running
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("forced-run.json") }
                var stops = 0
                vm.test_providerSwitchForceStop = { s in
                    stops += 1
                    s.runState = .cancelled
                    s.agentTask = nil
                    s.endCurrentRunAttempt(source: "test.force.settled")
                }
                vm.test_providerSwitchRetirement = { _ in }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(vm.providerSwitchTransitionAdmission(session), .forceable(.running))
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertTrue(forced)
                XCTAssertEqual(stops, 1, "Forcing goes through the ordinary stop exactly once")
                XCTAssertEqual(session.selectedAgent, .openCode)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
            }
        }

        func testForceSwitchStagesPayloadRenderedFromPostStopTranscript() async throws {
            // The staged handover must be projected after the managed stop, not from the
            // preview's pre-stop carriers: the stop's own transcript rows belong in it, and
            // the staged cutoff must reach them.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.installRunID(UUID())
                session.beginRunAttempt(source: "test.force")
                session.runState = .running
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("forced-post-stop.json") }
                var stopItemID: UUID?
                vm.test_providerSwitchForceStop = { s in
                    // Production shape: a settled .cancelled run, not .idle.
                    s.runState = .cancelled
                    s.agentTask = nil
                    s.endCurrentRunAttempt(source: "test.force.settled")
                    let marker = AgentChatItem.assistant("post-stop-marker-text", sequenceIndex: s.nextSequenceIndex)
                    stopItemID = marker.id
                    s.appendItem(marker)
                }
                vm.test_providerSwitchRetirement = { _ in }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                let preStopPayload = try XCTUnwrap(preview.chosen?.carrier.map { AgentProviderHandover.render($0) })
                XCTAssertFalse(preStopPayload.contains("post-stop-marker-text"))
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertTrue(forced)
                let payload = try XCTUnwrap(session.pendingHandoff.payload)
                XCTAssertNotEqual(payload, preStopPayload, "The preview's pre-stop carrier must never stage")
                XCTAssertTrue(
                    payload.contains("post-stop-marker-text"),
                    "The staged carrier must be projected from the post-stop transcript"
                )
                XCTAssertEqual(session.pendingHandoff.sourceItemID, stopItemID, "The cutoff must reach the stop's own rows")
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
            }
        }

        func testForceSwitchRefusesWhenPostStopCarrierNoLongerFits() async throws {
            // A post-stop projection that outgrows the budget refuses before retirement:
            // source already stopped, Review surfaced, nothing staged, provider intact.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let provider = session.selectedAgent
                session.installRunID(UUID())
                session.beginRunAttempt(source: "test.force")
                session.runState = .running
                var stops = 0
                var retirements = 0
                var saves = 0
                vm.test_setAgentSessionSaver { _, _, _ in
                    saves += 1
                    return fixture.rootURL.appendingPathComponent("unexpected-forced-save.json")
                }
                vm.test_providerSwitchForceStop = { s in
                    stops += 1
                    s.runState = .cancelled
                    s.agentTask = nil
                    s.endCurrentRunAttempt(source: "test.force.settled")
                    s.appendItem(.assistant(String(repeating: "x", count: AgentProviderHandover.maximumBytes + 1), sequenceIndex: s.nextSequenceIndex))
                }
                vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(vm.providerSwitchTransitionAdmission(session), .forceable(.running))
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertFalse(forced)
                XCTAssertEqual(stops, 1, "The managed stop still ran before the refusal")
                XCTAssertEqual(retirements, 0, "A predictable fit refusal precedes irreversible retirement")
                XCTAssertEqual(
                    vm.providerSwitchPreview?.failure,
                    AgentSessionLinkSendFailure.providerHandoverNeedsReview.message,
                    "The refusal surfaces Review like the existing late path"
                )
                XCTAssertEqual(session.selectedAgent, provider)
                XCTAssertNil(session.pendingHandoff.payload)
                XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                XCTAssertEqual(saves, 0)
            }
        }

        func testForceSwitchRebuildsOnceWhenRowsLandDuringRetirement() async throws {
            // Retirement writes no transcript rows itself, but a detached stop/provider tail can:
            // the apply must rebuild once against the now-final transcript instead of staging
            // the pre-retirement bytes.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.installRunID(UUID())
                session.beginRunAttempt(source: "test.force")
                session.runState = .running
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("forced-retire-drift.json") }
                vm.test_providerSwitchForceStop = { s in
                    s.runState = .cancelled
                    s.agentTask = nil
                    s.endCurrentRunAttempt(source: "test.force.settled")
                }
                var retireMarkerID: UUID?
                var retirements = 0
                vm.test_providerSwitchRetirement = { s in
                    retirements += 1
                    let marker = AgentChatItem.assistant("retire-tail-marker-text", sequenceIndex: s.nextSequenceIndex)
                    retireMarkerID = marker.id
                    s.appendItem(marker)
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertTrue(forced)
                XCTAssertEqual(retirements, 1)
                let payload = try XCTUnwrap(session.pendingHandoff.payload)
                XCTAssertTrue(
                    payload.contains("retire-tail-marker-text"),
                    "Rows landing during retirement must reach the rebuilt carrier"
                )
                XCTAssertEqual(session.pendingHandoff.sourceItemID, retireMarkerID)
            }
        }

        func testForceSwitchRefusesWhenSourceStaysLiveAfterTheStop() async throws {
            // A still-live source after the managed stop has no settled transcript to hand
            // over; staging a carrier from it would repeat the in-flight-turn defect, so the
            // apply refuses to Review before any retirement.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let provider = session.selectedAgent
                session.installRunID(UUID())
                session.beginRunAttempt(source: "test.force")
                session.runState = .running
                var stops = 0
                var retirements = 0
                var saves = 0
                vm.test_setAgentSessionSaver { _, _, _ in
                    saves += 1
                    return fixture.rootURL.appendingPathComponent("unexpected-wedged-save.json")
                }
                vm.test_providerSwitchForceStop = { _ in
                    stops += 1
                    // Wedged provider: the stop hook leaves the source live, as a detached
                    // stop that never settled would.
                }
                vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertFalse(forced)
                XCTAssertEqual(stops, 1)
                XCTAssertEqual(retirements, 0, "Refusal precedes retirement; the detached stop is left to finish")
                XCTAssertEqual(
                    vm.providerSwitchPreview?.failure,
                    AgentSessionLinkSendFailure.providerHandoverNeedsReview.message
                )
                XCTAssertEqual(session.selectedAgent, provider)
                XCTAssertNil(session.pendingHandoff.payload)
                XCTAssertEqual(saves, 0)
            }
        }

        func testForceSwitchRefusedOnHardBlocker() async throws {
            // Force only bypasses source liveness; a foreign handoff slot still refuses outright.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let provider = session.selectedAgent
                session.pendingHandoff = try .init(payload: "foreign-slot", createdAt: Date())
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertFalse(forced)
                XCTAssertEqual(session.selectedAgent, provider)
                XCTAssertEqual(session.pendingHandoff.payload, "foreign-slot")
            }
        }

        func testForceSwitchCompletesBeforeHeldRetirementIsReleased() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.waitingPrompt = "answer?"
                vm.test_providerSwitchStopDeadlineSeconds = 0.01
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("forced-deadline.json") }
                let retirement = TestReleaseFence(name: "forced switch retirement")
                var retirementEntered = false
                var retirementFinished = false
                vm.test_providerSwitchRetirement = { _ in
                    retirementEntered = true
                    await retirement.enterAndWait()
                    retirementFinished = true
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(vm.providerSwitchPreviewAdmission(preview), .forceable(.waitingForInput))
                var applyFinished = false
                let apply = Task {
                    let result = await vm.applyProviderSwitch(preview.id, force: true)
                    applyFinished = true
                    return result
                }
                do {
                    try await AsyncTestWait.waitUntil("forced switch retirement entered", timeout: 2) { retirementEntered }
                    try await AsyncTestWait.waitUntil("forced switch completes while retirement is held", timeout: 1) { applyFinished }
                    XCTAssertFalse(retirementFinished, "Outstanding retirement must remain running, not be cancelled to escape the wait")
                    XCTAssertEqual(session.selectedAgent, .openCode)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                    XCTAssertNotNil(session.pendingHandoff.payload)
                    XCTAssertNil(vm.providerSwitchMutation)
                } catch {
                    retirement.release()
                    _ = await apply.value
                    throw error
                }
                retirement.release()
                let applied = await apply.value
                XCTAssertTrue(applied)
                try await AsyncTestWait.waitUntil("released retirement finishes", timeout: 2) { retirementFinished }
            }
        }

        func testForceSwitchForeignHandoffStaysHardWhileSourceIsBusy() async throws {
            // Exercise the existing foreign-slot fixture with each independent live busy flag.
            // These are VM admission states, not evidence of a provider producing the overlap.
            for awaitingApproval in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    let provider = session.selectedAgent
                    session.pendingHandoff = try .init(payload: "foreign-slot", createdAt: Date())
                    if awaitingApproval {
                        session.pendingApproval = AgentApprovalRequest(
                            requestID: .codex(.int(1)),
                            method: "item/commandExecution/requestApproval",
                            kind: .commandExecution, threadID: "t", turnID: "t", itemID: "i"
                        )
                    } else {
                        session.mcpFollowUpRunPending = true
                    }
                    let handoff = session.pendingHandoff
                    let approval = session.pendingApproval
                    var retirements = 0
                    var saves = 0
                    vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                    vm.test_setAgentSessionSaver { _, _, _ in
                        saves += 1
                        return fixture.rootURL.appendingPathComponent("unexpected-forced-switch.json")
                    }
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                    let preview = try XCTUnwrap(vm.providerSwitchPreview)
                    XCTAssertFalse(preview.building)
                    XCTAssertNil(preview.failure)
                    let chosen = try XCTUnwrap(preview.chosen)
                    XCTAssertNil(chosen.unavailable)
                    XCTAssertEqual(vm.providerSwitchPreviewAdmission(preview), .hard(AgentSessionLinkSendFailure.targetBusy.message))
                    XCTAssertEqual(session.pendingApproval, approval, "Admission must not resolve the pending approval")
                    let forced = await vm.applyProviderSwitch(preview.id, force: true)
                    XCTAssertFalse(forced, "Foreign handoff remains hard; awaitingApproval=\(awaitingApproval)")
                    XCTAssertEqual(session.selectedAgent, provider)
                    XCTAssertEqual(session.pendingHandoff, handoff)
                    XCTAssertEqual(session.pendingApproval, approval, "Force refusal must neither approve nor clear the pending approval")
                    XCTAssertEqual(session.mcpFollowUpRunPending, !awaitingApproval)
                    XCTAssertEqual(retirements, 0)
                    XCTAssertEqual(saves, 0)
                }
            }
        }

        func testForceSwitchLatchedCompactFailureStaysHard() async throws {
            // A settled compact failure is integrity state (failed required save / unconfirmed
            // delivery), not live work: no force affordance, and a worktree flag still outranks
            // any live-state classification.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selfCompactState = AgentSelfCompactState(latest: .malformedRecovery())
                XCTAssertEqual(
                    vm.providerSwitchTransitionAdmission(session),
                    .hard(AgentModeViewModel.SendBlocker.pendingSelfCompact.rawValue),
                    "A latched compact recovery is a persistence-integrity refusal"
                )
                session.isChangingExecutionLocation = true
                XCTAssertEqual(
                    vm.providerSwitchTransitionAdmission(session),
                    .hard(AgentSessionLinkSendFailure.targetNotIdle.message),
                    "The worktree guard must precede every live-state classification"
                )
            }
        }

        func testForceSwitchWithdrawsQueuedWorkWithNoActiveRun() async throws {
            // Queued producers with no live run are withdrawn through the same claim-time path an
            // explicit Stop runs — nothing stays armed to dispatch under the new provider.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.mcpFollowUpRunPending = true
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("forced-queued.json") }
                vm.test_providerSwitchRetirement = { _ in }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(
                    vm.providerSwitchTransitionAdmission(session),
                    .forceable(.workInFlight),
                    "Queued work with no live run classifies as forceable"
                )
                let forced = await vm.applyProviderSwitch(preview.id, force: true)
                XCTAssertTrue(forced)
                XCTAssertFalse(session.mcpFollowUpRunPending, "The armed follow-up is withdrawn, never replayed")
                XCTAssertEqual(session.selectedAgent, .openCode)
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
            }
        }

        func testLateClaudeResumeTransferWriteCannotReachDestinationProvider() async throws {
            // B2: a transfer whose teardown completes after the forced switch retired the source
            // provider must not write the old Claude providerSessionID — or a destination-stamped
            // cleanup handle — onto the new provider, and the latch must not wedge.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .claudeCode
                session.providerSessionID = "old-claude-session"
                let coordinator = vm.test_claudeCoordinator
                coordinator.test_registerResumeTransfer(for: session, controller: LateTransferFakeRuntime())
                XCTAssertTrue(coordinator.hasPendingResumeTransfer(for: session))
                session.selectedAgent = .openCode
                await coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                XCTAssertEqual(session.providerSessionID, "old-claude-session")
                XCTAssertFalse(coordinator.hasPendingResumeTransfer(for: session))
            }
        }

        func testLateClaudeResumeTransferCannotWriteOntoSameFamilyDestination() async throws {
            // B2 epoch guard: a forced .claudeCode → .claudeCodeGLM switch rotates the runtime
            // context epoch, so a transfer stamped with the old epoch must not write the old
            // Claude session ref onto the same-family destination.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .claudeCode
                session.providerSessionID = "old-claude-session"
                let coordinator = vm.test_claudeCoordinator
                coordinator.test_registerResumeTransfer(for: session, controller: LateTransferFakeRuntime())
                XCTAssertTrue(coordinator.hasPendingResumeTransfer(for: session))
                session.selectedAgent = .claudeCodeGLM
                coordinator.rotateClaudeRuntimeEpoch(for: session)
                session.providerSessionID = "glm-session"
                await coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                XCTAssertEqual(session.providerSessionID, "glm-session")
                XCTAssertFalse(coordinator.hasPendingResumeTransfer(for: session))
            }
        }

        func testLateClaudeResumeTransferCannotWriteOntoSwitchBackSession() async throws {
            // B2 epoch guard: Claude → Codex → Claude switch-back rotates the epoch twice, so
            // the stale transfer completing late must not overwrite the new Claude session ref.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .claudeCode
                session.providerSessionID = "old-claude-session"
                let coordinator = vm.test_claudeCoordinator
                coordinator.test_registerResumeTransfer(for: session, controller: LateTransferFakeRuntime())
                session.selectedAgent = .codexExec
                coordinator.rotateClaudeRuntimeEpoch(for: session)
                session.selectedAgent = .claudeCode
                coordinator.rotateClaudeRuntimeEpoch(for: session)
                session.providerSessionID = "new-claude-session"
                await coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                XCTAssertEqual(session.providerSessionID, "new-claude-session")
                XCTAssertFalse(coordinator.hasPendingResumeTransfer(for: session))
            }
        }

        func testOrdinaryClaudeResumeTransferStillWritesSessionIDUnderEpochGuard() async throws {
            // Positive control: an ordinary stop/detach on a Claude tab — no provider-context
            // clear, no epoch rotation — must still adopt the transferred session ref and
            // clear the latch.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .claudeCode
                session.providerSessionID = "old-claude-session"
                let coordinator = vm.test_claudeCoordinator
                coordinator.test_registerResumeTransfer(for: session, controller: LateTransferFakeRuntime())
                XCTAssertTrue(coordinator.hasPendingResumeTransfer(for: session))
                await coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                XCTAssertEqual(session.providerSessionID, "late-claude-ref")
                XCTAssertFalse(coordinator.hasPendingResumeTransfer(for: session))
            }
        }

        func testStaleDetachedEpochCannotWriteOntoSuccessorClaudeSession() async throws {
            // B2 ownership: the first detach captures E1 into its controller; after the forced
            // Claude → Codex switch and a switch-back, the successor cancel detaches with E2.
            // The FIRST teardown's late transfer registration must use its own E1 stamp —
            // it cannot inherit E2 — so its write is dropped while the second transfer
            // (stamped E2) still completes normally.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .claudeCode
                let coordinator = vm.test_claudeCoordinator
                let first = coordinator.test_makeDetachedClaudeController(
                    for: session,
                    controller: LateTransferFakeRuntime(sessionRefID: "first-ref")
                )
                session.selectedAgent = .codexExec
                coordinator.rotateClaudeRuntimeEpoch(for: session)
                session.selectedAgent = .claudeCode
                coordinator.rotateClaudeRuntimeEpoch(for: session)
                let second = coordinator.test_makeDetachedClaudeController(
                    for: session,
                    controller: LateTransferFakeRuntime(sessionRefID: "second-ref")
                )
                session.providerSessionID = "new-claude-session"
                coordinator.test_registerResumeTransfer(for: session, oldController: first)
                await coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                XCTAssertEqual(session.providerSessionID, "new-claude-session")
                XCTAssertFalse(coordinator.hasPendingResumeTransfer(for: session))
                coordinator.test_registerResumeTransfer(for: session, oldController: second)
                await coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                XCTAssertEqual(session.providerSessionID, "second-ref")
                XCTAssertFalse(coordinator.hasPendingResumeTransfer(for: session))
            }
        }

        func testClaudeResumeTransferRetiredMidAwaitDoesNotWedgeLatch() async throws {
            // B2 wedge: a transfer retired while its await is in flight on a non-Claude tab
            // must drain the retired latch so hasPendingResumeTransfer returns false.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .claudeCode
                session.providerSessionID = "old-claude-session"
                let coordinator = vm.test_claudeCoordinator
                let runtime = LateTransferFakeRuntime()
                await runtime.setHoldTeardown(true)
                coordinator.test_registerResumeTransfer(for: session, controller: runtime)
                session.selectedAgent = .openCode
                async let wait: Void = coordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                await runtime.waitUntilTeardownStarted()
                coordinator.invalidatePendingClaudeResumeTransfer(for: session)
                await runtime.releaseTeardown()
                await wait
                XCTAssertEqual(session.providerSessionID, "old-claude-session")
                XCTAssertFalse(coordinator.hasPendingResumeTransfer(for: session))
            }
        }

        func testForceAffordanceNeverReachesOverseerOrMCP() async throws {
            // The force gesture lives only in the local sheet: a linked send during the same busy
            // state receives exactly today's retryable busy refusal, never a switch outcome.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.runState = .running
                let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(
                    tabID: session.tabID, sessionID: XCTUnwrap(session.activeAgentSessionID),
                    tabName: "Target", isWindowClosing: false
                ))
                let request = AgentSessionLinkSendRequest(
                    linkID: UUID(), linkGeneration: 1,
                    observerEndpoint: .init(
                        windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(),
                        persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1
                    ),
                    observerDisplayName: "Lane", message: "hi", workflow: nil
                )
                let outcome = await vm.agentSessionLinkPerformSend(
                    to: candidate, request: request,
                    liveness: { .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false) },
                    commitAuthorization: { .committed }
                )
                guard case let .blocked(failure) = outcome else {
                    return XCTFail("A send during a forceable-busy state must stay refused, got \(outcome)")
                }
                XCTAssertEqual(failure, .targetNotIdle)
                XCTAssertTrue(failure.isRetryable, "The busy refusal stays retryable exactly as today")
            }
        }

        func testRestoredIdenticalNewestTurnsFallsBackToFullHistory() async throws {
            // The saved newest-turns carrier equals what the fresh budget renders as full history;
            // the hidden row must resolve to .history rather than a missing selection.
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
                let projection = try AgentProviderHandover.project(session.transcript)
                let source = try AgentProviderHandover.Source(provider: "source", model: "source-model")
                let budget = AgentProviderHandover.Budget(catalogWindow: nil, instructions: [], composedInput: "", isPreview: false)
                let carrier = try XCTUnwrap(AgentProviderHandover.newestCompleteTurns(
                    projection, source: source, historyReference: nil, budget: budget
                ))
                let payload = AgentProviderHandover.render(carrier)
                session.pendingHandoff = try .init(
                    payload: payload, createdAt: Date(),
                    sourceItemID: session.items.last?.id, providerSwitchDelivery: .ready
                )
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                try await AsyncTestWait.waitUntil("identical restore settled") { vm.providerSwitchPreview?.building == false }
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(preview.choices.first { $0.mode == .newestTurns }?.hidden, true)
                XCTAssertNil(preview.choices.first { $0.mode == .history }?.unavailable)
                XCTAssertEqual(preview.selected, .history)
                XCTAssertEqual(preview.choices.first { $0.mode == .history }?.retainedPayload, payload)
            }
        }

        func testOrdinarySendArmingChangeReachesExistingPersistenceBoundary() async throws {
            for initiallyArmed in [false, true] {
                try await withFixture { fixture in
                    enum Fault: Error { case write }
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.pendingCodexComputerUseActivation = initiallyArmed ? .init(id: UUID(), createdAt: Date()) : nil
                    XCTAssertNil(session.pendingHandoff.providerSwitchDelivery)
                    let rows = session.items.map(\.id)
                    let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: session.tabID, sessionID: XCTUnwrap(session.activeAgentSessionID), tabName: "Target", isWindowClosing: false))
                    let observer = DomainAgentSessionLinkEndpointIdentity(windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1)
                    let request = AgentSessionLinkSendRequest(linkID: UUID(), linkGeneration: 1, observerEndpoint: observer, observerDisplayName: "Planning", message: "ordinary SEND", workflow: nil)
                    var saves = 0
                    var starts = 0
                    vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                    vm.test_setAgentSessionSaver { _, _, _ in
                        saves += 1
                        if saves == 1 { throw Fault.write }
                        return fixture.rootURL.appendingPathComponent("ordinary-send-rollback.json")
                    }
                    let result = await vm.agentSessionLinkPerformSend(to: candidate, request: request, liveness: {
                        .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false)
                    }, commitAuthorization: {
                        session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                        return .committed
                    })
                    XCTAssertEqual(result, .blocked(.persistenceFailed), "Ordinary SEND must reach its existing save boundary, not the switch-only arming refusal")
                    XCTAssertGreaterThan(saves, 0)
                    XCTAssertEqual(starts, 0)
                    XCTAssertNil(session.codexController)
                    XCTAssertEqual(session.items.map(\.id), rows)
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testOrdinaryUnloadedSubmissionConsumesOnlyCapturedAttachmentsAndWorkflow() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: fixture.workspace)
                var saved = try XCTUnwrap(loaded)
                saved.agentKind = AgentProviderKind.openCode.rawValue
                saved.agentModel = "unknown-window"
                _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
                fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
                session.selectedAgent = .openCode
                session.selectedModelRaw = "unknown-window"
                let a = fixture.rootURL.appendingPathComponent("submitted.txt")
                let b = fixture.rootURL.appendingPathComponent("later.txt")
                try "submitted file content".write(to: a, atomically: true, encoding: .utf8)
                try "later file content".write(to: b, atomically: true, encoding: .utf8)
                let imageA = AgentFileAttachment(source: .localFile(path: a.path), title: "A")
                let imageB = AgentFileAttachment(source: .localFile(path: b.path), title: "B")
                let fileA = AgentTaggedFileAttachment(relativePath: a.path, displayName: "A")
                let fileB = AgentTaggedFileAttachment(relativePath: b.path, displayName: "B")
                let workflowA = AgentWorkflowDefinition(customID: UUID(), displayName: "W1", template: "W1 $ARGUMENTS")
                let workflowB = AgentWorkflowDefinition(customID: UUID(), displayName: "W2", template: "W2 $ARGUMENTS")
                session.pendingFileAttachments = [imageA]
                session.pendingTaggedFileAttachments = [fileA]
                vm.selectWorkflow(workflowA)
                session.hasLoadedPersistedState = false
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                addTeardownBlock { await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil) }
                await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook { id in
                    guard id == sessionID else { return }
                    await entered.finish(())
                    await release.value()
                }
                var pending: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                var starts: [String] = []
                vm.test_providerSwitchStart = { _, user, _ in starts.append(user) }
                let immediate = vm.submitUserTurn(text: "submitted draft", tabID: session.tabID, scheduledProviderSwitchSubmission: { pending = $0 })
                XCTAssertEqual(immediate, .submitted)
                let deferred = try XCTUnwrap(pending)
                await entered.value()
                session.pendingFileAttachments.append(imageB)
                session.pendingTaggedFileAttachments.append(fileB)
                vm.selectWorkflow(workflowB)
                release.finish(())
                let result = await deferred.value
                XCTAssertEqual(result, .submitted)
                try await AsyncTestWait.waitUntil("ordinary hydrated input reaches owned start seam") { !starts.isEmpty }
                let row = try XCTUnwrap(session.items.last(where: { $0.kind == .user }))
                XCTAssertEqual(row.attachments.map(\.id), [imageA.id])
                XCTAssertEqual(row.taggedFileAttachments.map(\.id), [fileA.id])
                XCTAssertEqual(row.workflow, workflowA)
                XCTAssertEqual(session.pendingFileAttachments.map(\.id), [imageB.id])
                XCTAssertEqual(session.pendingTaggedFileAttachments.map(\.id), [fileB.id])
                XCTAssertEqual(session.selectedWorkflow, workflowB)
                XCTAssertTrue(starts[0].contains("W1 submitted draft"))
                XCTAssertFalse(starts[0].contains("W2 submitted draft"))
                await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
            }
        }

        func testRestoredPendingSwitchRefusalIsAwaitedAndPreservesLocalOrMCPInputState() async throws {
            for ingress in ["localDeferred", "localClaimed", "controlled"] {
                let controlled = ingress == "controlled"
                for kind in ["sending", "stale", "oversize"] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                        let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: fixture.workspace)
                        var saved = try XCTUnwrap(loaded)
                        saved.agentKind = AgentProviderKind.openCode.rawValue
                        saved.agentModel = "unknown-window"
                        saved.pendingHandoffPayload = try switchCarrier(padding: kind == "oversize" ? AgentProviderHandover.maximumBytes : 0)
                        saved.pendingHandoffCreatedAt = Date()
                        saved.pendingHandoffSourceItemID = session.items.last?.id
                        saved.pendingHandoffProviderSwitchDelivery = kind == "sending" ? .sending : .ready
                        if kind == "stale" {
                            let later = AgentChatItem.user("accepted later input", sequenceIndex: session.nextSequenceIndex)
                            saved.items.append(.init(from: later))
                            saved.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                                existingTranscript: saved.transcript ?? .empty,
                                workingItems: session.items + [later], terminalState: .completed,
                                nextSequenceIndex: later.sequenceIndex + 1
                            )
                        }
                        _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: fixture.workspace)
                        fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
                        session.selectedAgent = .openCode
                        session.selectedModelRaw = "unknown-window"
                        session.hasLoadedPersistedState = false
                        vm.storeDraftText(for: session.tabID, "retained local draft")
                        let workflow = AgentWorkflowDefinition(customID: UUID(), displayName: "Retained workflow", template: "W $ARGUMENTS")
                        vm.selectWorkflow(workflow)
                        var starts = 0
                        vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                        let failure: AgentSessionLinkSendFailure = kind == "sending" ? .providerSwitchUnconfirmed : (kind == "stale" ? .providerHandoverNeedsReview : .providerHandoverDoesNotFit)
                        let expected = !controlled && kind == "oversize" ? "Too long to send with the handover." : failure.message
                        if controlled {
                            let registration = await AgentRunSessionStore.register(sessionID: sessionID)
                            session.mcpControlContext = .init(sessionID: sessionID, activationID: UUID(), registration: registration, currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil, originatingConnectionID: nil, interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil), suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: session.autoEditEnabled, taskLabelKind: .explore)
                            vm.test_setMCPControlledTabIDs([session.tabID])
                            do {
                                _ = try await vm.mcpDispatchInstruction(sessionID: sessionID, text: "MCP retained request", allowStartingRun: true)
                                XCTFail("The actual controlled MCP call must await and surface the restored refusal")
                            } catch { XCTAssertTrue(String(describing: error).contains(expected), "\(error)") }
                        } else if ingress == "localClaimed" {
                            let target = try XCTUnwrap(vm.makeComposerSubmitTarget(tabID: session.tabID, session: session))
                            let result = await vm.submitUserTurnCreatingSessionIfNeeded(text: "retained local draft", target: target)
                            XCTAssertEqual(result, .blocked(message: expected))
                        } else {
                            var pending: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                            XCTAssertEqual(vm.submitUserTurn(text: "retained local draft", tabID: session.tabID, scheduledProviderSwitchSubmission: { pending = $0 }), .submitted)
                            let task = try XCTUnwrap(pending)
                            let result = await task.value
                            XCTAssertEqual(result, .blocked(message: expected))
                            XCTAssertEqual(vm.draftRestorationEvent?.message, expected)
                        }
                        XCTAssertEqual(starts, 0)
                        XCTAssertFalse(session.items.contains { $0.kind == .user && ($0.text == "retained local draft" || $0.text == "MCP retained request") })
                        XCTAssertEqual(session.draftText, "retained local draft")
                        XCTAssertEqual(session.selectedWorkflow, workflow)
                        XCTAssertEqual(session.pendingHandoff.payload, saved.pendingHandoffPayload)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testScheduledLocalAndControlledMCPArmingDriftRefusesBeforeAdmission() async throws {
            for controlled in [false, true] {
                for initiallyArmed in [false, true] {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        fixture.window.promptManager.apiSettingsViewModel?.isCodexConnected = true
                        XCTAssertTrue(vm.agentAvailabilityContext.codexAvailable)
                        session.selectedAgent = .codexExec
                        session.selectedModelRaw = vm.defaultModelRaw(for: .codexExec)
                        try installSwitch(fixture)
                        session.pendingCodexComputerUseActivation = initiallyArmed ? .init(id: UUID(), createdAt: Date()) : nil
                        vm.storeDraftText(for: session.tabID, "keep current draft")
                        let file = fixture.rootURL.appendingPathComponent("kept.txt")
                        try "keep attachment".write(to: file, atomically: true, encoding: .utf8)
                        session.pendingFileAttachments = [.init(source: .localFile(path: file.path), title: "kept image")]
                        session.pendingTaggedFileAttachments = [.init(relativePath: file.path, displayName: "kept.txt")]
                        let workflow = AgentWorkflowDefinition(customID: UUID(), displayName: "Kept workflow", template: "workflow $ARGUMENTS")
                        session.selectedWorkflow = workflow
                        let images = session.pendingFileAttachments
                        let files = session.pendingTaggedFileAttachments
                        let rows = session.items.map(\.id)
                        let slot = session.pendingHandoff
                        let entered = AgentSessionLinkStopSignal<Void>()
                        let release = AgentSessionLinkStopSignal<Void>()
                        defer { release.finish(())
                            vm.test_beforeProviderSwitchScheduledAdmission = nil
                        }
                        var didEnter = false
                        vm.test_beforeProviderSwitchScheduledAdmission = { _ in didEnter = true
                            entered.finish(())
                            await release.value()
                        }
                        var starts = 0
                        var saves = 0
                        vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                        vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                            return fixture.rootURL.appendingPathComponent("no-write.json")
                        }
                        if controlled {
                            let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                            let registration = await AgentRunSessionStore.register(sessionID: sessionID)
                            session.mcpControlContext = AgentModeViewModel.AgentMCPControlContext(
                                sessionID: sessionID, activationID: UUID(), registration: registration,
                                currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
                                originatingConnectionID: nil,
                                interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil),
                                suppressUserNotifications: true, forceAutoEditEnabled: false,
                                autoEditEnabledBeforeOverride: session.autoEditEnabled, taskLabelKind: .explore
                            )
                            vm.test_setMCPControlledTabIDs([session.tabID])
                            var finished = false
                            let dispatch = Task { defer { finished = true }
                                return try await vm.mcpDispatchInstruction(sessionID: sessionID, text: "MCP instruction", allowStartingRun: true, workflow: workflow)
                            }
                            defer { dispatch.cancel() }
                            try await AsyncTestWait.waitUntil("controlled MCP reaches the scheduled task gate or refuses") { didEnter || finished }
                            guard didEnter else { return XCTFail("Controlled MCP refused before its scheduled-ingress gate") }
                            await entered.value()
                            session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                            release.finish(())
                            do { _ = try await dispatch.value
                                XCTFail("Controlled MCP must surface the preacceptance refusal")
                            } catch { XCTAssertTrue(String(describing: error).contains(AgentModeViewModel.staleComposerSubmitTargetMessage)) }
                        } else {
                            var task: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                            let scheduled = vm.submitUserTurn(text: "local instruction", tabID: session.tabID, scheduledProviderSwitchSubmission: { task = $0 })
                            XCTAssertEqual(scheduled, .submitted, "The synchronous ingress means scheduled, not accepted")
                            let submission = try XCTUnwrap(task)
                            defer { submission.cancel() }
                            await entered.value()
                            session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                            release.finish(())
                            let result = await submission.value
                            XCTAssertEqual(result, .blocked(message: AgentModeViewModel.staleComposerSubmitTargetMessage))
                        }
                        XCTAssertEqual(starts, 0)
                        XCTAssertEqual(saves, 0)
                        XCTAssertEqual(session.items.map(\.id), rows)
                        XCTAssertEqual(session.draftText, "keep current draft")
                        XCTAssertEqual(session.selectedWorkflow, workflow)
                        XCTAssertEqual(session.pendingFileAttachments, images)
                        XCTAssertEqual(session.pendingTaggedFileAttachments, files)
                        XCTAssertEqual(session.pendingHandoff, slot)
                        XCTAssertNil(session.activeComposerSubmitAttempt)
                    }
                }
            }
        }

        func testPreviewRefreshRetainsGeneratedSummaryUnlessUserPicksHistory() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let initial = try XCTUnwrap(vm.providerSwitchPreview)
                let source = try XCTUnwrap(initial.source)
                let summary = AgentModeViewModel.ProviderSwitchGeneratedSummary(
                    text: "Generated summary", sourceRevision: initial.sourceRevision, cutoff: initial.cutoff,
                    sourceProvider: source.provider, sourceModel: source.model
                )
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID, retainingSummary: summary)
                XCTAssertEqual(vm.providerSwitchPreview?.selected, .summary)
                for explicitPick in [false, true] {
                    let previous = try XCTUnwrap(vm.providerSwitchPreview)
                    if explicitPick { vm.selectProviderSwitchChoice(.history, previewID: previous.id) }
                    session.draftText += " updated"
                    vm.updateBindingsFromSession(session)
                    try await AsyncTestWait.waitUntil("retained summary refresh completes") {
                        vm.providerSwitchPreview?.id != previous.id && vm.providerSwitchPreview?.building == false
                    }
                    XCTAssertEqual(vm.providerSwitchPreview?.selected, explicitPick ? .history : .summary)
                    XCTAssertNotNil(vm.providerSwitchPreview?.generatedSummary)
                }
            }
        }

        func testDiscardApplyAfterDraftDriftClearsOnlySlotWithoutRetirement() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                session.providerSessionID = "native-context-kept"
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                session.draftText = "draft changed without a preview refresh"
                var retirements = 0
                vm.test_providerSwitchRetirement = { _ in retirements += 1 }
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("discard-drift.json") }
                let applied = await vm.applyProviderSwitch(preview.id, discard: true)
                XCTAssertTrue(applied)
                XCTAssertEqual(session.pendingHandoff, .init())
                XCTAssertEqual(session.providerSessionID, "native-context-kept")
                XCTAssertEqual(session.draftText, "draft changed without a preview refresh")
                XCTAssertEqual(retirements, 0)
            }
        }

        func testPreviewRefreshPreservesPickMadeWhileRefreshIsQueued() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                session.pendingHandoff.payload = session.pendingHandoff.payload?.replacingOccurrences(of: "mode=\"history\"", with: "mode=\"newest_turns\"")
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let original = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(original.selected, .newestTurns)
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(())
                    vm.test_beforeProviderSwitchPreviewRefresh = nil
                }
                vm.test_beforeProviderSwitchPreviewRefresh = { _ in entered.finish(())
                    await release.value()
                }
                session.draftText = "changed draft"
                vm.updateBindingsFromSession(session)
                await entered.value()
                vm.selectProviderSwitchChoice(.history, previewID: original.id)
                release.finish(())
                try await AsyncTestWait.waitUntil("refreshed preview keeps live pick over retained mode") {
                    vm.providerSwitchPreview?.id != original.id && vm.providerSwitchPreview?.building == false
                }
                XCTAssertEqual(vm.providerSwitchPreview?.selected, .history)
                let refreshedID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                vm.selectProviderSwitchChoice(.newestTurns, previewID: original.id)
                XCTAssertEqual(vm.providerSwitchPreview?.id, refreshedID)
                XCTAssertEqual(vm.providerSwitchPreview?.selected, .history, "A stale row click must not select in its successor")
            }
        }

        func testDiscardIgnoresContentDriftButPreservesSlotAndLiveWorkGates() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                session.draftText = "draft changed after preview"
                XCTAssertNil(vm.providerSwitchDiscardBlocker(preview))
                session.runState = .running
                XCTAssertNotNil(vm.providerSwitchDiscardBlocker(preview), "Discard cannot clear a live carrying attempt")
                session.runState = .idle
                session.pendingHandoff.payload = "successor slot"
                XCTAssertNotNil(vm.providerSwitchDiscardBlocker(preview), "Discard must not clear a different slot")
            }
        }

        func testPreviewRefreshNeverAdoptsReboundOrReplacedChat() async throws {
            for origin in ["bindings", "queued-bindings", "queued-build"] {
                for replacement in [false, true] where origin != "bindings" || !replacement {
                    try await withFixture { fixture in
                        let vm = fixture.viewModel
                        let session = fixture.sourceSession
                        await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                        let original = try XCTUnwrap(vm.providerSwitchPreview)
                        let refreshEntered = AgentSessionLinkStopSignal<Void>()
                        let refreshRelease = AgentSessionLinkStopSignal<Void>()
                        defer { refreshRelease.finish(())
                            vm.test_beforeProviderSwitchPreviewRefresh = nil
                            vm.test_afterProviderInputAugmentation = nil
                        }
                        vm.test_beforeProviderSwitchPreviewRefresh = { _ in refreshEntered.finish(())
                            await refreshRelease.value()
                        }
                        if origin == "queued-bindings" {
                            session.appendItem(.assistant("same-chat content change", sequenceIndex: session.nextSequenceIndex))
                            vm.updateBindingsFromSession(session)
                            await refreshEntered.value()
                        } else if origin == "queued-build" {
                            let buildEntered = AgentSessionLinkStopSignal<Void>()
                            let buildRelease = AgentSessionLinkStopSignal<Void>()
                            defer { buildRelease.finish(()) }
                            vm.test_afterProviderInputAugmentation = { buildEntered.finish(())
                                await buildRelease.value()
                            }
                            let build = Task { await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID) }
                            await buildEntered.value()
                            session.appendItem(.assistant("drift during read-only preview build", sequenceIndex: session.nextSequenceIndex))
                            vm.test_afterProviderInputAugmentation = nil
                            buildRelease.finish(())
                            _ = await build.value
                            await refreshEntered.value()
                        }
                        let captured = try XCTUnwrap(vm.providerSwitchPreview)
                        let successor: AgentTabSession
                        if replacement {
                            successor = AgentTabSession(tabID: session.tabID)
                            successor.testInstallPersistentSessionBinding(sessionID: UUID())
                            vm.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: successor)
                        } else {
                            successor = session
                            session.testInstallPersistentSessionBinding(sessionID: UUID())
                        }
                        successor.providerSessionID = "successor-native-context"
                        if origin == "bindings" { vm.updateBindingsFromSession(session) }
                        refreshRelease.finish(())
                        try await AsyncTestWait.waitUntil("captured refresh refuses identity loss") { vm.providerSwitchPreview?.building == false || vm.providerSwitchPreview?.id != captured.id }
                        XCTAssertEqual(vm.providerSwitchPreview?.id, captured.id)
                        XCTAssertEqual(vm.providerSwitchPreview?.binding, captured.binding)
                        if origin != "queued-build" { XCTAssertEqual(captured.id, original.id) }
                        XCTAssertNotNil(vm.providerSwitchPreviewBlocker(captured))
                        let applied = await vm.applyProviderSwitch(captured.id)
                        XCTAssertFalse(applied)
                        XCTAssertEqual(successor.providerSessionID, "successor-native-context")
                        XCTAssertNil(successor.pendingHandoff.payload)
                        XCTAssertFalse(successor.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                    }
                }
            }
        }

        func testPreviewUsesDestinationImageRendering() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                session.selectedAgent = .codexExec
                let draft = String(repeating: "current draft ", count: 1000)
                vm.storeDraftText(for: session.tabID, draft)
                session.pendingFileAttachments = [.init(source: .localFile(path: fixture.rootURL.appendingPathComponent("image.png").path), title: "destination image")]
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                let expected = vm.renderProviderMessage(text: draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: preview.composition.images, agent: .openCode)
                let actual = await vm.augmentUserMessageForProviderSend(draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: preview.composition.images, agent: .openCode, session: session, ignoresPendingHandoff: true)
                XCTAssertEqual(actual, expected, "Explicit destination must win over the still-selected source")
                XCTAssertNotEqual(actual, vm.renderProviderMessage(text: draft.trimmingCharacters(in: .whitespacesAndNewlines), attachments: preview.composition.images, agent: session.selectedAgent))
                XCTAssertEqual(try XCTUnwrap(preview.budget).inputTokens, max(2048, AgentProviderHandover.estimate("\n\n" + expected)), accuracy: 0.000001)
                XCTAssertEqual(session.draftText, draft)
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testNativeComputerUseInterviewPreviewMatchesActualAdmittedSubmission() async throws {
            CodexComputerUseWorkflow.setEnabledForTesting(true)
            defer { CodexComputerUseWorkflow.setEnabledForTesting(nil) }
            try await withFixture(computerUseReady: true) { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                fixture.window.promptManager.apiSettingsViewModel?.isCodexConnected = true
                session.selectedAgent = .codexExec
                session.selectedModelRaw = "unknown-window"
                session.setItemsSilently([.user("earlier failed task", sequenceIndex: 0), .error("earlier failure", sequenceIndex: 1)], reason: .testOverride)
                session.transcript = .empty
                session.nextSequenceIndex = 2
                session.runState = .failed
                vm.interviewFirst = true
                let draft = "/computer-use " + String(repeating: "current native task ", count: 1000)
                vm.storeDraftText(for: session.tabID, draft)
                let originalRows = session.items.map(\.id)
                XCTAssertEqual(vm.submitUserTurn(text: draft, tabID: session.tabID), .blocked(message: "Enable Computer Use in this tab before submitting /computer-use."))
                XCTAssertEqual(session.items.map(\.id), originalRows, "Parity must not bypass the existing native arming prerequisite")
                session.pendingCodexComputerUseActivation = .init(id: UUID(), createdAt: Date())
                await vm.openProviderSwitchPreview(agent: .codexExec, model: session.selectedModelRaw, tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertTrue(preview.composition.includesInterview)
                XCTAssertFalse(session.items.contains { $0.kind == .assistant })
                let inputTokens = try XCTUnwrap(preview.budget).inputTokens
                let payloadResult = await vm.providerSwitchPayload(preview.id, mode: .history)
                let payload = try XCTUnwrap(payloadResult)
                vm.cancelProviderSwitchPreview()
                // Install the ready carrier, then use the real local/native ingress and its one
                // admission. Only the final transport is replaced; expected text is not rebuilt.
                session.pendingHandoff = .init(payload: payload, createdAt: Date(), sourceItemID: preview.cutoff, providerSwitchDelivery: .ready)
                var dispatchedInitial: String?
                vm.test_providerSwitchStart = { _, _, initial in dispatchedInitial = initial }
                vm.test_setAgentSessionSaver { _, _, _ in fixture.rootURL.appendingPathComponent("native-interview.json") }
                var pending: Task<AgentModeViewModel.UserTurnSubmissionResult, Never>?
                XCTAssertEqual(vm.submitUserTurn(text: draft, tabID: session.tabID, scheduledProviderSwitchSubmission: { pending = $0 }), .submitted)
                let admission = try XCTUnwrap(pending)
                let result = await admission.value
                XCTAssertEqual(result, .submitted)
                try await AsyncTestWait.waitUntil("native interview input reaches final transport seam") { dispatchedInitial != nil }
                let sent = try XCTUnwrap(dispatchedInitial)
                let prefix = payload + "\n\n"
                XCTAssertTrue(sent.hasPrefix(prefix))
                let admittedInput = String(sent.dropFirst(prefix.count))
                XCTAssertTrue(admittedInput.contains("<interview_first>"))
                XCTAssertEqual(admittedInput.components(separatedBy: "<computer_use_workflow>").count - 1, 1, "Native wrapping must not double-wrap Computer Use")
                XCTAssertGreaterThan(AgentProviderHandover.estimate("\n\n" + admittedInput), 2048)
                XCTAssertEqual(inputTokens, AgentProviderHandover.estimate("\n\n" + admittedInput), accuracy: 0.000001, "Preview must budget the actual ordinary/native admitted input, including Interview First")
                XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .sending)
                XCTAssertNil(session.codexController)
            }
        }

        func testPreviewBudgetsComposedWorkflowAndRefreshesWorkflowOnlyDrift() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                vm.storeDraftText(for: session.tabID, "tiny")
                let rawBudget = AgentProviderHandover.Budget(catalogWindow: nil, instructions: vm.providerSwitchInstructionStrings(session, destination: .openCode), composedInput: "tiny", isPreview: true)
                let historyBytes = Int((rawBudget.remainingCarrierTokens - 1000) * 4 / 1.05)
                XCTAssertGreaterThan(historyBytes, 0)
                session.appendItem(.assistant(String(repeating: "h", count: max(0, historyBytes)), sequenceIndex: session.nextSequenceIndex))
                let large = AgentWorkflowDefinition(customID: UUID(), displayName: "Large", template: String(repeating: "workflow ", count: 9000) + "$ARGUMENTS")
                session.selectedWorkflow = large
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                let full = try XCTUnwrap(preview.choices.first?.carrier)
                let budget = try XCTUnwrap(preview.budget)
                XCTAssertTrue(rawBudget.fits(full), "History is between raw-floor and composed-workflow allowances")
                XCTAssertFalse(budget.fits(full))
                XCTAssertGreaterThanOrEqual(budget.inputTokens, AgentProviderHandover.estimate(large.wrapUserText("tiny")))
                XCTAssertNotNil(preview.choices.first?.unavailable)
                XCTAssertNil(preview.selected)
                vm.cancelProviderSwitchPreview()
                let small = AgentWorkflowDefinition(customID: UUID(), displayName: "Small", template: "small $ARGUMENTS")
                session.selectedWorkflow = small
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(())
                    vm.test_afterProviderInputAugmentation = nil
                }
                vm.test_afterProviderInputAugmentation = { entered.finish(())
                    await release.value()
                }
                let build = Task { await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID) }
                await entered.value()
                let staleID = try XCTUnwrap(vm.providerSwitchPreview?.id)
                session.selectedWorkflow = large
                session.userWorkflowSelectionMutationGeneration &+= 1
                vm.test_afterProviderInputAugmentation = nil
                release.finish(())
                _ = await build.value
                try await AsyncTestWait.waitUntil("workflow-only drift refreshes the same chat") { vm.providerSwitchPreview?.id != staleID && vm.providerSwitchPreview?.building == false }
                let refreshed = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertTrue(refreshed.updated)
                XCTAssertEqual(refreshed.composition.workflow, large)
                XCTAssertEqual(refreshed.binding, preview.binding)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(refreshed.budget).inputTokens, AgentProviderHandover.estimate(large.wrapUserText("tiny")))
                XCTAssertEqual(session.draftText, "tiny")
                XCTAssertEqual(session.selectedWorkflow, large)
                XCTAssertNil(session.pendingHandoff.payload)
            }
        }

        func testSendComputerUseArmingDriftDuringAuthorizationRefusesBeforeAnyRow() async throws {
            for initiallyArmed in [false, true] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.selectedAgent = .codexExec
                    session.selectedModelRaw = "unknown-window"
                    try installSwitch(fixture)
                    session.pendingCodexComputerUseActivation = initiallyArmed ? .init(id: UUID(), createdAt: Date()) : nil
                    let endpoint = try XCTUnwrap(vm.agentSessionLinkObserverEndpoint(tabID: session.tabID))
                    let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: session.tabID, sessionID: endpoint.sessionID, tabName: "Target", isWindowClosing: false))
                    let request = AgentSessionLinkSendRequest(
                        linkID: UUID(),
                        linkGeneration: 1,
                        observerEndpoint: endpoint,
                        observerDisplayName: "Observer",
                        message: "ordinary request",
                        workflow: nil
                    )
                    let rows = session.items.map(\.id)
                    var starts = 0
                    var saves = 0
                    vm.test_providerSwitchStart = { _, _, _ in starts += 1 }
                    vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                        return fixture.rootURL.appendingPathComponent("no-write.json")
                    }
                    let outcome = await vm.agentSessionLinkPerformSend(
                        to: candidate,
                        request: request,
                        liveness: { .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false) },
                        commitAuthorization: {
                            session.pendingCodexComputerUseActivation = initiallyArmed ? nil : .init(id: UUID(), createdAt: Date())
                            return .committed
                        }
                    )
                    XCTAssertEqual(outcome, .blocked(.endpointPostReadiness))
                    XCTAssertEqual(session.items.map(\.id), rows)
                    XCTAssertEqual(starts, 0)
                    XCTAssertEqual(saves, 0)
                    XCTAssertEqual(session.pendingHandoff.providerSwitchDelivery, .ready)
                    XCTAssertNil(session.activeComposerSubmitAttempt)
                }
            }
        }

        func testDeferredUserSaveResumesAfterSameOwnerRetirementDrift() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                let sessionID = try XCTUnwrap(session.activeAgentSessionID)
                vm.test_setAgentSessionSaver { saved, workspace, _ in
                    try await AgentSessionDataService.shared.saveAgentSession(saved, for: workspace)
                }
                await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                let entered = AgentSessionLinkStopSignal<Void>()
                let release = AgentSessionLinkStopSignal<Void>()
                defer { release.finish(()) }
                vm.test_providerSwitchRetirement = { _ in entered.finish(())
                    await release.value()
                }
                let apply = Task { await vm.applyProviderSwitch(id) }
                await entered.value()
                vm.renameSession(tabID: session.tabID, to: "User title during retirement")
                let sourceAgent = session.selectedAgent
                let requestedGeneration = session.saveRequestGeneration
                let deferred = try XCTUnwrap(session.saveDebounceTask)
                await deferred.value // Exercise the actual scheduled save's mutation gate.
                session.appendItem(.user("later accepted input invalidates the captured history", sequenceIndex: session.nextSequenceIndex))
                release.finish(())
                let applied = await apply.value
                XCTAssertFalse(applied)
                XCTAssertNil(vm.providerSwitchMutation)
                XCTAssertGreaterThan(session.saveRequestGeneration, requestedGeneration, "An existing user save deferred by this mutation must be resumed, not dropped")
                await session.saveDebounceTask?.value
                let loaded = try await AgentSessionDataService.shared.loadAgentSession(id: sessionID, for: fixture.workspace)
                XCTAssertEqual(loaded?.name, "User title during retirement")
                XCTAssertNil(loaded?.pendingHandoffProviderSwitchDelivery)
                XCTAssertEqual(session.selectedAgent, sourceAgent)
            }
        }

        func testSwitchRetirementRechecksStopBindingAndExactOwnerWithoutOverwritingSuccessor() async throws {
            for drift in ["stop", "binding", "owner"] {
                try await withFixture { fixture in
                    let vm = fixture.viewModel
                    let session = fixture.sourceSession
                    session.providerSessionID = "old-native"
                    await vm.openProviderSwitchPreview(agent: .openCode, model: "destination", tabID: session.tabID)
                    let id = try XCTUnwrap(vm.providerSwitchPreview?.id)
                    let gate = AgentSessionLinkStopSignal<Void>()
                    defer { gate.finish(()) }
                    var retiring = false
                    var saves = 0
                    vm.test_providerSwitchRetirement = { _ in retiring = true
                        await gate.value()
                    }
                    vm.test_setAgentSessionSaver { _, _, _ in saves += 1
                        return fixture.rootURL.appendingPathComponent("unexpected.json")
                    }
                    let apply = Task { await vm.applyProviderSwitch(id) }
                    try await AsyncTestWait.waitUntil("outgoing retirement gate") { retiring }
                    let successor = AgentTabSession(tabID: session.tabID)
                    successor.selectedModelRaw = "successor-selection"
                    if drift == "stop" { session.stopState.invalidateScheduledStarts() }
                    else if drift == "binding" { session.testInstallPersistentSessionBinding(sessionID: UUID()) }
                    else { vm.test_replaceSessionForDeferredHydration(tabID: session.tabID, with: successor) }
                    gate.finish(())
                    let applied = await apply.value
                    XCTAssertFalse(applied)
                    XCTAssertEqual(saves, 0)
                    XCTAssertFalse(session.items.contains { $0.recoveryDiagnostic?.reason == "providerSwitch" })
                    XCTAssertNil(session.pendingHandoff.payload)
                    if drift == "owner" {
                        XCTAssertTrue(vm.sessions[session.tabID] === successor)
                        XCTAssertEqual(successor.selectedModelRaw, "successor-selection")
                    }
                }
            }
        }

        func testIdenticalNewestTurnsRowIsHiddenButPayloadAndSelectionStayValid() async throws {
            try await withFixture { fixture in
                let vm = fixture.viewModel
                let session = fixture.sourceSession
                try installSwitch(fixture)
                await vm.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: session.tabID)
                try await AsyncTestWait.waitUntil("short preview settled") { vm.providerSwitchPreview?.building == false }
                let preview = try XCTUnwrap(vm.providerSwitchPreview)
                XCTAssertEqual(preview.choices.count, 3)
                XCTAssertEqual(preview.choices.first(where: { $0.mode == .newestTurns })?.hidden, true)
                XCTAssertEqual(preview.selected, .history)
                let payload = await vm.providerSwitchPayload(preview.id, mode: .newestTurns)
                XCTAssertNotNil(payload)
            }
        }

        func testProviderSwitchScaleThreeHundredSavedChatsThreeWindowsTenLinks() async throws {
            let clock = ContinuousClock()
            let started = clock.now
            let reads = ProviderSwitchScaleReads()
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook { id in await reads.record(id) }
            var fixtures: [Fixture] = []
            do {
                for _ in 0 ..< 3 {
                    try await fixtures.append(makeFixture())
                }
                // Each real window fixture owns an explicit private catalog. Reinstall those
                // captured catalogs after construction notifications settle; this is not coverage
                // of the still-open #1422 new-window canonical-selection change.
                for fixture in fixtures {
                    fixture.window.workspaceManager.workspaces = [fixture.workspace]
                    fixture.window.workspaceManager.activeWorkspace = fixture.workspace
                }
                let first = fixtures[0]
                let manager = first.window.workspaceManager
                let workspaceID = try XCTUnwrap(manager.activeWorkspaceID)
                let workspaceIndex = try XCTUnwrap(manager.workspaces.firstIndex { $0.id == workspaceID })
                var preparedIDs: [UUID] = []
                var preparedTabs: [UUID] = []
                for index in 0 ..< 297 {
                    let id = UUID()
                    let tab = UUID()
                    let saved = AgentSession(
                        id: id,
                        workspaceID: workspaceID,
                        composeTabID: tab,
                        name: "Saved \(index)",
                        items: [
                            AgentChatItemPersist(from: .user("saved request \(index)", sequenceIndex: 0)),
                            AgentChatItemPersist(from: .assistant("retained reply \(index)", sequenceIndex: 1))
                        ],
                        parentSessionID: index < 7 ? first.sourceSession.activeAgentSessionID : nil,
                        createdByOverseerSessionID: index < 7 ? first.sourceSession.activeAgentSessionID : nil,
                        isMCPOriginated: index < 7
                    )
                    _ = try await AgentSessionDataService.shared.saveAgentSession(saved, for: manager.workspaces[workspaceIndex])
                    manager.workspaces[workspaceIndex].composeTabs.append(.init(id: tab, name: "Saved \(index)", activeAgentSessionID: id))
                    if index < 7 { preparedIDs.append(id)
                        preparedTabs.append(tab)
                    }
                }
                for (id, tab) in zip(preparedIDs, preparedTabs) {
                    let prepared = await first.viewModel.prepareSavedOversightSession(
                        tabID: tab,
                        sessionID: id,
                        workspaceID: workspaceID,
                        isStillAuthorized: { true }
                    )
                    XCTAssertTrue(prepared)
                }
                // An agreeing recovered catalog replica does not become a second payload writer.
                fixtures[2].window.workspaceManager.workspaces.append(manager.workspaces[workspaceIndex])
                let sourceID = try XCTUnwrap(first.sourceSession.activeAgentSessionID)
                let replica = AgentSessionCarrierResolver.capture(windows: fixtures.map(\.window), sessionIDs: [sourceID], includeRuntimeOwners: true)
                XCTAssertFalse(replica.ambiguousSessionIDs.contains(sourceID))
                XCTAssertTrue(replica.uniqueRuntimeOwners[sourceID]?.session === first.sourceSession)
                let host = WindowStatesManager.shared
                let authority = DomainAgentSessionLinkAuthority(identity: .init(runtimeID: UUID(), lifecycleGeneration: 1, processID: 1, mode: .app, createdAt: Date()))
                let bridge = AgentSessionLinkRuntimeBridge(authority: authority, host: host, toolAdvertisementInvalidator: { _ in })
                bridge.attach(host: host)
                defer { bridge.freezeForTermination()
                    AgentSessionLinkRuntimeBridge.shared.attach(host: host)
                }
                let nodes = fixtures.map { ($0.viewModel, $0.sourceSession) }
                    + preparedTabs.compactMap { tab in first.viewModel.sessions[tab].map { (first.viewModel, $0) } }
                XCTAssertEqual(nodes.count, 10)
                for node in nodes.prefix(2) {
                    let endpoint = try XCTUnwrap(node.0.agentSessionLinkObserverEndpoint(tabID: node.1.tabID))
                    let activation = await bridge.becomeOverseer(endpoint: endpoint, isEnabled: { true }, revalidateRoute: { true }, commitIfCurrent: { $0() })
                    XCTAssertNotNil(activation)
                }
                for target in nodes.dropFirst() {
                    let result = try await bridge.addMonitorLink(
                        observerSessionID: sourceID,
                        rawTargetSessionID: XCTUnwrap(target.1.activeAgentSessionID).uuidString
                    )
                    guard case .added = result else { XCTFail("Expected direct grant, got \(result)")
                        throw CancellationError()
                    }
                }
                let reverse = try await bridge.addMonitorLink(observerSessionID: XCTUnwrap(nodes[1].1.activeAgentSessionID), rawTargetSessionID: sourceID.uuidString)
                guard case .added = reverse else { XCTFail("Expected independent reverse grant")
                    throw CancellationError()
                }
                let grants = await authority.links(forObserver: sourceID)
                let reverseGrants = try await authority.links(forObserver: XCTUnwrap(nodes[1].1.activeAgentSessionID))
                XCTAssertEqual(grants.items.count + reverseGrants.items.count, 10)
                let endpoints = nodes.map { $0.0.agentSessionLinkObserverEndpoint(tabID: $0.1.tabID) }
                let parents = nodes.map(\.1.parentSessionID)
                let worktrees = nodes.map(\.1.worktreeBindings)
                let activations = nodes.prefix(2).map(\.1.oversight.overseerActivation)
                var providerCalls = 0
                for fixture in fixtures {
                    fixture.viewModel.test_providerSwitchStart = { _, _, _ in providerCalls += 1 }
                }
                let target = nodes[3]
                for node in [nodes[0], target] {
                    await node.0.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: node.1.tabID)
                    let id = try XCTUnwrap(node.0.providerSwitchPreview?.id)
                    let applied = await node.0.applyProviderSwitch(id)
                    XCTAssertTrue(applied)
                }
                // Simulate the durable possible-write fault, then restore through the ordinary exact
                // saved-session loader, not a preview/seed ledger or a provider probe.
                target.1.pendingHandoff.providerSwitchDelivery = .sending
                target.1.appendItem(.user("uncertain input", sequenceIndex: target.1.nextSequenceIndex))
                target.1.isDirty = true
                let persisted = await target.0.flushSaveRequired(for: target.1.tabID, workspaceID: workspaceID)
                guard case .success = persisted else { XCTFail("Uncertainty fixture must be durable")
                    throw CancellationError()
                }
                target.1.hasLoadedPersistedState = false
                let restored = await target.0.ensureSessionReady(tabID: target.1.tabID, reconnectActiveProviders: false)
                XCTAssertTrue(restored === target.1)
                guard case .failure(.providerSwitchUnconfirmed) = await target.0.providerSwitchSendAdmission(session: restored, input: "not replayed") else { XCTFail("Restore must block every new input")
                    throw CancellationError()
                }
                await target.0.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: restored.tabID)
                let orphan = restored.pendingHandoff
                target.0.cancelProviderSwitchPreview()
                XCTAssertEqual(restored.pendingHandoff, orphan)
                await target.0.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: restored.tabID)
                target.0.providerSwitchPreview?.selected = .history
                let reviewed = try await target.0.applyProviderSwitch(XCTUnwrap(target.0.providerSwitchPreview?.id))
                XCTAssertTrue(reviewed)
                XCTAssertTrue(restored.pendingHandoff.payload?.contains("uncertain input") == true)
                guard case .success(.some) = await target.0.providerSwitchSendAdmission(session: restored, input: "new ordinary input") else { XCTFail("Reviewed carrier should admit new input")
                    throw CancellationError()
                }
                await first.viewModel.openProviderSwitchPreview(agent: .openCode, model: "unknown-window", tabID: first.sourceTabID)
                let discarded = try await first.viewModel.applyProviderSwitch(XCTUnwrap(first.viewModel.providerSwitchPreview?.id), discard: true)
                XCTAssertTrue(discarded)
                XCTAssertEqual(nodes.map { $0.0.agentSessionLinkObserverEndpoint(tabID: $0.1.tabID) }, endpoints)
                XCTAssertEqual(nodes.map(\.1.parentSessionID), parents)
                XCTAssertEqual(nodes.map(\.1.worktreeBindings), worktrees)
                XCTAssertEqual(nodes.prefix(2).map(\.1.oversight.overseerActivation), activations)
                let after = await authority.links(forObserver: sourceID)
                let afterReverse = try await authority.links(forObserver: XCTUnwrap(nodes[1].1.activeAgentSessionID))
                XCTAssertEqual(after.items.map(\.linkID), grants.items.map(\.linkID))
                XCTAssertEqual(after.items.map(\.generation), grants.items.map(\.generation))
                XCTAssertEqual(afterReverse.items.map(\.linkID), reverseGrants.items.map(\.linkID))
                let expectedReadIDs = Set(nodes.compactMap(\.1.activeAgentSessionID))
                let pointReads = await reads.snapshot()
                XCTAssertTrue(Set(pointReads).isSubset(of: expectedReadIDs), "No unrelated saved transcript may hydrate")
                XCTAssertEqual(Set(pointReads), expectedReadIDs)
                XCTAssertEqual(providerCalls, 0)
                XCTAssertTrue(nodes.allSatisfy { $0.1.agentTask == nil && $0.1.codexController == nil && $0.1.claudeController == nil && $0.1.acpController == nil })
                XCTAssertEqual(first.viewModel.sessions.values.count(where: { $0.hasLoadedPersistedState && $0.activeAgentSessionID != nil }), 8)
                let elapsed = started.duration(to: clock.now)
                print("PROVIDER_SWITCH_SCALE saved=300 windows=3 links=10 prepared=7 pointReads=\(pointReads.count) providerCalls=\(providerCalls) elapsed=\(elapsed)")
                XCTAssertLessThan(elapsed, .seconds(10))
            } catch {
                await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
                for fixture in fixtures.reversed() {
                    await cleanup(fixture)
                }
                throw error
            }
            await AgentSessionDataService.shared.test_setAfterHydrationPrepareHook(nil)
            for fixture in fixtures.reversed() {
                await cleanup(fixture)
            }
        }

        private func summaryMonitorContext(_ fixture: Fixture) throws -> (DomainAgentSessionLinkEndpointIdentity, AgentSessionLinkPassiveStatusNotices.Sample) {
            let endpoint = try XCTUnwrap(fixture.viewModel.agentSessionLinkObserverEndpoint(tabID: fixture.sourceTabID))
            let target = DomainAgentSessionLinkEndpointIdentity(windowID: 99, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1)
            let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
            fixture.viewModel.agentSessionLinkPublishPromptInventory(.init(
                observerSessionID: endpoint.sessionID, linkSetRevision: 1,
                items: [.init(targetSessionID: target.sessionID, displayName: "Summary lane", capabilityNames: ["poll", "read"], reference: reference)]
            ), to: endpoint)
            return (endpoint, .init(reference: reference, targetEndpoint: target, targetSessionID: target.sessionID, displayName: "Summary lane", status: .running))
        }

        private func publishSwitchWake(_ fixture: Fixture, endpoint: DomainAgentSessionLinkEndpointIdentity) throws {
            let session = fixture.sourceSession
            let runID = try XCTUnwrap(session.runID)
            fixture.viewModel.agentSessionLinkPublishRunCatalogProjection(.init(
                runID: runID, routeToken: .init(runID: runID, observerEndpoint: endpoint, connectionID: UUID(), routingAuthorityGeneration: 1, connectionLifecycleGeneration: 1),
                projectionRevision: 1, hasAgentSessionLink: true, hasAnyActiveLink: true
            ), to: endpoint)
            let target = DomainAgentSessionLinkEndpointIdentity(windowID: 99, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1)
            let reference = DomainAgentSessionLinkReference(linkID: UUID(), generation: 1)
            fixture.viewModel.agentSessionLinkPublishPromptInventory(.init(
                observerSessionID: endpoint.sessionID, linkSetRevision: 1,
                items: [.init(targetSessionID: target.sessionID, displayName: "Lane", capabilityNames: ["poll", "read", "send_when_idle", "wait"], reference: reference)]
            ), to: endpoint)
            session.oversight.autoWakeOnUpdates = true
            fixture.viewModel.agentSessionLinkPublishPassiveStatusNotices(.init(
                observerEndpoint: endpoint, queueEpoch: UUID(), queueRevision: 1, linkSetRevision: 1,
                isEnabled: true, isDeliverable: true,
                entries: [.init(reference: reference, targetEndpoint: target, targetSessionID: target.sessionID, displayName: "Lane", fromStatus: .running, toStatus: .idle, observedAt: Date(), idleForSend: true, latestVisibleAssistantPreview: "Done.", changeSequence: 1, edgeSequence: 1)],
                unacknowledgedOverflowCount: 0, overflowProduced: 0,
                autoWakeLanes: [.init(reference: reference, targetEndpoint: target, targetSessionID: target.sessionID, isEffectivelySelected: true)]
            ), to: endpoint)
        }

        private func composerClaim(_ fixture: Fixture, text: String) throws -> AgentModeViewModel.AgentComposerSubmitClaim {
            let target = try XCTUnwrap(fixture.viewModel.makeComposerSubmitTarget(tabID: fixture.sourceTabID, session: fixture.sourceSession))
            let attempt = AgentComposerSubmitAttempt(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: text)
            guard case let .claimed(claim) = fixture.viewModel.claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else { throw CancellationError() }
            return claim
        }

        private func switchCarrier(padding: Int = 0) throws -> String {
            let request = AgentChatItem.user(String(repeating: "h", count: max(0, padding)), sequenceIndex: 0)
            let turn = AgentTranscriptTurn(request: .init(from: request), responseSpans: [], conclusionActivityID: nil, terminalState: .completed, startedAt: request.timestamp, completedAt: request.timestamp)
            let projection = try AgentProviderHandover.project(AgentTranscript(turns: [turn]))
            let source = try AgentProviderHandover.Source(provider: "source", model: "source-model")
            return AgentProviderHandover.render(AgentProviderHandover.history(projection, source: source, historyReference: nil))
        }

        private func installSwitch(_ fixture: Fixture, padding: Int = 0) throws {
            // Fixture-local availability only: never call a connect/login/provider API or write defaults.
            fixture.window.promptManager.apiSettingsViewModel?.isOpenCodeConnected = true
            XCTAssertTrue(fixture.viewModel.agentAvailabilityContext.openCodeAvailable)
            fixture.sourceSession.pendingHandoff = try .init(payload: switchCarrier(padding: padding), createdAt: Date(), sourceItemID: fixture.sourceSession.items.last?.id, providerSwitchDelivery: .ready)
        }

        private func switchPreparation(_ fixture: Fixture) async throws -> AgentModeViewModel.ProviderSwitchSendPreparation {
            let outcome = await fixture.viewModel.providerSwitchSendAdmission(session: fixture.sourceSession, input: "ordinary input")
            guard case let .success(preparation) = outcome else { throw CancellationError() }
            return try XCTUnwrap(preparation)
        }
    #endif

    private func withFixture(computerUseReady: Bool = false, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture(computerUseReady: computerUseReady)
        do {
            try await body(fixture)
        } catch {
            await cleanup(fixture)
            throw error
        }
        await cleanup(fixture)
    }

    private func makeFixture(computerUseReady: Bool = false, pickerProviderConstruction: (() -> Void)? = nil) async throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionLinkHandoffInheritanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let previousAutoStart = pickerProviderConstruction == nil ? GlobalSettingsStore.shared.mcpAutoStart() : nil
        if previousAutoStart != nil { GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false) }
        let window: WindowState
        #if DEBUG
            if computerUseReady || pickerProviderConstruction != nil {
                window = WindowState(agentModeViewModelFactory: { windowID, prompt, manager, server in
                    let claudeFactory: ClaudeAgentModeCoordinator.ClaudeControllerFactory? = pickerProviderConstruction == nil ? nil : { _, _, _, _ in
                        pickerProviderConstruction?()
                        preconditionFailure("Picker must never construct a native provider")
                    }
                    let vm = AgentModeViewModel(
                        testWindowID: windowID,
                        codexControllerFactory: { _, _, _, _, _, _ in
                            pickerProviderConstruction?()
                            preconditionFailure("Fixture must stop before provider transport")
                        },
                        claudeControllerFactory: claudeFactory,
                        testMCPServer: server,
                        testWorkspaceFileContextStore: prompt.workspaceFileContextStore,
                        testCodexComputerUseCompanionReady: { true }, testCodexComputerUseReservedEntryExists: { false }
                    )
                    vm.promptManager = prompt
                    vm.workspaceManager = manager
                    return vm
                }, contextBuilderProviderFactory: { _, _, _, _ in preconditionFailure("Parity fixture never runs Context Builder") })
            } else { window = WindowState() }
        #else
            window = WindowState()
        #endif
        WindowStatesManager.shared.registerWindowState(window)
        if let previousAutoStart { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        await window.workspaceManager.awaitInitialized()

        let defaultsDomain = "ProviderSwitchTests.\(UUID())"
        do {
            let workspace = window.workspaceManager.createWorkspace(
                name: "Handoff inheritance \(UUID().uuidString.prefix(8))",
                repoPaths: [rootURL.path],
                ephemeral: true
            )
            await window.workspaceManager.switchWorkspace(
                to: workspace,
                saveState: false,
                reason: "agentSessionLinkHandoffInheritanceTests"
            )

            let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceTab = ComposeTabState(
                id: sourceTabID,
                name: "Source",
                activeAgentSessionID: sourceSessionID
            )
            let workspaceIndex = try XCTUnwrap(
                window.workspaceManager.workspaces.firstIndex(where: { $0.id == activeWorkspace.id })
            )
            window.workspaceManager.workspaces[workspaceIndex].customStoragePath = rootURL.appendingPathComponent("sessions", isDirectory: true)
            let persistedSource = AgentSession(
                id: sourceSessionID,
                workspaceID: activeWorkspace.id,
                composeTabID: sourceTabID,
                name: "Source",
                items: [
                    AgentChatItemPersist(from: .user("Source user", sequenceIndex: 0)),
                    AgentChatItemPersist(from: .assistant("Source assistant", sequenceIndex: 1))
                ],
                autoEditEnabled: false
            )
            _ = try await AgentSessionDataService.shared.saveAgentSession(
                persistedSource, for: window.workspaceManager.workspaces[workspaceIndex]
            )
            window.workspaceManager.workspaces[workspaceIndex].composeTabs = [sourceTab]
            window.workspaceManager.workspaces[workspaceIndex].activeComposeTabID = sourceTabID
            window.promptManager.loadComposeTabsFromWorkspace(
                window.workspaceManager.workspaces[workspaceIndex],
                syncPromptText: true
            )

            let viewModel = window.agentModeViewModel
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsDomain))
            let settings = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: rootURL.appendingPathComponent("settings.json")))
            settings.setAutoEffortEnabled(false)
            settings.setUsageBalancingEnabled(false)
            viewModel.modelRouterSettingsStore = settings
            let sourceSession = await viewModel.ensureSessionReady(tabID: sourceTabID)
            XCTAssertEqual(sourceSession.activeAgentSessionID, sourceSessionID)
            XCTAssertEqual(
                window.workspaceManager.activeAgentSessionID(forTabID: sourceTabID),
                sourceSessionID
            )
            let sourceToken = try XCTUnwrap(
                sourceSession.permitsBoundOperationAndSave ? sourceSession.currentRestorationBindingToken : nil,
                "Handoff requires a restored source payload."
            )
            XCTAssertEqual(sourceSession.qualifiedRestorationReadiness, .authoritative(sourceToken, .persistedPayloadApplied))
            XCTAssertEqual(sourceSession.items.count, 2)
            viewModel.setAgentModeActive(true)

            return Fixture(
                window: window,
                rootURL: rootURL,
                defaultsDomain: defaultsDomain,
                viewModel: viewModel,
                sourceTabID: sourceTabID,
                sourceSession: sourceSession,
                workspace: window.workspaceManager.workspaces[workspaceIndex]
            )
        } catch {
            UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
            window.beginClose()
            await window.tearDown()
            WindowStatesManager.shared.unregisterWindowState(window)
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    private func cleanup(_ fixture: Fixture) async {
        UserDefaults.standard.removePersistentDomain(forName: fixture.defaultsDomain)
        fixture.window.beginClose()
        await fixture.window.tearDown()
        WindowStatesManager.shared.unregisterWindowState(fixture.window)
        try? FileManager.default.removeItem(at: fixture.rootURL)
    }

    private actor ProviderSwitchScaleReads {
        private var ids: [UUID] = []
        func record(_ id: UUID) {
            ids.append(id)
        }

        func snapshot() -> [UUID] {
            ids
        }
    }

    private struct Fixture {
        let window: WindowState
        let rootURL: URL
        let defaultsDomain: String
        let viewModel: AgentModeViewModel
        let sourceTabID: UUID
        let sourceSession: AgentModeViewModel.TabSession
        let workspace: WorkspaceModel
    }
}

/// Minimal runtime for the B2 late-transfer-write regression: tears down immediately and
/// reports a fixed session ref, so the transfer completion path is exercised without a provider.
private actor LateTransferFakeRuntime: NativeAgentRuntimeControlling {
    let sessionRefID: String
    var hasActiveSession = false
    var hasTurnInFlight = false
    var holdTeardown = false

    init(sessionRefID: String = "late-claude-ref") {
        self.sessionRefID = sessionRefID
    }

    private var teardownStarted = false
    private var teardownStartedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    var events: AsyncStream<NativeAgentRuntimeEvent> {
        AsyncStream { $0.finish() }
    }

    func availableSlashCommands() async -> [NativeAgentRuntimeSlashCommand] {
        []
    }

    func ensureEventsStreamReady() {}
    func resetEventsStreamForNewRun() {}
    func currentSessionRef() async -> NativeAgentRuntimeSessionRef {
        teardownStarted = true
        teardownStartedContinuation?.resume()
        if holdTeardown {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
        return .init(sessionID: sessionRefID)
    }

    func setHoldTeardown(_ value: Bool) {
        holdTeardown = value
    }

    func waitUntilTeardownStarted() async {
        if teardownStarted { return }
        await withCheckedContinuation { teardownStartedContinuation = $0 }
    }

    func releaseTeardown() {
        holdTeardown = false
        releaseContinuation?.resume()
    }

    func applyModelAndEffort(model: String?, effortLevel: NativeAgentRuntimeEffortLevel?) {}
    func shutdown() {}
    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) {}
    func startOrResume(existingSessionID: String?, model: String?, effortLevel: NativeAgentRuntimeEffortLevel?, systemPromptOverride: String?) -> NativeAgentRuntimeSessionRef {
        .init(sessionID: sessionRefID)
    }

    func sendUserMessage(_ text: String) -> UUID {
        UUID()
    }

    func interruptTurn(reason: String) -> NativeAgentRuntimeInterruptOutcome {
        .noTurnInFlight
    }
}
