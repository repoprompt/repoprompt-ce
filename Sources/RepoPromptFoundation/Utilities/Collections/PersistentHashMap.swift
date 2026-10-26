import Foundation

/// A persistent hash map (a hash array mapped trie) with structural sharing.
///
/// Copying a map is O(1). Mutating a copy duplicates only the trie nodes on the path to the
/// changed key: at most 32 entries per level and `O(log32 n)` levels. An immutable snapshot can
/// therefore be advanced by a small diff while readers keep the previous version, without copying
/// the whole map. Iteration order is unspecified; callers that need an order must sort.
///
/// `copiedEntryCount` accumulates every entry copied or shifted by mutations on this value, so
/// callers can account for the real work of an update (see `takeCopiedEntryCount()`). It is
/// bookkeeping only and does not participate in equality or hashing.
package struct PersistentHashMap<Key: Hashable, Value> {
    fileprivate enum Entry {
        case pair(key: Key, value: Value, hash: Int)
        case child(Node)
        /// Transient placeholder while a child is detached for in-place mutation.
        case vacant
    }

    fileprivate final class Node {
        var bitmap: UInt32
        var entries: ContiguousArray<Entry>
        /// Collision nodes sit below the last hash level and hold unindexed pairs whose full
        /// hashes are equal.
        let isCollision: Bool

        init(bitmap: UInt32 = 0, entries: ContiguousArray<Entry> = [], isCollision: Bool = false) {
            self.bitmap = bitmap
            self.entries = entries
            self.isCollision = isCollision
        }

        func copy() -> Node {
            Node(bitmap: bitmap, entries: entries, isCollision: isCollision)
        }
    }

    private static var bitsPerLevel: Int {
        5
    }

    private var root: Node?
    package private(set) var count = 0
    package private(set) var copiedEntryCount = 0

    package init() {}

    package var isEmpty: Bool {
        count == 0
    }

    package subscript(key: Key) -> Value? {
        get { lookup(key, hash: key.hashValue) }
        set {
            if let newValue {
                updateValue(newValue, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    package subscript(key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        get { self[key] ?? defaultValue() }
        set { updateValue(newValue, forKey: key) }
    }

    /// Returns and resets the copied/shifted entry count accumulated by mutations.
    package mutating func takeCopiedEntryCount() -> Int {
        defer { copiedEntryCount = 0 }
        return copiedEntryCount
    }

    @discardableResult
    package mutating func updateValue(_ value: Value, forKey key: Key) -> Value? {
        let hash = key.hashValue
        var copies = 0
        let previous: Value?
        if root == nil {
            root = Node()
        }
        previous = Self.insert(into: &root!, key: key, value: value, hash: hash, shift: 0, copies: &copies)
        copiedEntryCount += copies
        if previous == nil { count += 1 }
        return previous
    }

    @discardableResult
    package mutating func removeValue(forKey key: Key) -> Value? {
        let hash = key.hashValue
        // Look up first so removing an absent key never copies a shared path.
        guard let previous = lookup(key, hash: hash), root != nil else { return nil }
        var copies = 0
        Self.remove(from: &root!, key: key, hash: hash, shift: 0, copies: &copies)
        copiedEntryCount += copies
        count -= 1
        if count == 0 { root = nil }
        return previous
    }

    // MARK: - Trie operations

    private static func slot(_ hash: Int, _ shift: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: (UInt(bitPattern: hash) >> UInt(shift)) & 31)
    }

    private func lookup(_ key: Key, hash: Int) -> Value? {
        var node = root
        var shift = 0
        while let current = node {
            if current.isCollision {
                for case let .pair(existingKey, value, _) in current.entries where existingKey == key {
                    return value
                }
                return nil
            }
            let bit = UInt32(1) << Self.slot(hash, shift)
            guard current.bitmap & bit != 0 else { return nil }
            let position = (current.bitmap & (bit &- 1)).nonzeroBitCount
            switch current.entries[position] {
            case let .pair(existingKey, value, existingHash):
                return existingHash == hash && existingKey == key ? value : nil
            case let .child(child):
                node = child
                shift += Self.bitsPerLevel
            case .vacant:
                return nil
            }
        }
        return nil
    }

    private static func ensureUnique(_ node: inout Node, copies: inout Int) {
        guard !isKnownUniquelyReferenced(&node) else { return }
        node = node.copy()
        copies += node.entries.count
    }

    private static func insert(
        into node: inout Node,
        key: Key,
        value: Value,
        hash: Int,
        shift: Int,
        copies: inout Int
    ) -> Value? {
        ensureUnique(&node, copies: &copies)
        if node.isCollision {
            for index in node.entries.indices {
                guard case let .pair(existingKey, existingValue, _) = node.entries[index],
                      existingKey == key
                else { continue }
                node.entries[index] = .pair(key: key, value: value, hash: hash)
                copies += 1
                return existingValue
            }
            node.entries.append(.pair(key: key, value: value, hash: hash))
            copies += 1
            return nil
        }
        let bit = UInt32(1) << slot(hash, shift)
        let position = (node.bitmap & (bit &- 1)).nonzeroBitCount
        guard node.bitmap & bit != 0 else {
            node.entries.insert(.pair(key: key, value: value, hash: hash), at: position)
            node.bitmap |= bit
            copies += node.entries.count - position
            return nil
        }
        switch node.entries[position] {
        case let .pair(existingKey, existingValue, existingHash):
            if existingHash == hash, existingKey == key {
                node.entries[position] = .pair(key: key, value: value, hash: hash)
                copies += 1
                return existingValue
            }
            node.entries[position] = .child(makeNode(
                .pair(key: existingKey, value: existingValue, hash: existingHash),
                hash: existingHash,
                .pair(key: key, value: value, hash: hash),
                hash: hash,
                shift: shift + bitsPerLevel
            ))
            copies += 2
            return nil
        case var .child(child):
            // Detach so the child is uniquely referenced unless another version shares it.
            node.entries[position] = .vacant
            let previous = insert(into: &child, key: key, value: value, hash: hash, shift: shift + bitsPerLevel, copies: &copies)
            node.entries[position] = .child(child)
            return previous
        case .vacant:
            preconditionFailure("Persistent hash map nodes never retain vacant entries.")
        }
    }

    private static func makeNode(
        _ first: Entry,
        hash firstHash: Int,
        _ second: Entry,
        hash secondHash: Int,
        shift: Int
    ) -> Node {
        guard shift < Int.bitWidth else {
            return Node(entries: [first, second], isCollision: true)
        }
        let firstSlot = slot(firstHash, shift)
        let secondSlot = slot(secondHash, shift)
        if firstSlot == secondSlot {
            return Node(
                bitmap: UInt32(1) << firstSlot,
                entries: [.child(makeNode(first, hash: firstHash, second, hash: secondHash, shift: shift + bitsPerLevel))]
            )
        }
        let bitmap = (UInt32(1) << firstSlot) | (UInt32(1) << secondSlot)
        return Node(bitmap: bitmap, entries: firstSlot < secondSlot ? [first, second] : [second, first])
    }

    /// Removes a key known to be present.
    private static func remove(
        from node: inout Node,
        key: Key,
        hash: Int,
        shift: Int,
        copies: inout Int
    ) {
        ensureUnique(&node, copies: &copies)
        if node.isCollision {
            if let index = node.entries.firstIndex(where: {
                if case let .pair(existingKey, _, _) = $0 { return existingKey == key }
                return false
            }) {
                node.entries.remove(at: index)
                copies += node.entries.count - index
            }
            return
        }
        let bit = UInt32(1) << slot(hash, shift)
        let position = (node.bitmap & (bit &- 1)).nonzeroBitCount
        switch node.entries[position] {
        case .pair:
            node.entries.remove(at: position)
            node.bitmap &= ~bit
            copies += node.entries.count - position
        case var .child(child):
            node.entries[position] = .vacant
            remove(from: &child, key: key, hash: hash, shift: shift + bitsPerLevel, copies: &copies)
            if child.entries.isEmpty {
                node.entries.remove(at: position)
                node.bitmap &= ~bit
                copies += node.entries.count - position
            } else if child.entries.count == 1, case let .pair(remainingKey, remainingValue, remainingHash) = child.entries[0] {
                // Keep the trie canonical: a lone pair moves back up to this level.
                node.entries[position] = .pair(key: remainingKey, value: remainingValue, hash: remainingHash)
                copies += 1
            } else {
                node.entries[position] = .child(child)
            }
        case .vacant:
            preconditionFailure("Persistent hash map nodes never retain vacant entries.")
        }
    }
}

extension PersistentHashMap: Sequence {
    package struct Iterator: IteratorProtocol {
        fileprivate var stack: [(node: Node, index: Int)]

        package mutating func next() -> (key: Key, value: Value)? {
            while let top = stack.last {
                guard top.index < top.node.entries.count else {
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].index = top.index + 1
                switch top.node.entries[top.index] {
                case let .pair(key, value, _):
                    return (key, value)
                case let .child(child):
                    stack.append((node: child, index: 0))
                case .vacant:
                    continue
                }
            }
            return nil
        }
    }

    package func makeIterator() -> Iterator {
        Iterator(stack: root.map { [(node: $0, index: 0)] } ?? [])
    }

    package var underestimatedCount: Int {
        count
    }

    package var keys: LazyMapSequence<Self, Key> {
        lazy.map(\.key)
    }

    package var values: LazyMapSequence<Self, Value> {
        lazy.map(\.value)
    }
}

extension PersistentHashMap: ExpressibleByDictionaryLiteral {
    package init(dictionaryLiteral elements: (Key, Value)...) {
        self.init()
        for (key, value) in elements {
            updateValue(value, forKey: key)
        }
        copiedEntryCount = 0
    }
}

extension PersistentHashMap: Equatable where Value: Equatable {
    package static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        if lhs.root === rhs.root { return true }
        return lhs.allSatisfy { rhs[$0.key] == $0.value }
    }
}

extension PersistentHashMap: Hashable where Value: Hashable {
    package func hash(into hasher: inout Hasher) {
        // Order-independent: iteration order depends on the trie layout, not on contents.
        var combined = 0
        for (key, value) in self {
            var entryHasher = Hasher()
            entryHasher.combine(key)
            entryHasher.combine(value)
            combined &+= entryHasher.finalize()
        }
        hasher.combine(count)
        hasher.combine(combined)
    }
}

/// Nodes are only mutated after `isKnownUniquelyReferenced`, the same copy-on-write discipline as
/// the standard collections, so shared versions are never observed mid-mutation.
extension PersistentHashMap: @unchecked Sendable where Key: Sendable, Value: Sendable {}

/// A persistent hash set with structural sharing; see `PersistentHashMap`.
package struct PersistentHashSet<Element: Hashable> {
    private var storage = PersistentHashMap<Element, Bool>()

    package init() {}

    package var count: Int {
        storage.count
    }

    package var isEmpty: Bool {
        storage.isEmpty
    }

    package func contains(_ element: Element) -> Bool {
        storage[element] != nil
    }

    @discardableResult
    package mutating func insert(_ element: Element) -> Bool {
        storage.updateValue(true, forKey: element) == nil
    }

    @discardableResult
    package mutating func remove(_ element: Element) -> Element? {
        storage.removeValue(forKey: element) == nil ? nil : element
    }

    package mutating func takeCopiedEntryCount() -> Int {
        storage.takeCopiedEntryCount()
    }
}

extension PersistentHashSet: Sequence {
    package func makeIterator() -> LazyMapSequence<PersistentHashMap<Element, Bool>, Element>.Iterator {
        storage.keys.makeIterator()
    }

    package var underestimatedCount: Int {
        count
    }
}

extension PersistentHashSet: ExpressibleByArrayLiteral {
    package init(arrayLiteral elements: Element...) {
        self.init()
        for element in elements {
            insert(element)
        }
        _ = takeCopiedEntryCount()
    }
}

extension PersistentHashSet: Hashable {}
extension PersistentHashSet: @unchecked Sendable where Element: Sendable {}
