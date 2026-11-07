/// A memory-bounded map that evicts the least recently used entry (overview.md §5: caches stay in memory and bounded).
///
/// A value type: the owning actor keeps it as stored state. Reads through `value(for:)` count as use; `peek(_:)` does
/// not. Capacities are small (repositories, worktrees), so the recency list is a plain array.
struct BoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    let capacity: Int
    private var values: [Key: Value] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    init(capacity: Int) {
        precondition(capacity > 0, "a cache must hold at least one entry")
        self.capacity = capacity
    }

    var count: Int { values.count }
    var keys: [Key] { order }

    /// The value, marking it as most recently used.
    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// The value, without changing its recency.
    func peek(_ key: Key) -> Value? {
        values[key]
    }

    /// Stores the value as most recently used, evicting the least recently used entry when full.
    mutating func insert(_ value: Value, for key: Key) {
        if values.updateValue(value, forKey: key) != nil {
            touch(key)
            return
        }
        order.append(key)
        if order.count > capacity {
            values[order.removeFirst()] = nil
        }
    }

    mutating func removeValue(for key: Key) {
        guard values.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    mutating func removeAll(where shouldRemove: (Key) -> Bool) {
        for key in order where shouldRemove(key) {
            values[key] = nil
        }
        order.removeAll(where: shouldRemove)
    }

    private mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
