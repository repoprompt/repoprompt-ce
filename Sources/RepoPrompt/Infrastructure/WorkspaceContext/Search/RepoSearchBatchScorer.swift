import Foundation
import RepoPromptC

enum RepoSearchBatchScorer {
    struct Candidate {
        let name: String
        let path: String
        let nameLower: String
        let pathLower: String
    }

    static func scores(
        for candidates: [Candidate],
        query: RepoSearchQuery,
        fuzzyThreshold: Double
    ) -> [Int32] {
        guard !candidates.isEmpty, !query.isEmpty else { return [] }

        var totalBufferSize = 0
        for candidate in candidates {
            totalBufferSize += candidate.name.utf8.count + 1
            totalBufferSize += candidate.path.utf8.count + 1
            totalBufferSize += candidate.nameLower.utf8.count + 1
            totalBufferSize += candidate.pathLower.utf8.count + 1
        }
        guard totalBufferSize > 0 else { return Array(repeating: 0, count: candidates.count) }

        let stringBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: totalBufferSize)
        defer { stringBuffer.deallocate() }

        var fileInfos: [repo_file_info] = []
        fileInfos.reserveCapacity(candidates.count)

        var currentOffset = 0
        for candidate in candidates {
            let namePtr = stringBuffer.advanced(by: currentOffset)
            let nameBytes = candidate.name.utf8CString
            nameBytes.withUnsafeBufferPointer { bytes in
                namePtr.initialize(from: bytes.baseAddress!, count: bytes.count)
            }
            currentOffset += nameBytes.count

            let pathPtr = stringBuffer.advanced(by: currentOffset)
            let pathBytes = candidate.path.utf8CString
            pathBytes.withUnsafeBufferPointer { bytes in
                pathPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
            }
            currentOffset += pathBytes.count

            let nameLowerPtr = stringBuffer.advanced(by: currentOffset)
            let nameLowerBytes = candidate.nameLower.utf8CString
            nameLowerBytes.withUnsafeBufferPointer { bytes in
                nameLowerPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
            }
            currentOffset += nameLowerBytes.count

            let pathLowerPtr = stringBuffer.advanced(by: currentOffset)
            let pathLowerBytes = candidate.pathLower.utf8CString
            pathLowerBytes.withUnsafeBufferPointer { bytes in
                pathLowerPtr.initialize(from: bytes.baseAddress!, count: bytes.count)
            }
            currentOffset += pathLowerBytes.count

            fileInfos.append(
                repo_file_info(
                    name: UnsafePointer(namePtr),
                    path: UnsafePointer(pathPtr),
                    name_lower: UnsafePointer(nameLowerPtr),
                    path_lower: UnsafePointer(pathLowerPtr)
                )
            )
        }

        var scores = [Int32](repeating: 0, count: candidates.count)
        fileInfos.withUnsafeBufferPointer { infosPtr in
            scores.withUnsafeMutableBufferPointer { scoresPtr in
                query.raw.withCString { queryPtr in
                    query.lowered.withCString { queryLowerPtr in
                        repo_score_matches_batch(
                            infosPtr.baseAddress,
                            candidates.count,
                            queryPtr,
                            queryLowerPtr,
                            query.hasSlash,
                            query.isWildcard,
                            fuzzyThreshold,
                            scoresPtr.baseAddress
                        )
                    }
                }
            }
        }

        return scores
    }
}
