import Foundation

/// A minimal, allocation-conscious Least-Recently-Used cache.
/// • O(1) get / set
/// • Bounded by `capacity` – oldest entry is evicted on overflow.
/// The implementation relies on a doubly-linked list stitched together with
/// a dictionary for fast key look-ups.  Designed for **single-threaded or
/// actor-isolated** use; no internal locking.
struct LRUCache<Key: Hashable, Value> {
    // MARK: - Node

    private final class Node {
        let key: Key
        var value: Value
        weak var prev: Node?
        var next: Node?
        init(key: Key, value: Value) {
            self.key = key
            self.value = value
        }
    }

    // MARK: - Properties

    private let capacity: Int
    private var dict: [Key: Node] = [:]
    private var head: Node? // Most recently used
    private var tail: Node? // Least recently used

    // MARK: - Init

    init(capacity: Int) {
        precondition(capacity > 0, "LRUCache capacity must be > 0")
        self.capacity = capacity
    }

    // MARK: - Public API

    subscript(key: Key) -> Value? {
        mutating get { value(forKey: key) }
        mutating set {
            if let newVal = newValue {
                _ = insert(key: key, value: newVal)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    var count: Int {
        dict.count
    }

    var keys: [Key] {
        Array(dict.keys)
    }

    func snapshot() -> [Key: Value] {
        var snapshot: [Key: Value] = [:]
        snapshot.reserveCapacity(dict.count)
        for (key, node) in dict {
            snapshot[key] = node.value
        }
        return snapshot
    }

    @discardableResult
    mutating func set(_ value: Value, forKey key: Key) -> Key? {
        setReturningEvictedEntry(value, forKey: key)?.key
    }

    /// Inserts or replaces a value and returns the entry evicted by the count limit.
    /// Replacement is not reported as eviction.
    @discardableResult
    mutating func setReturningEvictedEntry(_ value: Value, forKey key: Key) -> (key: Key, value: Value)? {
        insert(key: key, value: value)
    }

    /// Clear all stored entries.
    mutating func removeAll() {
        var node = head
        while let current = node {
            let next = current.next
            current.prev = nil
            current.next = nil
            node = next
        }
        dict.removeAll()
        head = nil
        tail = nil
    }

    // MARK: - Internal helpers

    @discardableResult
    private mutating func value(forKey key: Key) -> Value? {
        guard let node = dict[key] else { return nil }
        moveToHead(node)
        return node.value
    }

    @discardableResult
    private mutating func insert(key: Key, value: Value) -> (key: Key, value: Value)? {
        if let node = dict[key] {
            // Update value and move to MRU position
            node.value = value
            moveToHead(node)
            return nil
        }

        // New entry
        let node = Node(key: key, value: value)
        dict[key] = node
        insertAtHead(node)

        // Evict if needed
        if dict.count > capacity, let oldTail = tail {
            dict.removeValue(forKey: oldTail.key)
            removeNode(oldTail)
            return (oldTail.key, oldTail.value)
        }
        return nil
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let node = dict[key] else { return nil }
        dict.removeValue(forKey: key)
        removeNode(node)
        return node.value
    }

    @discardableResult
    mutating func removeLeastRecentlyUsed() -> (key: Key, value: Value)? {
        guard let oldTail = tail else { return nil }
        dict.removeValue(forKey: oldTail.key)
        removeNode(oldTail)
        return (oldTail.key, oldTail.value)
    }

    // MARK: - Linked list operations

    private mutating func moveToHead(_ node: Node) {
        guard head !== node else { return }
        removeNode(node)
        insertAtHead(node)
    }

    private mutating func insertAtHead(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil {
            tail = node
        }
    }

    private mutating func removeNode(_ node: Node) {
        let prev = node.prev
        let next = node.next
        prev?.next = next
        next?.prev = prev
        if head === node {
            head = next
        }
        if tail === node {
            tail = prev
        }
        node.prev = nil
        node.next = nil
    }
}
