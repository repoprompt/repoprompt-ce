import Darwin
import Foundation

/// An OS-observed process lifetime, never an MCP initialize name or claimed PID.
/// Start time prevents a recycled PID from inheriting consent. Nothing is persisted.
struct MCPApprovalProcessIdentity: Hashable {
    let pid: Int32
    let parentPID: Int32
    let effectiveUID: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.effectiveUID == rhs.effectiveUID
            && lhs.startSeconds == rhs.startSeconds && lhs.startMicroseconds == rhs.startMicroseconds
            && lhs.executablePath == rhs.executablePath
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(effectiveUID)
        hasher.combine(startSeconds)
        hasher.combine(startMicroseconds)
        hasher.combine(executablePath)
    }

    static func read(pid: Int32) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size),
              info.pbi_pid == UInt32(pid)
        else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return Self(
            pid: pid,
            parentPID: Int32(info.pbi_ppid),
            effectiveUID: info.pbi_uid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            executablePath: URL(fileURLWithPath: String(cString: path))
                .resolvingSymlinksInPath().standardizedFileURL.path
        )
    }

    /// Only a verified bundled transport may delegate identity to its immediate parent.
    /// Never walk ancestors looking for a recognizable application or trust client metadata.
    static func resolve(
        peerPID: Int32,
        bundledHelper: Bool,
        read: (Int32) -> Self? = Self.read
    ) -> Self? {
        guard let peer = read(peerPID), peer.effectiveUID == geteuid() else { return nil }
        guard bundledHelper else { return peer }
        guard let parent = read(peer.parentPID),
              parent.effectiveUID == peer.effectiveUID,
              let recheckedPeer = read(peerPID), recheckedPeer == peer,
              recheckedPeer.parentPID == peer.parentPID
        else { return nil }
        return parent
    }
}
