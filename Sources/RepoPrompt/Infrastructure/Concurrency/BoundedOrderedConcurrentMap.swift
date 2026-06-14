import Foundation

private struct BoundedOrderedMapOutcome<Value: Sendable> {
    let index: Int
    let value: Value
}

enum BoundedOrderedConcurrentMap {
    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maxConcurrent: Int,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let limit = min(max(1, maxConcurrent), inputs.count)
        var outcomes = [Output?](repeating: nil, count: inputs.count)
        var nextIndex = 0

        await withTaskGroup(of: BoundedOrderedMapOutcome<Output>.self) { group in
            func schedule(_ index: Int) {
                let input = inputs[index]
                group.addTask {
                    await BoundedOrderedMapOutcome(index: index, value: operation(input))
                }
            }

            while nextIndex < limit {
                schedule(nextIndex)
                nextIndex += 1
            }

            while let outcome = await group.next() {
                outcomes[outcome.index] = outcome.value
                if nextIndex < inputs.count {
                    schedule(nextIndex)
                    nextIndex += 1
                }
            }
        }

        return outcomes.compactMap(\.self)
    }
}
