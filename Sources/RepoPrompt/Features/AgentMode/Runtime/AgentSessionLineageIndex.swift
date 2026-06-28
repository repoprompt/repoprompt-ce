import Foundation

struct AgentSessionLineageIndex: Equatable {
    struct Node: Equatable {
        let sessionID: UUID
        let parentSessionID: UUID?

        init(sessionID: UUID, parentSessionID: UUID?) {
            self.sessionID = sessionID
            self.parentSessionID = parentSessionID
        }
    }

    private let sessionIDs: Set<UUID>
    private let orderedSessionIDs: [UUID]
    private let validatedParentBySessionID: [UUID: UUID]
    private let childrenByParentSessionID: [UUID: [UUID]]
    private let rootBySessionID: [UUID: UUID]

    init(nodes: [Node]) {
        var seenSessionIDs = Set<UUID>()
        var orderedSessionIDs: [UUID] = []
        var parentBySessionID: [UUID: UUID] = [:]

        for node in nodes where seenSessionIDs.insert(node.sessionID).inserted {
            orderedSessionIDs.append(node.sessionID)
            if let parentSessionID = node.parentSessionID,
               parentSessionID != node.sessionID
            {
                parentBySessionID[node.sessionID] = parentSessionID
            }
        }

        let sessionIDs = Set(orderedSessionIDs)
        let rawParentBySessionID = parentBySessionID.filter { _, parentSessionID in
            sessionIDs.contains(parentSessionID)
        }

        var validatedParentBySessionID: [UUID: UUID] = [:]
        for sessionID in orderedSessionIDs {
            guard let parentSessionID = rawParentBySessionID[sessionID] else { continue }
            var visited: Set<UUID> = [sessionID]
            var cursor: UUID? = parentSessionID
            var hasCycle = false
            while let current = cursor {
                guard visited.insert(current).inserted else {
                    hasCycle = true
                    break
                }
                cursor = rawParentBySessionID[current]
            }
            if !hasCycle {
                validatedParentBySessionID[sessionID] = parentSessionID
            }
        }

        var childrenByParentSessionID: [UUID: [UUID]] = [:]
        for sessionID in orderedSessionIDs {
            guard let parentSessionID = validatedParentBySessionID[sessionID] else { continue }
            childrenByParentSessionID[parentSessionID, default: []].append(sessionID)
        }

        var rootBySessionID: [UUID: UUID] = [:]
        for sessionID in orderedSessionIDs {
            var cursor = sessionID
            while let parentSessionID = validatedParentBySessionID[cursor] {
                cursor = parentSessionID
            }
            rootBySessionID[sessionID] = cursor
        }

        self.sessionIDs = sessionIDs
        self.orderedSessionIDs = orderedSessionIDs
        self.validatedParentBySessionID = validatedParentBySessionID
        self.childrenByParentSessionID = childrenByParentSessionID
        self.rootBySessionID = rootBySessionID
    }

    func contains(_ sessionID: UUID) -> Bool {
        sessionIDs.contains(sessionID)
    }

    func parentSessionID(of sessionID: UUID) -> UUID? {
        validatedParentBySessionID[sessionID]
    }

    func rootSessionID(for sessionID: UUID) -> UUID? {
        rootBySessionID[sessionID]
    }

    func ancestorSessionIDs(of sessionID: UUID, includeSelf: Bool = false) -> [UUID] {
        guard contains(sessionID) else { return [] }
        var ancestors: [UUID] = includeSelf ? [sessionID] : []
        var cursor = sessionID
        while let parentSessionID = validatedParentBySessionID[cursor] {
            ancestors.append(parentSessionID)
            cursor = parentSessionID
        }
        return ancestors
    }

    func childSessionIDs(of parentSessionID: UUID) -> [UUID] {
        childrenByParentSessionID[parentSessionID] ?? []
    }

    func descendantSessionIDs(of rootSessionID: UUID, includeSelf: Bool = false) -> Set<UUID> {
        guard contains(rootSessionID) else { return [] }
        var descendants: Set<UUID> = includeSelf ? [rootSessionID] : []
        var stack = childSessionIDs(of: rootSessionID)
        while let sessionID = stack.popLast() {
            guard descendants.insert(sessionID).inserted else { continue }
            stack.append(contentsOf: childSessionIDs(of: sessionID))
        }
        return descendants
    }

    func descendantSessionIDsChildFirst(of rootSessionID: UUID, includeSelf: Bool = false) -> [UUID] {
        guard contains(rootSessionID) else { return [] }

        var ordered: [UUID] = []
        func visit(_ sessionID: UUID) {
            for childSessionID in childSessionIDs(of: sessionID) {
                visit(childSessionID)
                ordered.append(childSessionID)
            }
        }

        visit(rootSessionID)
        if includeSelf {
            ordered.append(rootSessionID)
        }
        return ordered
    }
}
