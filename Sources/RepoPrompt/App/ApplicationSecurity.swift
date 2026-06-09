//
//  ApplicationSecurity.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-27.
//

import Cocoa
import Darwin
import Foundation
import MachO
import os.lock

/// This class handles application security by monitoring the environment
/// for potential tampering or unauthorized access.
class ApplicationSecurity {
    private static let denyAttachRequest: Int32 = 31
    // Singleton instance
    private static let shared = ApplicationSecurity()
    private let stateQueue = DispatchQueue(label: "com.repoprompt.security.state")
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private var didStartMonitoring = false

    private var didEnableAntiDebugging = false
    private var didLogMainThreadSync = false
    private var mainThreadSyncLogLock = os_unfair_lock_s()

    // MARK: - Lock-based soft restrictions (avoids stateQueue.sync from MainActor)

    private var softRestrictionsValue: Bool = false
    private var softRestrictionsLock = os_unfair_lock_s()

    private func getSoftRestrictionsActive() -> Bool {
        os_unfair_lock_lock(&softRestrictionsLock)
        let value = softRestrictionsValue
        os_unfair_lock_unlock(&softRestrictionsLock)
        return value
    }

    /// Returns previous value to detect transitions.
    @discardableResult
    private func setSoftRestrictionsActive(_ newValue: Bool) -> Bool {
        os_unfair_lock_lock(&softRestrictionsLock)
        let old = softRestrictionsValue
        softRestrictionsValue = newValue
        os_unfair_lock_unlock(&softRestrictionsLock)
        return old
    }

    /// Default initialization (no heavy work here; startMonitoring controls timing)
    private init() {
        // Set queue-specific key in all builds so withStateQueue can detect reentrant calls
        // and avoid deadlocks even in DEBUG builds.
        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }

    /// Start monitoring the app environment for security issues
    static func startMonitoring() {
        #if !DEBUG
            _ = shared
            shared.stateQueue.async {
                shared.startIfNeeded()
            }
        #endif
    }

    /// Enable anti-debug attachment hardening (ptrace).
    static func enableAntiDebugging() {
        #if !DEBUG
            _ = shared
            shared.stateQueue.async {
                shared.enableAntiDebuggingIfNeeded()
            }
        #endif
    }

    /// Check if soft restrictions are active.
    /// This is a lock-based read that does NOT block on stateQueue,
    /// preventing UI hangs when security checks are running.
    static func softRestrictionsActive() -> Bool {
        #if !DEBUG
            _ = shared
            return shared.getSoftRestrictionsActive()
        #else
            return false
        #endif
    }

    private func startIfNeeded() {
        #if DEBUG
            dispatchPrecondition(condition: .onQueue(stateQueue))
        #endif
        guard !didStartMonitoring else { return }
        didStartMonitoring = true

        // Schedule initial environmental check asynchronously to avoid blocking MainActor.
        // This keeps launch-time monitoring work off the main thread.
        stateQueue.async { [weak self] in
            self?.performIntegrityCheck()
        }

        schedulePeriodicChecks()
    }

    private func enableAntiDebuggingIfNeeded() {
        #if !DEBUG
            #if DEBUG
                dispatchPrecondition(condition: .onQueue(stateQueue))
            #endif
            guard !didEnableAntiDebugging else { return }
            didEnableAntiDebugging = true
            preventExternalAttachment()
        #endif
    }

    /// Schedule periodic integrity checks at random intervals
    private func schedulePeriodicChecks() {
        #if !DEBUG
            // Random interval between 30-120 seconds to make pattern detection harder
            let randomInterval = Double.random(in: 30 ... 120)
            stateQueue.asyncAfter(deadline: .now() + randomInterval) { [weak self] in
                self?.performIntegrityCheck()
                self?.schedulePeriodicChecks() // Schedule next check
            }
        #endif
    }

    /// Check system integrity - checks for debugger + tamper signals
    private func performIntegrityCheck() {
        #if !DEBUG
            withStateQueue {
                // Strong signal: debugger
                if isBeingInspected() {
                    exitForSecurityViolation()
                }

                let envSignals = environmentSignals()

                // Strong signal: DYLD_INSERT_LIBRARIES
                if envSignals.hasInsert {
                    exitForSecurityViolation()
                }

                // Weak signals:
                // - "Other" DYLD vars are common in enterprise/dev environments.
                // - Single dylib hit can be noisy; require corroboration to hard-exit.
                let hasOtherEnv = envSignals.hasOther
                let dylibHit = hasInjectedLibraries()

                // Avoid hard exit for noisy enterprise environments; keep soft restrictions instead.
                let shouldApplySoftRestrictions = hasOtherEnv || dylibHit
                if shouldApplySoftRestrictions {
                    applySoftRestrictionsIfNeeded()
                } else {
                    clearSoftRestrictionsIfNeeded()
                }
            }
        #endif
    }

    private func applySoftRestrictionsIfNeeded() {
        _ = setSoftRestrictionsActive(true)
    }

    private func clearSoftRestrictionsIfNeeded() {
        _ = setSoftRestrictionsActive(false)
    }

    private func exitForSecurityViolation() -> Never {
        exit(0)
    }

    /// Determine if the application is being inspected (debugged)
    private func isBeingInspected() -> Bool {
        #if !DEBUG
            var info = kinfo_proc()
            var size = MemoryLayout.stride(ofValue: info)
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

            let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)

            // Check if P_TRACED flag is set
            return (result == 0) && ((info.kp_proc.p_flag & P_TRACED) != 0)
        #else
            return false
        #endif
    }

    /// Prevent external attachment - uses ptrace to deny debugger attachment
    private func preventExternalAttachment() {
        #if !DEBUG
            ptrace(Self.denyAttachRequest, 0, nil, 0)
        #endif
    }

    // MARK: - Tamper Signals

    private func environmentSignals() -> (hasInsert: Bool, hasOther: Bool) {
        let env = ProcessInfo.processInfo.environment
        let insertKey = ProcessEnvironmentSanitizer.dynamicLoaderInsertLibrariesKey
        if let value = env[insertKey], !value.isEmpty {
            return (true, true)
        }
        for (key, value) in env {
            guard key != insertKey, !value.isEmpty else { continue }
            if ProcessEnvironmentSanitizer.isDynamicLoaderKey(key) {
                return (false, true)
            }
        }
        return (false, false)
    }

    private func hasInjectedLibraries() -> Bool {
        let suspiciousIndicators = [
            "frida",
            "substrate",
            "cycript",
            "injectioniii",
            "gdb",
            "libhooker",
            "fishhook"
        ]
        let count = _dyld_image_count()
        for index in 0 ..< count {
            guard let namePtr = _dyld_get_image_name(index) else { continue }
            let path = String(cString: namePtr)
            let baseName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
            for indicator in suspiciousIndicators {
                if baseName.contains(indicator) {
                    return true
                }
            }
        }
        return false
    }

    private func withStateQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return body()
        }
        if Thread.isMainThread {
            #if DEBUG
                assertionFailure("ApplicationSecurity.withStateQueue called on main thread")
            #else
                logMainThreadSyncIfNeeded()
            #endif
        }
        return stateQueue.sync { body() }
    }

    private func logMainThreadSyncIfNeeded() {
        os_unfair_lock_lock(&mainThreadSyncLogLock)
        let shouldLog = !didLogMainThreadSync
        if shouldLog {
            didLogMainThreadSync = true
        }
        os_unfair_lock_unlock(&mainThreadSyncLogLock)
        guard shouldLog else { return }
        NSLog("ApplicationSecurity.withStateQueue called on main thread; this can block UI.")
    }
}
