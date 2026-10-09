/// A task-local whose bound payload is always a single immutable class reference.
///
/// Use this instead of `@TaskLocal` for any task-local whose value type is a struct, enum, or
/// Foundation value such as `UUID` (https://github.com/repoprompt/repoprompt-ce/issues/1039).
///
/// On macOS releases before 15, async `TaskLocal.withValue` executes the client-emitted
/// `@backDeployed` fallback. When Xcode 26 specializes that fallback for a payload whose size is
/// only known at run time (for example `UUID?`, or a struct containing a `UUID`), it copies the
/// payload into a task-allocator temporary, pushes the task-local item, and then frees the
/// temporary while the item is still the most recent task allocation. The task allocator is
/// strictly LIFO, so the runtime aborts in `swift_task_dealloc` ("freed pointer was not the last
/// allocation") on every such binding. Binding an immutable class reference keeps the payload a
/// fixed, pointer-sized value, so no task-allocator temporary is created.
///
/// Declare the handle as an immutable static and expose reads through a computed property:
///
///     static let currentIDTaskLocal = BoxedTaskLocal<UUID?>(nil)
///     static var currentID: UUID? { currentIDTaskLocal.get() }
///
/// Child-task inheritance and `nil`-shadowing semantics match `@TaskLocal`.
public final class BoxedTaskLocal<Value: Sendable>: Sendable {
    /// Immutable fixed-size carrier bound into the underlying `TaskLocal`.
    public final class Reference: Sendable {
        public let value: Value

        init(_ value: Value) {
            self.value = value
        }
    }

    private let storage: TaskLocal<Reference?>
    private let defaultValue: Value

    public init(_ defaultValue: Value) {
        self.defaultValue = defaultValue
        storage = TaskLocal(wrappedValue: nil)
    }

    public func get() -> Value {
        storage.get()?.value ?? defaultValue
    }

    @discardableResult
    public func withValue<R>(
        _ valueDuringOperation: Value,
        operation: () async throws -> R,
        isolation: isolated (any Actor)? = #isolation,
        file: String = #fileID,
        line: UInt = #line
    ) async rethrows -> R {
        try await storage.withValue(
            Reference(valueDuringOperation),
            operation: { try await operation() },
            file: file,
            line: line
        )
    }

    @discardableResult
    public func withValue<R>(
        _ valueDuringOperation: Value,
        operation: () throws -> R,
        file: String = #fileID,
        line: UInt = #line
    ) rethrows -> R {
        try storage.withValue(Reference(valueDuringOperation), operation: operation, file: file, line: line)
    }
}
