import Foundation

package enum HTTPDecoding {
    package static func decode<T: Decodable>(_ type: T.Type, from data: Data) async throws -> T {
        try await Task.detached(priority: .utility) {
            let decoder = JSONDecoder()
            return try decoder.decode(T.self, from: data)
        }.value
    }
}
