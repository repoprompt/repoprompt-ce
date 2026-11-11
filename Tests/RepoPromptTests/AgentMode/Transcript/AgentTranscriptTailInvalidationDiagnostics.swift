#if DEBUG
    import AppKit
    import Combine
    import Darwin
    @testable import RepoPromptApp
    import RepoPromptSettingsCore
    import SwiftUI
    import XCTest

    /// Opt-in production-host diagnostic, not a latency assertion or a replacement transcript view.
    @MainActor
    final class AgentTranscriptTailInvalidationDiagnostics: XCTestCase {
        @MainActor
        private final class NativeWitness {
            weak var view: CodeBlockTextView?
            let rowID: UUID
            init(_ view: CodeBlockTextView, rowID: UUID) {
                self.view = view
                self.rowID = rowID
            }
        }

        @MainActor
        private final class Recorder {
            var blocks: [String: Int] = [:]
            var bodies: [UUID: Int] = [:]
            var latestBody: [UUID: String] = [:]
            var footers: [UUID: String] = [:]
            var natives: [ObjectIdentifier: NativeWitness] = [:]
            var counts: [UUID: [String: Int]] = [:]
            var serial = 0

            func receive(_ event: AgentTranscriptTailRenderProbe.Event) {
                switch event {
                case let .block(id): blocks[id, default: 0] += 1
                case let .body(id, text):
                    bodies[id, default: 0] += 1
                    latestBody[id] = text
                case let .footer(id?, text):
                    footers[id] = text
                case .footer(nil, _): return
                case let .native(boundary, scope, view):
                    let key = ObjectIdentifier(view)
                    if let scope, natives[key]?.view !== view {
                        natives[key] = NativeWitness(view, rowID: scope)
                    }
                    guard let witness = natives[key], witness.view === view else { return }
                    counts[witness.rowID, default: [:]][boundary.rawValue, default: 0] += 1
                }
                serial += 1
            }

            func attached(_ id: UUID, window: NSWindow) -> [CodeBlockTextView] {
                natives.values.compactMap { $0.rowID == id && $0.view?.window === window ? $0.view : nil }
            }
        }

        private final class CountingHost: NSHostingView<AnyView> {
            var layouts = 0
            override func layout() {
                layouts += 1
                super.layout()
            }
        }

        @MainActor
        private struct Fixture {
            let state: WindowState
            let tabID: UUID
            let host: CountingHost
            let window: NSWindow
            let source: [AgentChatItem]
            let recorder: Recorder
            var store: AgentTranscriptUIStore {
                state.agentModeViewModel.ui.transcript
            }
        }

        private enum Refused: Error { case providerLaunch }

        private var ownedStates: [WindowState] = []

        override func tearDown() async throws {
            AgentTranscriptTailRenderProbe.sink = nil
            for state in ownedStates {
                await state.tearDown()
            }
            ownedStates = []
            try await super.tearDown()
        }

        private struct GateFailure: Error, CustomStringConvertible {
            let description: String
        }

        func testRowBoundaryKeepsNativeIdentitySelectionAndDeliversChangedInputs() async throws {
            let oldAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(oldAutoStart, commit: false)
                AgentTranscriptTailRenderProbe.sink = nil
            }
            let recorder = Recorder()
            AgentTranscriptTailRenderProbe.sink = { recorder.receive($0) }
            let fixture = try await makeFixture(turns: 10, recorder: recorder)
            defer { fixture.window.contentView = nil
                fixture.window.close()
            }
            let userID = fixture.source[45].id
            let openerID = fixture.source[46].id
            let tailID = fixture.source[49].id
            try await wait(fixture, seconds: 60, gate: "selection witness") { self.hasRichWitness(userID, in: fixture) }
            try await calibrateNativeUpdate(fixture, rowID: userID)
            var warmTail = try XCTUnwrap(fixture.store.snapshot.presentation.visibleRows.first { $0.id == tailID })
            warmTail.text += " SELECTION_WARMUP"
            var warm = replacing(warmTail, in: fixture.store.snapshot)
            warm.runtimeFooterByItemID[tailID] = .init(itemID: tailID, anchorDate: warmTail.timestamp, completedDate: nil, statusText: "Warm-up status")
            fixture.store.update(warm)
            try await wait(fixture, seconds: 5, gate: "selection tail warm-up") {
                recorder.footers[tailID] == "Warm-up status" && recorder.attached(tailID, window: fixture.window).contains { $0.string.contains("SELECTION_WARMUP") }
            }
            var lastSerial = recorder.serial
            var quietSince = ProcessInfo.processInfo.systemUptime
            try await wait(fixture, seconds: 5, gate: "selection setup quiet window") {
                if lastSerial != recorder.serial {
                    lastSerial = recorder.serial
                    quietSince = ProcessInfo.processInfo.systemUptime
                }
                return ProcessInfo.processInfo.systemUptime - quietSince >= 0.22
            }
            let view = try XCTUnwrap(recorder.attached(userID, window: fixture.window).first)
            let selection = NSRange(location: 8, length: 12)
            view.setSelectedRange(selection)
            let originalStorage = view.attributedString()
            var tail = try XCTUnwrap(fixture.store.snapshot.presentation.visibleRows.first { $0.id == tailID })
            tail.text += " SELECTION_TAIL"
            var next = replacing(tail, in: fixture.store.snapshot)
            next.runtimeFooterByItemID[tailID] = .init(itemID: tailID, anchorDate: tail.timestamp, completedDate: nil, statusText: "Selection status")
            recorder.bodies = [:]
            recorder.counts = [:]
            fixture.store.update(next)
            try await wait(fixture, seconds: 5, gate: "tail text and status") {
                recorder.footers[tailID] == "Selection status" && recorder.attached(tailID, window: fixture.window).contains { $0.string.contains("SELECTION_TAIL") }
            }
            XCTAssertTrue(recorder.attached(userID, window: fixture.window).contains { $0 === view })
            XCTAssertEqual(view.selectedRange(), selection)
            XCTAssertTrue(view.attributedString().isEqual(to: originalStorage))
            XCTAssertTrue(recorder.bodies.allSatisfy { $0.key == tailID || $0.value == 0 }, "Non-tail calls: \(recorder.bodies.filter { $0.key != tailID })")
            XCTAssertEqual(recorder.counts[userID]?["update", default: 0] ?? 0, 0)
            var user = try XCTUnwrap(next.presentation.visibleRows.first { $0.id == userID })
            user.text += " CHANGED_USER_INPUT"
            next = replacing(user, in: next)
            fixture.store.update(next)
            try await wait(fixture, seconds: 5, gate: "changed stable user input") {
                recorder.attached(userID, window: fixture.window).contains { $0.string.contains("CHANGED_USER_INPUT") }
            }
            XCTAssertGreaterThan(recorder.bodies[userID, default: 0], 0)
            next.presentationRevision += 1
            next.runtimeFooterByItemID[openerID] = .init(itemID: openerID, anchorDate: user.timestamp, completedDate: nil, statusText: "Changed stable footer")
            fixture.store.update(next)
            try await wait(fixture, seconds: 5, gate: "changed stable footer") { recorder.footers[openerID] == "Changed stable footer" }
            XCTAssertGreaterThan(recorder.bodies[openerID, default: 0], 0)
        }

        func testRowBoundaryAccountsForPayloadActionsAndOpaqueLoginCallbacks() async throws {
            let oldAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(oldAutoStart, commit: false) }
            let fixture = try await makeFixture(turns: 10, recorder: Recorder())
            defer { fixture.window.contentView = nil
                fixture.window.close()
            }
            let vm = fixture.state.agentModeViewModel
            func row(item: AgentChatItem, run: AgentRunInteractionUISnapshot, payload: String? = nil, revision: Int = 0) -> AgentTranscriptRow {
                AgentTranscriptRow(
                    inputs: .init(
                        item: item, isMostRecentEditBubble: false, windowID: fixture.state.windowID,
                        workspaceID: fixture.state.workspaceManager.activeWorkspaceID, tabID: fixture.tabID,
                        suppressAskUserTranscriptUI: false, activeContextBuilderCallID: nil, activeContextBuilderResultID: nil,
                        rawToolResultPayload: payload, rawToolResultPayloadRenderRevision: revision, cancelRunID: run.activeRunID,
                        runInteraction: run, runtimeFooter: nil, autoExpandEnabled: true,
                        liveBashExecution: nil, isRecentAssistant: false, approvalVisible: false
                    ),
                    agentModeVM: vm,
                    promptManager: fixture.state.promptManager,
                    contextBuilderAgentVM: fixture.state.contextBuilderAgentViewModel,
                    codexManagedLoginAction: nil
                )
            }
            let item = fixture.source[0]
            let run = vm.ui.runInteraction.snapshot
            let original = row(item: item, run: run)
            XCTAssertEqual(original, row(item: item, run: run))
            XCTAssertNotEqual(original, row(item: item, run: run, payload: "new raw result", revision: 1))
            XCTAssertNotEqual(original, row(item: fixture.source[5], run: run))
            var changedRun = run
            changedRun.selectedModelRaw = "changed-model"
            XCTAssertNotEqual(original, row(item: item, run: changedRun))
            XCTAssertEqual(row(item: item, run: changedRun).handoffConfig.defaultModelRaw, "changed-model")
            let config = original.handoffConfig
            XCTAssertEqual(config.itemID, item.id)
            XCTAssertEqual(config.windowID, fixture.state.windowID)
            let payload = await config.buildPayloadForClipboard()
            XCTAssertTrue(payload.contains("Turn 0 rich request"))
            XCTAssertFalse(payload.contains("Turn 1 rich request"), "The handoff callback must retain the exact row cutoff")
            let opaque = AgentTranscriptRow(
                inputs: original.inputs,
                agentModeVM: vm,
                promptManager: fixture.state.promptManager,
                contextBuilderAgentVM: fixture.state.contextBuilderAgentViewModel,
                codexManagedLoginAction: .init(ownerID: ObjectIdentifier(vm), browser: { _ in throw Refused.providerLaunch }, deviceCode: { _ in throw Refused.providerLaunch })
            )
            XCTAssertEqual(opaque, opaque, "Action identity must be reflexive")
            var callbackInvocations = 0
            let newAction = CodexManagedLoginAction(
                ownerID: ObjectIdentifier(vm),
                revision: 1,
                browser: { _ in callbackInvocations += 1
                    return true
                },
                deviceCode: { _ in false }
            )
            let replaced = AgentTranscriptRow(
                inputs: original.inputs,
                agentModeVM: vm,
                promptManager: fixture.state.promptManager,
                contextBuilderAgentVM: fixture.state.contextBuilderAgentViewModel,
                codexManagedLoginAction: newAction
            )
            XCTAssertNotEqual(opaque, replaced)
            let authenticated = try await XCTUnwrap(replaced.codexManagedLoginAction).browser { _ in }
            XCTAssertTrue(authenticated)
            XCTAssertEqual(callbackInvocations, 1)
        }

        func testRowBoundaryIsolatesSettledErrorsAndUnrelatedBashUpdates() async throws {
            let oldAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            defer { GlobalSettingsStore.shared.setMCPAutoStart(oldAutoStart, commit: false)
                AgentTranscriptTailRenderProbe.sink = nil
            }
            let recorder = Recorder()
            AgentTranscriptTailRenderProbe.sink = { recorder.receive($0) }
            let fixture = try await makeFixture(turns: 10, recorder: recorder)
            defer { fixture.window.contentView = nil
                fixture.window.close()
            }
            let userID = fixture.source[45].id
            let tailID = fixture.source[49].id
            let ordinaryID = fixture.source[41].id
            let loginID = fixture.source[42].id
            let bashID = fixture.source[43].id
            try await wait(fixture, seconds: 60, gate: "rich native witness") { self.hasRichWitness(userID, in: fixture) }
            var next = fixture.store.snapshot
            for (id, message) in [(ordinaryID, "Ordinary settled error"), (loginID, CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)] {
                var item = try XCTUnwrap(next.presentation.visibleRows.first { $0.id == id })
                item.kind = .error
                item.text = message
                next = replacing(item, in: next)
            }
            var bash = try XCTUnwrap(next.presentation.visibleRows.first { $0.id == bashID })
            bash.toolName = "bash"
            bash.toolArgsJSON = "{}"
            bash.toolResultJSON = "{\"output\":\"initial\",\"isRunning\":true}"
            next = replacing(bash, in: next)
            fixture.store.update(next)
            try await wait(fixture, seconds: 5, gate: "settled error and bash bodies") {
                recorder.latestBody[ordinaryID] == "Ordinary settled error" && recorder.latestBody[loginID] == CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage && recorder.bodies[bashID, default: 0] > 0
            }
            // A properly bound delayed save must not allocate another identity or replace
            // settled presentation rows. Exercise the same debounce path that exposed the
            // old duplicate-identity fixture, rather than relying on its scheduling timing.
            let vm = fixture.state.agentModeViewModel
            let session = vm.session(for: fixture.tabID)
            let binding = try XCTUnwrap(session.currentRestorationBindingToken)
            let beforeSave = fixture.store.snapshot
            session.isDirty = true
            vm.persistenceRuntime.scheduleSave(for: session)
            let save = try XCTUnwrap(session.saveDebounceTask)
            await save.value
            XCTAssertFalse(session.isDirty, "The scheduled save must actually complete")
            XCTAssertEqual(session.currentRestorationBindingToken, binding)
            XCTAssertEqual(fixture.store.snapshot, beforeSave, "Saving an existing binding must not republish settled rows")
            var serial = recorder.serial
            var quietSince = ProcessInfo.processInfo.systemUptime
            try await wait(fixture, seconds: 5, gate: "error fixture quiet window") {
                if serial != recorder.serial { serial = recorder.serial
                    quietSince = ProcessInfo.processInfo.systemUptime
                }
                return ProcessInfo.processInfo.systemUptime - quietSince >= 0.22
            }
            var tail = try XCTUnwrap(next.presentation.visibleRows.first { $0.id == tailID })
            tail.text += " BASH_AND_ERROR_TAIL"
            next = replacing(tail, in: next)
            next.activeBashLiveExecutionByItemID[bashID] = .init(
                executionKey: "synthetic-bash",
                transcriptItemID: bashID,
                toolName: "bash",
                invocationID: bash.toolInvocationID,
                fallbackSignature: "synthetic",
                processID: nil,
                command: "printf synthetic",
                statusWord: "running",
                exitCode: nil,
                output: "updated output",
                isSummaryOnly: false,
                lastSignalAt: tail.timestamp
            )
            recorder.bodies = [:]
            recorder.counts = [:]
            fixture.store.update(next)
            try await wait(fixture, seconds: 5, gate: "tail and Bash refresh") {
                recorder.latestBody[tailID]?.hasSuffix("BASH_AND_ERROR_TAIL") == true && recorder.bodies[bashID, default: 0] > 0
            }
            XCTAssertEqual(recorder.bodies[ordinaryID, default: 0], 0)
            XCTAssertEqual(recorder.bodies[loginID, default: 0], 0)
            XCTAssertEqual(recorder.bodies[userID, default: 0], 0)
            XCTAssertEqual(recorder.counts[userID]?["update", default: 0] ?? 0, 0)

            // Exercise the normal source mutation, coalescer and VM publication path too.
            vm.streamRuntime.enqueueAssistantDelta(" NORMAL_VM_DELTA", session: session)
            vm.streamRuntime.flushPendingAssistantDelta(session)
            try await wait(fixture, seconds: 5, gate: "normal VM delta reaches attached native storage") {
                recorder.attached(tailID, window: fixture.window).contains { $0.string.contains("NORMAL_VM_DELTA") }
            }
            XCTAssertTrue(session.items.last?.text.hasSuffix("NORMAL_VM_DELTA") == true)
        }

        private enum Workload: String {
            case richConclusion, shortNarration
            var projectedStreaming: Bool {
                self == .shortNarration
            }
        }

        func testStreamingTailInvalidationAcrossSessionSizes() async throws {
            try await measureWorkload(.richConclusion)
        }

        func testStreamingShortNarrationInvalidationAcrossSessionSizes() async throws {
            try await measureWorkload(.shortNarration)
        }

        private func measureWorkload(_ workload: Workload) async throws {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["RPCE_RUN_SCALE_TESTS"] == "1", "Opt-in transcript diagnostic: docs/designs/optimize-streaming-tail-runs.md (local report)")
            let oldAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
            let oldFont = FontScaleManager.shared.preset
            GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
            FontScaleManager.shared.setPreset(.normal)
            defer {
                GlobalSettingsStore.shared.setMCPAutoStart(oldAutoStart, commit: false)
                FontScaleManager.shared.setPreset(oldFont)
            }
            for (repeatIndex, order) in [[10, 40, 200], [40, 200, 10], [200, 10, 40]].enumerated() {
                for turns in order {
                    print("TAIL_SETUP turns=\(turns) repeat=\(repeatIndex + 1)")
                    try await run(turns: turns, repeatIndex: repeatIndex + 1, workload: workload)
                }
            }
        }

        private func run(turns: Int, repeatIndex: Int, workload: Workload) async throws {
            let recorder = Recorder()
            AgentTranscriptTailRenderProbe.sink = { recorder.receive($0) }
            defer { AgentTranscriptTailRenderProbe.sink = nil }
            let fixture = try await makeFixture(turns: turns, recorder: recorder, workload: workload)
            defer {
                fixture.window.contentView = nil
                fixture.window.close()
            }
            let snapshot = fixture.store.snapshot
            let olderIDs = Set(fixture.source.filter { $0.sequenceIndex < (turns - 1) * 5 && $0.kind == .user }.map(\.id))
            let activeID = fixture.source[(turns - 1) * 5].id
            let tailID = try XCTUnwrap(fixture.source.last?.id)
            print("TAIL_PRESENTATION turns=\(turns) repeat=\(repeatIndex) blocks=\(snapshot.presentation.visibleBlocks.count) rows=\(snapshot.presentation.visibleRows.count) hydrated=\(snapshot.isHydrated) pane=\(snapshot.panePresentation) font=\(FontScaleManager.shared.preset) viewport=1000x800 sourceTailStreaming=\(fixture.source.last?.isStreaming == true) projectedTailStreaming=\(snapshot.presentation.visibleRows.last(where: { $0.id == tailID })?.isStreaming == true)")
            var failure: Error?
            do {
                guard snapshot.currentTabID == fixture.tabID, snapshot.presentation.tabID == fixture.tabID,
                      snapshot.isHydrated, snapshot.panePresentation == .transcript
                else { throw GateFailure(description: "production pane scope/hydration") }
                try await wait(fixture, seconds: 60, gate: "attached rich native older/active witnesses") {
                    olderIDs.contains { self.hasRichWitness($0, in: fixture) }
                        && self.hasRichWitness(activeID, in: fixture)
                        && fixture.host.layouts > 0
                        && recorder.counts.values.contains { $0["ensureLayout", default: 0] > 0 }
                }
                print("TAIL_MOUNT_GATE passed olderRows=\(olderIDs.count(where: { self.hasRichWitness($0, in: fixture) })) active=\(recorder.attached(activeID, window: fixture.window).count) tail=\(recorder.attached(tailID, window: fixture.window).count)")
                try await calibrateNativeUpdate(fixture, rowID: activeID)
                try await measureChunks(fixture, turns: turns, repeatIndex: repeatIndex, tailID: tailID, workload: workload)
            } catch {
                print("TAIL_BASELINE_UNAVAILABLE turns=\(turns) repeat=\(repeatIndex) gate=\(error) bodies=\(recorder.bodies.count) nativeInstances=\(recorder.natives.count) attached=\(recorder.natives.values.count(where: { $0.view?.window === fixture.window })) layouts=\(fixture.host.layouts) nativeCounts=\(recorder.counts.values.reduce(into: [String: Int]()) { result, counts in for (key, value) in counts { result[key, default: 0] += value } })")
                failure = error
            }
            AgentTranscriptTailRenderProbe.sink = nil
            fixture.window.contentView = nil
            fixture.window.close()
            await fixture.state.tearDown()
            ownedStates.removeAll { $0 === fixture.state }
            if let failure { throw failure }
        }

        private func measureChunks(_ fixture: Fixture, turns: Int, repeatIndex: Int, tailID: UUID, workload: Workload) async throws {
            let recorder = fixture.recorder
            let evaluated = Set(recorder.bodies.keys)
            let activeIDs = Set(fixture.source.filter { $0.sequenceIndex >= (turns - 1) * 5 }.map(\.id)).subtracting([tailID])
            let cohorts: [(String, Set<UUID>)] = [
                ("older", evaluated.subtracting(activeIDs).subtracting([tailID])),
                ("activeStable", evaluated.intersection(activeIDs)), ("tail", [tailID])
            ]
            guard cohorts[0].1.count > 0, cohorts[1].1.count > 0 else { throw GateFailure(description: "stable cohorts empty") }
            let mountedIDs = Set(recorder.natives.values.compactMap { $0.view?.window === fixture.window ? $0.rowID : nil })
            var base = fixture.store.snapshot
            var tail = try XCTUnwrap(base.presentation.visibleRows.first { $0.id == tailID })
            let vm = fixture.state.agentModeViewModel
            let session = vm.session(for: fixture.tabID)
            let runInteraction = fixture.state.agentModeViewModel.ui.runInteraction.snapshot
            guard runInteraction.runState == .running else {
                throw GateFailure(description: "canonical run interaction must be running")
            }
            guard tail.isStreaming == workload.projectedStreaming, session.items.last?.isStreaming == true else {
                throw GateFailure(description: "unexpected source/projected streaming state for \(workload.rawValue)")
            }
            let tailBlockKinds = base.presentation.visibleBlocks.filter { $0.rows.contains { $0.id == tailID } }.map { String(describing: $0.kind) }
            print("TAIL_ROUTE turns=\(turns) repeat=\(repeatIndex) runState=\(runInteraction.runState) projectedStreaming=\(tail.isStreaming) blockKinds=\(tailBlockKinds) cadence=\(tail.isStreaming ? "streamingCoalesced" : "immediate")")
            guard !MarkdownStreamingFreezeBoundaryResolver.shouldConsiderSegmentation(for: tail.text + String(repeating: "x", count: 9 * 128)) else {
                throw GateFailure(description: "workload exceeds single native renderer boundary")
            }
            var publications = 0
            let subscription = fixture.store.$snapshot.dropFirst().sink { _ in publications += 1 }
            defer { subscription.cancel() }
            for ordinal in 0 ... 8 {
                // Narration stays below the production substantive-assistant boundary (80 characters).
                let marker = workload == .richConclusion ? String(format: "CHUNK%02d", ordinal) : "n\(ordinal)"
                let delta = workload == .richConclusion ? String(repeating: "x", count: 128 - marker.utf8.count) + marker : marker
                let sourceBefore = session.items
                let expectedText = tail.text + delta
                recorder.bodies = [:]
                recorder.blocks = [:]
                recorder.counts = [:]
                recorder.latestBody = [:]
                recorder.footers = [:]
                publications = 0
                let layoutsBefore = fixture.host.layouts
                let cpuBefore = try mainThreadCPU()
                let start = ProcessInfo.processInfo.systemUptime
                vm.streamRuntime.enqueueAssistantDelta(delta, session: session)
                vm.streamRuntime.flushPendingAssistantDelta(session)
                var driveMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                var serial = recorder.serial
                var lastChange = ProcessInfo.processInfo.systemUptime
                var quietTurns = 0
                var acknowledged = false
                while ProcessInfo.processInfo.systemUptime - start < 5 {
                    let driveStart = ProcessInfo.processInfo.systemUptime
                    fixture.host.layoutSubtreeIfNeeded()
                    driveMS += (ProcessInfo.processInfo.systemUptime - driveStart) * 1000
                    let now = ProcessInfo.processInfo.systemUptime
                    if recorder.serial != serial {
                        serial = recorder.serial
                        lastChange = now
                        quietTurns = 0
                    } else { quietTurns += 1 }
                    let ready = publications >= 1 && recorder.latestBody[tailID] == expectedText
                        && recorder.attached(tailID, window: fixture.window).contains { $0.string.contains(marker) }
                    if ready, quietTurns >= 2, now - lastChange >= 0.22 { acknowledged = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let wallMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                let cpuMS = try (mainThreadCPU()) - cpuBefore
                let next = fixture.store.snapshot
                tail = try XCTUnwrap(next.presentation.visibleRows.first { $0.id == tailID })
                guard acknowledged, publications >= 1, tail.text == expectedText,
                      tail.isStreaming == workload.projectedStreaming,
                      session.items.last?.isStreaming == true,
                      sourceBefore.filter({ $0.id != tailID }) == session.items.filter({ $0.id != tailID }),
                      base.presentation.visibleRows.filter({ $0.id != tailID }) == next.presentation.visibleRows.filter({ $0.id != tailID }),
                      base.presentation.visibleBlocks.map(\.id) == next.presentation.visibleBlocks.map(\.id),
                      base.presentation.rowAnchorIndex == next.presentation.rowAnchorIndex,
                      vm.ui.runInteraction.snapshot == runInteraction
                else {
                    throw GateFailure(description: "\(workload.rawValue) chunk=\(ordinal) VM marker/native/settle/stable-input gate publications=\(publications) projectedStreaming=\(tail.isStreaming)")
                }
                if ordinal > 0 {
                    var record: [String: Any] = [
                        "workload": workload.rawValue,
                        "sourceStreaming": session.items.last?.isStreaming == true,
                        "deltaBytes": delta.utf8.count,
                        "turns": turns,
                        "repeat": repeatIndex,
                        "chunk": ordinal,
                        "revision": next.presentationRevision,
                        "publications": publications,
                        "runState": runInteraction.runState.rawValue,
                        "projectedStreaming": tail.isStreaming,
                        "tailBlockKinds": tailBlockKinds,
                        "mainDriveElapsedMS": driveMS,
                        "mainThreadCPUMS": cpuMS,
                        "settleWallMS": wallMS,
                        "hostLayouts": fixture.host.layouts - layoutsBefore,
                        "blockBuildCalls": recorder.blocks.values.reduce(0, +),
                        "blockBuildCallsByID": recorder.blocks,
                        "presentedRows": base.presentation.visibleRows.count,
                        "presentedBlocks": base.presentation.visibleBlocks.count
                    ]
                    // Include newly evaluated/mounted IDs, not just the setup population.
                    let observed = Set(recorder.bodies.keys).union(recorder.counts.keys).union(recorder.footers.keys)
                    let chunkCohorts: [(String, Set<UUID>)] = [
                        ("older", observed.subtracting(activeIDs).subtracting([tailID])),
                        ("activeStable", observed.intersection(activeIDs)), ("tail", [tailID])
                    ]
                    for (name, ids) in chunkCohorts {
                        var counters = Dictionary(uniqueKeysWithValues: ["make", "update", "replacement", "size", "ensureLayout", "draw"].map { ($0, 0) })
                        for id in ids {
                            for (key, value) in recorder.counts[id] ?? [:] {
                                counters[key, default: 0] += value
                            }
                        }
                        record[name] = [
                            "setupEvaluatedDenominator": cohorts.first { $0.0 == name }!.1.count,
                            "observedIDs": ids.map(\.uuidString).sorted(),
                            "evaluatedDenominator": ids.count,
                            "setupMountedNativeRows": cohorts.first { $0.0 == name }!.1.intersection(mountedIDs).count,
                            "bodyCalls": ids.reduce(0) { $0 + recorder.bodies[$1, default: 0] },
                            "bodyDistinct": ids.count(where: { recorder.bodies[$0, default: 0] > 0 }),
                            "native": counters
                        ] as [String: Any]
                    }
                    let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    print("TAIL_SAMPLE \(String(decoding: json, as: UTF8.self))")
                } else { print("TAIL_WARMUP passed turns=\(turns) repeat=\(repeatIndex)") }
                base = next
            }
        }

        /// CPU consumed by the current main thread, including callbacks between driver intervals.
        private func mainThreadCPU() throws -> Double {
            guard Thread.isMainThread else { throw GateFailure(description: "CPU clock off main thread") }
            let thread = mach_thread_self()
            defer { mach_port_deallocate(mach_task_self_, thread) }
            var info = thread_basic_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { throw GateFailure(description: "main-thread CPU clock unavailable") }
            return Double(info.user_time.seconds + info.system_time.seconds) * 1000
                + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
        }

        private func hasRichWitness(_ id: UUID, in fixture: Fixture) -> Bool {
            fixture.recorder.bodies[id, default: 0] > 0 && fixture.recorder.attached(id, window: fixture.window).contains { view in
                view.string.contains("CODEMARK") && view.string.contains("TABLEMARK")
                    && view.lastMeasuredSize.width > 1 && view.lastMeasuredSize.height > 1 && containsTable(view)
            }
        }

        private func calibrateNativeUpdate(_ fixture: Fixture, rowID: UUID) async throws {
            let base = fixture.store.snapshot
            var changed = try XCTUnwrap(base.presentation.visibleRows.first { $0.id == rowID })
            changed.text = changed.text.replacingOccurrences(of: "CODEMARK", with: "CALIBRATED")
            let before = fixture.recorder.counts[rowID]?["update", default: 0] ?? 0
            var publications = 0
            let subscription = fixture.store.$snapshot.dropFirst().sink { _ in publications += 1 }
            defer { subscription.cancel() }
            publishSourceItem(changed, in: fixture)
            try await wait(fixture, seconds: 5, gate: "native positive control update and attached storage") {
                (fixture.recorder.counts[rowID]?["update", default: 0] ?? 0) > before
                    && fixture.recorder.attached(rowID, window: fixture.window).contains { $0.string.contains("CALIBRATED") && !$0.string.contains("CODEMARK") }
            }
            guard publications == 1 else { throw GateFailure(description: "control publications=\(publications), expected 1") }
            let original = try XCTUnwrap(base.presentation.visibleRows.first { $0.id == rowID })
            publishSourceItem(original, in: fixture)
            try await wait(fixture, seconds: 5, gate: "native positive control restoration") {
                self.hasRichWitness(rowID, in: fixture) && fixture.recorder.attached(rowID, window: fixture.window).allSatisfy { !$0.string.contains("CALIBRATED") }
            }
            guard publications == 2 else { throw GateFailure(description: "control restore publications=\(publications), expected 2") }
            print("TAIL_NATIVE_CONTROL passed updates=\((fixture.recorder.counts[rowID]?["update", default: 0] ?? 0) - before) publications=\(publications)")
        }

        private func publishSourceItem(_ item: AgentChatItem, in fixture: Fixture) {
            let vm = fixture.state.agentModeViewModel
            let session = vm.session(for: fixture.tabID)
            guard let index = session.items.firstIndex(where: { $0.id == item.id }) else { return }
            session.mutateItem(at: index) { $0 = item }
            vm.refreshDerivedTranscriptState(for: session, reason: .liveMutation)
            vm.updateBindingsFromSession(session)
        }

        /// Derive coherent variants from one production-built presentation, preserving every block identity.
        private func replacing(_ item: AgentChatItem, in base: AgentTranscriptUISnapshot) -> AgentTranscriptUISnapshot {
            func rows(_ rows: [AgentChatItem]) -> [AgentChatItem] {
                rows.map { $0.id == item.id ? item : $0 }
            }
            func blocks(_ input: [AgentTranscriptRenderBlock]) -> [AgentTranscriptRenderBlock] {
                input.map { block in
                    let grouped = block.groupedHistory.map { history in
                        AgentTranscriptGroupedHistory(summary: history.summary, sections: history.sections.map { section in
                            AgentTranscriptGroupedSection(id: section.id, kind: section.kind, title: section.title, icon: section.icon, childBlocks: blocks(section.childBlocks), clusterSummary: section.clusterSummary)
                        })
                    }
                    var copy = AgentTranscriptRenderBlock(
                        id: block.id, kind: block.kind, turnID: block.turnID, spanID: block.spanID,
                        retentionTier: block.retentionTier, rows: rows(block.rows), isArchived: block.isArchived,
                        primaryAnchor: block.primaryAnchor, anchorActivityID: block.anchorActivityID, activityIDs: block.activityIDs,
                        clusterSummary: block.clusterSummary, groupedHistory: grouped, collapsedHistoryRange: block.collapsedHistoryRange,
                        defaultPresentation: block.defaultPresentation
                    )
                    copy.displaySummaryInputs = block.displaySummaryInputs
                    return copy
                }
            }
            let p = base.presentation
            var result = base
            result.presentationRevision += 1
            result.presentation = AgentTranscriptPresentationSnapshot(
                tabID: p.tabID, revision: p.revision + 1,
                visibleBlocks: blocks(p.visibleBlocks), workingBlocks: blocks(p.workingBlocks),
                visibleRows: rows(p.visibleRows), workingRows: rows(p.workingRows),
                rowAnchorIndex: p.rowAnchorIndex, anchorBlockIndex: p.anchorBlockIndex, archivedHistoryState: p.archivedHistoryState,
                isCompressedHistoryRevealed: p.isCompressedHistoryRevealed, isTranscriptWindowExpanded: p.isTranscriptWindowExpanded,
                isWindowCappedWhileActive: p.isWindowCappedWhileActive, bindingsHydrated: p.bindingsHydrated,
                hydratedPersistentBinding: p.hydratedPersistentBinding, hydratedBindingTransitionGeneration: p.hydratedBindingTransitionGeneration,
                performanceSnapshot: p.performanceSnapshot, metadata: p.metadata, rawToolResultPayloadRenderRevisionByItemID: p.rawToolResultPayloadRenderRevisionByItemID
            )
            result.archivedBlocks = blocks(base.archivedBlocks)
            return result
        }

        private func containsTable(_ view: CodeBlockTextView) -> Bool {
            guard let storage = view.textStorage else { return false }
            var found = false
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let style = value as? NSParagraphStyle, style.textBlocks.contains(where: { $0 is NSTextTableBlock }) { found = true }
            }
            return found
        }

        private func wait(_ fixture: Fixture, seconds: Double, gate: String, until ready: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                fixture.host.layoutSubtreeIfNeeded()
                if ready() { return }
                // A scheduler/coalescer servicing interval, never a substitute for the readiness oracle.
                try await Task.sleep(for: .milliseconds(20))
            }
            throw GateFailure(description: gate)
        }

        private func makeFixture(turns: Int, recorder: Recorder, workload: Workload = .richConclusion) async throws -> Fixture {
            _ = NSApplication.shared
            let state = WindowState(
                agentModeViewModelFactory: { windowID, prompt, manager, server in
                    let vm = AgentModeViewModel(
                        testWindowID: windowID,
                        codexControllerFactory: { _, _, _, _, _, _ in LifecycleNoopCodexController(recorder: LifecycleRecorder()) },
                        claudeControllerFactory: { _, _, _, _ in MonitorFakeNativeController() },
                        headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1) },
                        acpProviderFactory: { _, _ in throw Refused.providerLaunch },
                        acpControllerFactory: { _, _ in throw Refused.providerLaunch },
                        connectionPolicyInstaller: { _, _, _, _, _, _, _, _, _, _, _, _, _ in },
                        mcpRunRoutingCleaner: { _, _, _ in },
                        mcpServerEnabler: { false },
                        testMCPServer: server,
                        testWorkspaceFileContextStore: prompt.workspaceFileContextStore
                    )
                    vm.promptManager = prompt
                    vm.workspaceManager = manager
                    return vm
                },
                contextBuilderProviderFactory: { _, _, _, _ in AgentSessionLinkCapturingHeadlessProvider(failuresRemaining: 1) }
            )
            ownedStates.append(state)
            await state.workspaceManager.awaitInitialized()
            // Windows from an earlier fixture may still own a retiring writer during drain.
            // Transcript item IDs stay deterministic, but every fixture needs its own session.
            let sessionID = UUID()
            let tab = ComposeTabState(name: "Synthetic transcript baseline", activeAgentSessionID: sessionID)
            let workspace = WorkspaceModel(name: "Transcript baseline", repoPaths: [], ephemeralFlag: true, composeTabs: [tab], activeComposeTabID: tab.id)
            state.workspaceManager.workspaces = [workspace]
            let switched = await state.workspaceManager.switchWorkspace(to: workspace, saveState: false, reason: "transcriptTailDiagnostic")
            guard switched == .switched else { throw GateFailure(description: "workspace activation") }
            state.promptManager.loadComposeTabsFromWorkspace(workspace)
            let vm = state.agentModeViewModel
            await vm.handleWorkspaceSwitch(workspace)
            vm.test_setCurrentTabIDOverride(tab.id)
            _ = await vm.ensureSessionReady(tabID: tab.id)
            let session = vm.session(for: tab.id)
            let installed = try XCTUnwrap(vm.test_installPersistentSessionBinding(sessionID: sessionID, on: session, updateWorkspaceMetadata: true))
            XCTAssertEqual(installed.sessionID, sessionID)
            XCTAssertEqual(session.activeAgentSessionID, sessionID)
            session.hasLoadedPersistedState = true
            session.recordRestorationAuthoritative(.persistedPayloadApplied)
            session.markCurrentBindingHydrated()
            session.isTranscriptWindowExpanded = true
            var source = Self.items(turns: turns)
            if workload == .shortNarration {
                let index = source.count - 1
                source[index].text = "Checking "
                source[index].sequenceIndex += 1
                source.insert(AgentChatItem(
                    id: Self.id(90001),
                    timestamp: source[index].timestamp,
                    kind: .assistant,
                    text: "A settled substantive answer.",
                    sequenceIndex: source[index].sequenceIndex - 1
                ), at: index)
            }
            session.runState = .running
            session.items = source
            session.nextSequenceIndex = (source.last?.sequenceIndex ?? -1) + 1
            vm.refreshDerivedTranscriptState(for: session, reason: .liveMutation)
            vm.updateBindingsFromSession(session)
            guard vm.ui.runInteraction.snapshot.runState == .running else {
                throw GateFailure(description: "live fixture did not publish running interaction")
            }

            let parent = AgentModeDetailWithSidebarView(
                agentModeVM: vm, runtimeVM: vm.ui.runtimeMetrics.runtimeVM, statusPillsUI: vm.ui.statusPills,
                contextBuilderAgentVM: state.contextBuilderAgentViewModel, oracleViewModel: state.oracleViewModel,
                promptManager: state.promptManager, workspaceSearchService: state.workspaceSearchService,
                selectionCoordinator: state.selectionCoordinator, stressHarness: nil, windowID: state.windowID,
                currentTabID: tab.id, codexManagedLoginAction: CodexManagedLoginAction(
                    ownerID: ObjectIdentifier(vm),
                    browser: { _ in throw Refused.providerLaunch }, deviceCode: { _ in throw Refused.providerLaunch }
                )
            ).environment(\.agentWindowIsFocused, false)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = CountingHost(rootView: AnyView(parent))
            window.contentView = host
            // Never order the window, activate the app, reassign rootView, or force drawing.
            host.layoutSubtreeIfNeeded()
            return Fixture(state: state, tabID: tab.id, host: host, window: window, source: source, recorder: recorder)
        }

        private static func id(_ value: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value + 1))!
        }

        private static func rich(_ turn: Int) -> String {
            let code = (0 ..< 48).map { "let code\($0) = \(turn * 100 + $0) // CODEMARK" }.joined(separator: "\n")
            let table = (0 ..< 12).map { "| TABLEMARK\($0) | \(turn) | value\($0) |" }.joined(separator: "\n")
            return "Turn \(turn) rich request\n\n```swift\n\(code)\n```\n\n| Marker | Turn | Value |\n| --- | --- | --- |\n\(table)\n\n"
        }

        private static func items(turns: Int) -> [AgentChatItem] {
            (0 ..< turns).flatMap { turn -> [AgentChatItem] in
                let start = turn * 5
                let date = Date(timeIntervalSince1970: 1_800_000_000 + Double(turn * 60))
                return [
                    AgentChatItem(id: id(start), timestamp: date, kind: .user, text: rich(turn), sequenceIndex: start),
                    AgentChatItem(id: id(start + 1), timestamp: date, kind: .assistant, text: "Settled opener \(turn)", sequenceIndex: start + 1),
                    AgentChatItem(id: id(start + 2), timestamp: date, kind: .toolCall, text: "", toolName: "read_file", toolInvocationID: id(10000 + turn), toolArgsJSON: "{\"path\":\"Synthetic.swift\"}", sequenceIndex: start + 2),
                    AgentChatItem(id: id(start + 3), timestamp: date, kind: .toolResult, text: "Synthetic result", toolName: "read_file", toolInvocationID: id(10000 + turn), toolResultJSON: "{\"content\":\"Synthetic result\"}", toolIsError: false, sequenceIndex: start + 3),
                    AgentChatItem(id: id(start + 4), timestamp: date, kind: .assistant, text: turn == turns - 1 ? rich(turn) + "Open streaming paragraph " : "Settled conclusion \(turn)", sequenceIndex: start + 4, isStreaming: turn == turns - 1)
                ]
            }
        }
    }
#endif
