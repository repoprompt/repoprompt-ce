@testable import RepoPrompt
import XCTest

/// Regression coverage for the crash-relaunch session clobber:
/// `windowSessions.json` writes requested while the startup restore session is
/// still loading or applying must be deferred, not written, so a crash-surviving
/// snapshot (and the workspace whose agent/oracle settings it points at) is not
/// overwritten by the transient default/system-workspace startup state.
final class WindowSessionRestorePersistenceGateTests: XCTestCase {
    func testIdleGateAllowsImmediatePersistAndHasNothingToFlush() {
        var gate = WindowSessionRestorePersistenceGate()

        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertTrue(gate.shouldPersistNow(reason: "registerWindow"))
        XCTAssertNil(gate.deferredPersistReason)
        XCTAssertNil(gate.takeFlushableDeferredReason())
    }

    func testPersistRequestsDuringSessionLoadAreDeferredUntilLoadFinishes() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoreSessionLoad()

        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertFalse(gate.shouldPersistNow(reason: "registerWindow"))
        XCTAssertFalse(gate.shouldPersistNow(reason: "focusChanged:true"))
        // Latest deferred reason wins; the flush recaptures current state anyway.
        XCTAssertEqual(gate.deferredPersistReason, "focusChanged:true")
        // Still loading: nothing may flush yet.
        XCTAssertNil(gate.takeFlushableDeferredReason())

        gate.finishRestoreSessionLoad(pendingEntryCount: 0)

        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "focusChanged:true")
        // The deferred request is consumed exactly once.
        XCTAssertNil(gate.takeFlushableDeferredReason())
    }

    func testPersistRequestsDeferredWhileAnyWindowRestoreIsInFlight() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoreSessionLoad()
        gate.finishRestoreSessionLoad(pendingEntryCount: 2)

        // Both entries are handed to their registered windows.
        gate.consumePendingRestoreEntry()
        gate.beginRestoringWindow(1)
        gate.consumePendingRestoreEntry()
        gate.beginRestoringWindow(2)
        XCTAssertEqual(gate.pendingRestoreEntryCount, 0)

        // Load finished but two windows are still applying their restore entries.
        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertFalse(gate.shouldPersistNow(reason: "workspaceSwitch"))
        XCTAssertNil(gate.takeFlushableDeferredReason())

        gate.finishRestoringWindow(1)
        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertNil(gate.takeFlushableDeferredReason())

        gate.finishRestoringWindow(2)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "workspaceSwitch")
    }

    func testLeftoverRestoreEntriesForUnregisteredWindowsKeepPersistsDeferred() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoreSessionLoad()

        // Two-window crash snapshot, but only window 1 has registered so far.
        gate.finishRestoreSessionLoad(pendingEntryCount: 2)
        gate.consumePendingRestoreEntry()
        gate.beginRestoringWindow(1)

        // Window 1 finishes restoring; its focus/workspace-switch persists must NOT
        // write a partial one-window snapshot while window 2's entry is unclaimed.
        gate.finishRestoringWindow(1)
        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertEqual(gate.pendingRestoreEntryCount, 1)
        XCTAssertFalse(gate.shouldPersistNow(reason: "workspaceSwitch"))
        XCTAssertNil(gate.takeFlushableDeferredReason())

        // Window 2 registers late and consumes the leftover entry.
        gate.consumePendingRestoreEntry()
        gate.beginRestoringWindow(2)
        XCTAssertTrue(gate.isRestoreInProgress)
        XCTAssertNil(gate.takeFlushableDeferredReason())

        gate.finishRestoringWindow(2)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "workspaceSwitch")
    }

    func testAbandoningLeftoverRestoreEntriesReleasesGateAndConsumeClampsAtZero() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoreSessionLoad()
        gate.finishRestoreSessionLoad(pendingEntryCount: 1)

        // The entry's window never re-registers; persists stay deferred meanwhile.
        XCTAssertFalse(gate.shouldPersistNow(reason: "focusChanged:true"))
        XCTAssertNil(gate.takeFlushableDeferredReason())

        // The grace valve abandons the leftover entry and reopens persistence.
        gate.abandonPendingRestoreEntries()
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.pendingRestoreEntryCount, 0)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "focusChanged:true")

        // A late hand-off after abandonment must not underflow the pending count.
        gate.consumePendingRestoreEntry()
        XCTAssertEqual(gate.pendingRestoreEntryCount, 0)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertTrue(gate.shouldPersistNow(reason: "workspaceSwitch"))
    }

    func testWindowClosedMidRestoreReleasesGateAndUnknownWindowFinishIsHarmless() {
        var gate = WindowSessionRestorePersistenceGate()
        gate.beginRestoringWindow(7)
        XCTAssertFalse(gate.shouldPersistNow(reason: "unregisterWindow:7"))

        // Unregistering a window mid-restore must not leave the gate held forever.
        gate.finishRestoringWindow(7)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "unregisterWindow:7")

        // Finishing a window that never began restoring stays inert.
        gate.finishRestoringWindow(42)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertNil(gate.takeFlushableDeferredReason())
        XCTAssertTrue(gate.shouldPersistNow(reason: "focusChanged:false"))
    }

    func testCrashRelaunchSequenceNeverAllowsPersistBeforeRestoreCompletes() {
        var gate = WindowSessionRestorePersistenceGate()

        // 1. App init kicks off the async session load before any window registers.
        gate.beginRestoreSessionLoad()

        // 2. First window registers while the load is still pending; its snapshot
        //    would capture the default/system workspace and clobber the crash snapshot.
        XCTAssertFalse(gate.shouldPersistNow(reason: "registerWindow"))

        // 3. Load completes: the entry is counted, then handed to the window.
        gate.finishRestoreSessionLoad(pendingEntryCount: 1)
        gate.consumePendingRestoreEntry()
        gate.beginRestoringWindow(1)
        XCTAssertTrue(gate.isRestoreInProgress)

        // 4. Startup noise (focus, initial workspace activation) keeps deferring.
        XCTAssertFalse(gate.shouldPersistNow(reason: "focusChanged:true"))

        // 5. Restore finishes; only now may a snapshot be written.
        gate.finishRestoringWindow(1)
        XCTAssertFalse(gate.isRestoreInProgress)
        XCTAssertEqual(gate.takeFlushableDeferredReason(), "focusChanged:true")
        XCTAssertTrue(gate.shouldPersistNow(reason: "workspaceSwitch"))
    }
}
