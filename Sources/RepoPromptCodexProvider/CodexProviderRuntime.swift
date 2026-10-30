import Foundation

package enum CodexProviderRuntime {
    package enum Source: Equatable {
        case bundled(target: String)
        case externalOverride
    }

    package struct StatePaths: Equatable {
        package let codexHome: URL
        package let sqliteHome: URL

        package init(codexHome: URL, sqliteHome: URL) {
            self.codexHome = codexHome
            self.sqliteHome = sqliteHome
        }

        package var environment: [String: String] {
            [
                "CODEX_HOME": codexHome.path,
                "CODEX_SQLITE_HOME": sqliteHome.path
            ]
        }
    }

    package struct Runtime: Equatable {
        package let executableURL: URL
        package let version: Version
        package let source: Source
        package let statePaths: StatePaths

        package init(executableURL: URL, version: Version, source: Source, statePaths: StatePaths) {
            self.executableURL = executableURL
            self.version = version
            self.source = source
            self.statePaths = statePaths
        }
    }

    package struct Version: Comparable, CustomStringConvertible, Equatable {
        package let major: Int
        package let minor: Int
        package let patch: Int
        package let prerelease: String?

        package init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prerelease
        }

        package var description: String {
            let core = "\(major).\(minor).\(patch)"
            return prerelease.map { "\(core)-\($0)" } ?? core
        }

        package static func < (lhs: Version, rhs: Version) -> Bool {
            let lhsCore = (lhs.major, lhs.minor, lhs.patch)
            let rhsCore = (rhs.major, rhs.minor, rhs.patch)
            if lhsCore != rhsCore {
                return lhsCore < rhsCore
            }

            switch (lhs.prerelease, rhs.prerelease) {
            case (nil, nil):
                return false
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            case let (.some(lhsPrerelease), .some(rhsPrerelease)):
                return comparePrerelease(lhsPrerelease, rhsPrerelease)
            }
        }

        package static func parse(_ text: String) -> Version? {
            let pattern = #"(?<![0-9A-Za-z.+-])([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?![0-9A-Za-z.+-])"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  match.numberOfRanges == 5,
                  let majorRange = Range(match.range(at: 1), in: text),
                  let minorRange = Range(match.range(at: 2), in: text),
                  let patchRange = Range(match.range(at: 3), in: text),
                  let major = Int(text[majorRange]),
                  let minor = Int(text[minorRange]),
                  let patch = Int(text[patchRange])
            else {
                return nil
            }
            let prerelease = Range(match.range(at: 4), in: text).map { String(text[$0]) }
            if let prerelease {
                let hasInvalidNumericIdentifier = prerelease.split(separator: ".").contains { identifier in
                    identifier.count > 1 && identifier.first == "0" && identifier.allSatisfy(\.isNumber)
                }
                guard !hasInvalidNumericIdentifier else { return nil }
            }
            return Version(major: major, minor: minor, patch: patch, prerelease: prerelease)
        }

        private static func comparePrerelease(_ lhs: String, _ rhs: String) -> Bool {
            let lhsIdentifiers = lhs.split(separator: ".", omittingEmptySubsequences: false)
            let rhsIdentifiers = rhs.split(separator: ".", omittingEmptySubsequences: false)
            for (lhsIdentifier, rhsIdentifier) in zip(lhsIdentifiers, rhsIdentifiers) {
                guard lhsIdentifier != rhsIdentifier else { continue }
                switch (Int(lhsIdentifier), Int(rhsIdentifier)) {
                case let (.some(lhsNumber), .some(rhsNumber)):
                    return lhsNumber < rhsNumber
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return lhsIdentifier < rhsIdentifier
                }
            }
            return lhsIdentifiers.count < rhsIdentifiers.count
        }
    }
}

package struct CodexProviderExecutableResolution: Equatable {
    package enum Status: Equatable {
        case available
        case bundledRuntimeUnavailable
        case externalOverrideInvalid
        case externalOverrideIncompatible
        case unsupportedArchitecture
    }

    package let commandName: String
    package let resolvedCommand: String
    package let status: Status
    package let runtime: CodexProviderRuntime.Runtime?
    package let userMessage: String
    package let debugMessage: String

    package init(commandName: String, resolvedCommand: String, status: Status, runtime: CodexProviderRuntime.Runtime?, userMessage: String, debugMessage: String) {
        self.commandName = commandName
        self.resolvedCommand = resolvedCommand
        self.status = status
        self.runtime = runtime
        self.userMessage = userMessage
        self.debugMessage = debugMessage
    }

    package var environmentOverrides: [String: String] {
        runtime?.statePaths.environment ?? [:]
    }

    package var displayDescription: String? {
        guard let runtime else { return nil }
        return switch runtime.source {
        case let .bundled(target):
            "Bundled Codex \(runtime.version) (\(target))"
        case .externalOverride:
            "Local Codex \(runtime.version) (\(runtime.executableURL.lastPathComponent))"
        }
    }
}
