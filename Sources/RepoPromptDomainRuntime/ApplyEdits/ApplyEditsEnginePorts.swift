import Foundation

package protocol DiffChunkGenerator {
    func makeDiffChunks(
        filePath: String,
        originalText: String,
        search: String?,
        replace: String,
        replaceAll: Bool,
        treatAsRewrite: Bool
    ) async throws -> [DiffChunk]
}

package protocol DiffChunkApplier {
    func apply(chunks: [DiffChunk], to originalText: String) throws -> String
}

package protocol UnifiedDiffRendering {
    func render(filePath: String, chunks: [DiffChunk]) -> String
}
