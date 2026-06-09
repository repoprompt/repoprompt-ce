import Darwin
import Foundation

final class HeadlessFileLock {
    typealias DescriptorOpenedHook = (Int32) -> Void

    private let path: URL
    private let stateRoot: URL
    private let descriptorOpenedHook: DescriptorOpenedHook?
    private var descriptor: Int32 = -1

    init(path: URL, stateRoot: URL? = nil, descriptorOpenedHook: DescriptorOpenedHook? = nil) {
        self.path = path
        let parent = path.deletingLastPathComponent()
        self.stateRoot = stateRoot ?? (parent.lastPathComponent == "Workspaces" ? parent.deletingLastPathComponent() : parent)
        self.descriptorOpenedHook = descriptorOpenedHook
    }

    func lock() throws {
        if descriptor >= 0 {
            return
        }
        let fd = try HeadlessStateFileSecurity.openPrivateLockFile(at: path, stateRoot: stateRoot)
        descriptorOpenedHook?(fd)
        if flock(fd, LOCK_EX) != 0 {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw HeadlessCommandError("Unable to lock \(path.path): \(message)", exitCode: 2)
        }
        descriptor = fd
    }

    func unlock() {
        guard descriptor >= 0 else {
            return
        }
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        unlock()
    }

    static func withExclusiveLock<T>(path: URL, stateRoot: URL? = nil, _ body: () throws -> T) throws -> T {
        let lock = HeadlessFileLock(path: path, stateRoot: stateRoot)
        try lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
