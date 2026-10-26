import Foundation

extension CLIProcessConfiguration {
    package mutating func ensureAdditionalPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        for path in paths where !additionalPaths.contains(path) {
            additionalPaths.append(path)
        }
    }
}
