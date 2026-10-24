import Foundation

/// Immutable functional-graph index. Each parent edge is examined once; ancestry queries are O(1),
/// including cycles and missing-parent endpoints. This is derived placement, never authority.
package struct DomainAgentSessionAncestryIndex: Sendable {
    private struct Position: Sendable {
        let treeRoot: UUID
        let depth: Int
        let start: Int
        let end: Int
    }

    private struct Cycle: Sendable {
        let id: UUID
        let offset: Int
        let length: Int
    }

    private let positions: [UUID: Position]
    private let cycles: [UUID: Cycle]
    package let buildEdgeVisits: Int

    package init(parents: [UUID: UUID]) {
        let nodes = Set(parents.keys).union(parents.values)
        var resolved: Set<UUID> = []
        var cycles: [UUID: Cycle] = [:]
        var visits = 0
        for node in nodes where !resolved.contains(node) {
            var path: [UUID] = []
            var offsets: [UUID: Int] = [:]
            var cursor: UUID? = node
            while let current = cursor, !resolved.contains(current), offsets[current] == nil {
                offsets[current] = path.count
                path.append(current)
                if parents[current] != nil { visits += 1 }
                cursor = parents[current]
            }
            if let current = cursor, let start = offsets[current] {
                let members = Array(path[start...])
                for (offset, member) in members.enumerated() {
                    cycles[member] = Cycle(id: current, offset: offset, length: members.count)
                }
            }
            resolved.formUnion(path)
        }
        var children: [UUID: [UUID]] = [:]
        for (child, parent) in parents where cycles[child] == nil {
            children[parent, default: []].append(child)
        }
        var positions: [UUID: Position] = [:]
        var ordinal = 0
        for root in nodes where parents[root] == nil || cycles[root] != nil {
            // Enter/exit stack avoids recursive stack growth on large legacy trees.
            var stack: [(UUID, Int, Int?)] = [(root, 0, nil)]
            while let (node, depth, start) = stack.popLast() {
                if let start {
                    positions[node] = Position(treeRoot: root, depth: depth, start: start, end: ordinal)
                } else {
                    let start = ordinal
                    ordinal += 1
                    stack.append((node, depth, start))
                    for child in children[node] ?? [] {
                        stack.append((child, depth + 1, nil))
                    }
                }
            }
        }
        self.positions = positions
        self.cycles = cycles
        buildEdgeVisits = visits
    }

    /// Number of parent hops to the root, or nil. The caller preserves its existing chain bound.
    package func distance(from sessionID: UUID, to rootSessionID: UUID, onLookup: ((UUID) -> Void)? = nil) -> Int? {
        if sessionID == rootSessionID { return 0 }
        onLookup?(sessionID)
        onLookup?(rootSessionID)
        guard let target = positions[sessionID], let root = positions[rootSessionID] else { return nil }
        if target.treeRoot == root.treeRoot, root.start <= target.start, target.start < root.end {
            return target.depth - root.depth
        }
        onLookup?(rootSessionID)
        onLookup?(target.treeRoot)
        guard let rootCycle = cycles[rootSessionID], let entry = cycles[target.treeRoot],
              rootCycle.id == entry.id else { return nil }
        return target.depth + (rootCycle.offset - entry.offset + entry.length) % entry.length
    }
}
