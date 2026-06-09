import Darwin
import RepoPromptCore

/// macOS `sysctl` adapter for parent-process inspection.
package struct MacOSProcessAncestryInspector: ProcessAncestryInspecting {
    package init() {}

    package func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout.stride(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }
}
