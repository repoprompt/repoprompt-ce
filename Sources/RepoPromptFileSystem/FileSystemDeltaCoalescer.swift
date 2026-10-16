import Foundation
import RepoPromptWorkspaceCore

package enum FileSystemDeltaCoalescer {
    package static func rawRelativePath(for delta: FileSystemDelta) -> String {
        switch delta {
        case let .fileAdded(rel), let .fileRemoved(rel),
             let .folderAdded(rel), let .folderRemoved(rel),
             let .fileModified(rel, _), let .folderModified(rel, _):
            rel
        }
    }

    package static func standardizedRelativePath(for delta: FileSystemDelta) -> String {
        StandardizedPath.relative(rawRelativePath(for: delta))
    }

    package static func containedPaths(
        for delta: FileSystemDelta,
        inRoot standardizedRoot: String
    ) -> (relativePath: String, absolutePath: String)? {
        let rawRelativePath = rawRelativePath(for: delta)
        guard !rawRelativePath.hasPrefix("/") else { return nil }
        let relativePath = standardizedRelativePath(for: delta)
        let joined = StandardizedPath.join(
            standardizedRoot: standardizedRoot,
            standardizedRelativePath: relativePath
        )
        let absolutePath = relativePath == ".." || relativePath.hasPrefix("../")
            ? StandardizedPath.absolute(joined)
            : joined
        guard StandardizedPath.isDescendant(absolutePath, of: standardizedRoot) else { return nil }
        return (relativePath, absolutePath)
    }

    package static func coalesce(
        _ deltas: [FileSystemDelta],
        inRoot standardizedRoot: String? = nil
    ) -> [FileSystemDelta] {
        enum ItemKind {
            case file
            case folder
        }
        struct Key: Hashable {
            let rel: String
            let kind: ItemKind
        }
        struct State {
            var add: (idx: Int, delta: FileSystemDelta, rel: String)?
            var remove: (idx: Int, delta: FileSystemDelta, rel: String)?
            var modify: (idx: Int, delta: FileSystemDelta, rel: String)?
        }

        var table: [Key: State] = [:]
        for (idx, delta) in deltas.enumerated() {
            let rel: String
            if let standardizedRoot {
                guard let contained = containedPaths(for: delta, inRoot: standardizedRoot) else { continue }
                rel = contained.relativePath
            } else {
                rel = standardizedRelativePath(for: delta)
            }
            let kind: ItemKind = switch delta {
            case .fileAdded, .fileRemoved, .fileModified:
                .file
            case .folderAdded, .folderRemoved, .folderModified:
                .folder
            }
            let key = Key(rel: rel, kind: kind)
            switch delta {
            case .fileAdded, .folderAdded:
                table[key, default: State()].add = (idx, delta, rel)
            case .fileRemoved, .folderRemoved:
                table[key, default: State()].remove = (idx, delta, rel)
            case .fileModified, .folderModified:
                table[key, default: State()].modify = (idx, delta, rel)
            }
        }

        var chosen: [(idx: Int, delta: FileSystemDelta, rel: String)] = []
        for state in table.values {
            if let add = state.add, let remove = state.remove {
                chosen.append(add.idx > remove.idx ? add : remove)
            } else if let add = state.add {
                chosen.append(add)
            } else if let remove = state.remove {
                chosen.append(remove)
            }
            if let modify = state.modify,
               state.add == nil,
               state.remove == nil
            {
                chosen.append(modify)
            }
        }

        let removedFolders = chosen.compactMap { pair -> String? in
            if case .folderRemoved = pair.delta {
                return pair.rel
            }
            return nil
        }

        if !removedFolders.isEmpty {
            chosen.removeAll { pair in
                for folder in removedFolders where pair.rel != folder {
                    if StandardizedPath.isDescendant(pair.rel, of: folder) {
                        return true
                    }
                }
                return false
            }
        }

        return chosen.sorted { $0.idx < $1.idx }.map(\.delta)
    }
}
