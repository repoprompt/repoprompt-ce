import Foundation

extension MCPRunRouteBindings {
    @MainActor
    struct PendingRunScopedContextStore {
        private var storage: [String: [Int: [UUID: MCPTabContextSnapshot]]] = [:]

        var isEmpty: Bool {
            storage.isEmpty
        }

        func contains(clientName: String, windowID: Int, runID: UUID) -> Bool {
            storage[clientName]?[windowID]?[runID] != nil
        }

        func contains(clientName: String, runID: UUID) -> Bool {
            storage[clientName]?.values.contains { $0[runID] != nil } == true
        }

        @discardableResult
        mutating func enqueueReplacing(_ context: MCPTabContextSnapshot, clientName: String, windowID: Int) -> Int {
            guard let runID = context.runID else { return queueLength(clientName: clientName, windowID: windowID) }

            // Keep exactly one pending entry per run for a client. If the run is reinstalled
            // for a different window/tab before a socket claims it, the newest exact run
            // context wins deterministically instead of leaving FIFO order to decide.
            if var windowMap = storage[clientName] {
                for existingWindowID in Array(windowMap.keys) {
                    windowMap[existingWindowID]?.removeValue(forKey: runID)
                    if windowMap[existingWindowID]?.isEmpty == true {
                        windowMap.removeValue(forKey: existingWindowID)
                    }
                }
                storage[clientName] = windowMap.isEmpty ? nil : windowMap
            }

            var windowMap = storage[clientName] ?? [:]
            var runMap = windowMap[windowID] ?? [:]
            runMap[runID] = context
            windowMap[windowID] = runMap
            storage[clientName] = windowMap
            return runMap.count
        }

        mutating func pop(clientName: String, windowID: Int, runID: UUID) -> (context: MCPTabContextSnapshot?, remaining: Int) {
            guard var windowMap = storage[clientName],
                  var runMap = windowMap[windowID]
            else {
                return (nil, 0)
            }

            let context = runMap.removeValue(forKey: runID)
            if runMap.isEmpty {
                windowMap.removeValue(forKey: windowID)
            } else {
                windowMap[windowID] = runMap
            }
            if windowMap.isEmpty {
                storage.removeValue(forKey: clientName)
            } else {
                storage[clientName] = windowMap
            }
            return (context, runMap.count)
        }

        mutating func popByRunID(clientName: String, runID: UUID) -> (context: MCPTabContextSnapshot?, windowID: Int?, remaining: Int) {
            guard var windowMap = storage[clientName] else {
                return (nil, nil, 0)
            }

            for windowID in windowMap.keys.sorted() {
                guard var runMap = windowMap[windowID], let context = runMap.removeValue(forKey: runID) else {
                    continue
                }
                if runMap.isEmpty {
                    windowMap.removeValue(forKey: windowID)
                } else {
                    windowMap[windowID] = runMap
                }
                if windowMap.isEmpty {
                    storage.removeValue(forKey: clientName)
                } else {
                    storage[clientName] = windowMap
                }
                return (context, windowID, runMap.count)
            }

            return (nil, nil, 0)
        }

        func queueLength(clientName: String, windowID: Int) -> Int {
            storage[clientName]?[windowID]?.count ?? 0
        }

        mutating func clear(clientName: String) {
            storage.removeValue(forKey: clientName)
        }

        /// Clear only one window queue for a given client.
        @discardableResult
        mutating func clear(clientName: String, windowID: Int) -> Int {
            guard var windowMap = storage[clientName] else { return 0 }
            let removed = windowMap[windowID]?.count ?? 0
            windowMap.removeValue(forKey: windowID)
            if windowMap.isEmpty {
                storage.removeValue(forKey: clientName)
            } else {
                storage[clientName] = windowMap
            }
            return removed
        }

        mutating func purge(tabID: UUID) -> [MCPTabContextSnapshot] {
            var removed: [MCPTabContextSnapshot] = []
            let clientNames = Array(storage.keys)

            for clientName in clientNames {
                guard var windowMap = storage[clientName] else { continue }
                for windowID in Array(windowMap.keys) {
                    guard var runMap = windowMap[windowID] else { continue }
                    for (runID, context) in runMap where context.tabID == tabID {
                        removed.append(context)
                        runMap.removeValue(forKey: runID)
                    }
                    if runMap.isEmpty {
                        windowMap.removeValue(forKey: windowID)
                    } else {
                        windowMap[windowID] = runMap
                    }
                }

                if windowMap.isEmpty {
                    storage.removeValue(forKey: clientName)
                } else {
                    storage[clientName] = windowMap
                }
            }

            return removed
        }
    }
}
