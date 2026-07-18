import Darwin
import Foundation

actor ProcessRegistry {
    private var children: [pid_t: SpawnedProcess] = [:]

    func add(_ process: SpawnedProcess) {
        children[process.pid] = process
    }

    func remove(pid: pid_t) -> SpawnedProcess? {
        children.removeValue(forKey: pid)
    }

    func removeAll() -> [SpawnedProcess] {
        let current = Array(children.values)
        children.removeAll()
        return current
    }

    func current() -> [SpawnedProcess] {
        Array(children.values)
    }
}
