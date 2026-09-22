import Foundation

/// Matches logical slice paths without scanning every modified file for each slice.
struct HiddenSessionSlicePathIndex {
    private let fileIDsByRelativePath: [Substring: Set<UUID>]

    init(relativePathsByFileID: [UUID: String]) {
        var index: [Substring: Set<UUID>] = [:]
        index.reserveCapacity(relativePathsByFileID.count)
        for (fileID, path) in relativePathsByFileID {
            index[Substring(path), default: []].insert(fileID)
        }
        fileIDsByRelativePath = index
    }

    func matchingFileIDs(for slicePaths: [String]) -> Set<UUID> {
        var matches = Set<UUID>()
        for path in slicePaths {
            if let fileIDs = fileIDsByRelativePath[Substring(path)] {
                matches.formUnion(fileIDs)
            }
            // Preserve exact equality or hasSuffix("/" + relativePath), including
            // repeated/trailing separators. Splitting into components would lose them.
            let scalars = path.unicodeScalars
            for separator in scalars.indices where scalars[separator] == "/" {
                let suffix = path[scalars.index(after: separator)...]
                if let fileIDs = fileIDsByRelativePath[suffix] {
                    matches.formUnion(fileIDs)
                }
            }
        }
        return matches
    }
}
