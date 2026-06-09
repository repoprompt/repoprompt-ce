/// Platform-neutral parent-process lookup used by MCP admission policy.
package protocol ProcessAncestryInspecting: Sendable {
    func parentPID(of pid: Int32) -> Int32?
}
