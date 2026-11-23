import AppKit
import IOKit.pwr_mgt
import RepoPromptRemoteProtocol
import ServiceManagement

/// Owns desktop availability policy for the Remote surface. The assertion is
/// held only while an authoritative Agent Mode session is active or waiting
/// for input; an idle gateway does not keep the Mac awake.
@MainActor
final class RemoteAvailabilityController: ObservableObject {
    private static let launchAtLoginKey = "RepoPrompt.remote.launchAtLogin"

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var preventsIdleSleepForActiveRun = false
    @Published private(set) var lastError: String?

    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    init() {
        launchAtLoginEnabled = UserDefaults.standard.bool(forKey: Self.launchAtLoginKey)
        refreshLaunchAtLoginStatus()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            UserDefaults.standard.set(enabled, forKey: Self.launchAtLoginKey)
            launchAtLoginEnabled = enabled
            lastError = nil
        } catch {
            lastError = "Launch at login could not be updated: \(error.localizedDescription)"
            refreshLaunchAtLoginStatus()
        }
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
        if status == .notFound {
            lastError = "The installed app bundle does not expose a launch-at-login registration."
        }
    }

    func update(snapshot: RemoteSnapshot) {
        let shouldPreventSleep = snapshot.sessions.contains { Self.requiresSleepAssertion($0.runState) }

        if shouldPreventSleep {
            acquireSleepAssertionIfNeeded()
        } else {
            releaseSleepAssertionIfNeeded()
        }
    }

    func releaseSleepAssertion() {
        releaseSleepAssertionIfNeeded()
    }

    static func requiresSleepAssertion(_ state: RemoteRunState) -> Bool {
        switch state {
        case .opening, .working, .waitingForInput, .blocked:
            true
        case .idle, .completed, .failed, .cancelled:
            false
        }
    }

    private func acquireSleepAssertionIfNeeded() {
        guard assertionID == IOPMAssertionID(kIOPMNullAssertionID) else { return }

        var createdAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "RepoPrompt agent run active" as CFString,
            &createdAssertion
        )
        guard result == kIOReturnSuccess else {
            lastError = "Active-run sleep prevention could not be enabled (IOKit status \(result))."
            return
        }
        assertionID = createdAssertion
        preventsIdleSleepForActiveRun = true
    }

    private func releaseSleepAssertionIfNeeded() {
        guard assertionID != IOPMAssertionID(kIOPMNullAssertionID) else {
            preventsIdleSleepForActiveRun = false
            return
        }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        preventsIdleSleepForActiveRun = false
    }
}
