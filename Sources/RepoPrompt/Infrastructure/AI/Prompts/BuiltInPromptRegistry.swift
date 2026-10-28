import CryptoKit
import Foundation
import os

/// Stable identifiers for built-in prompts whose mutable body lives in
/// `AppResources/Prompts/<rawValue>/prompt.md`.
///
/// Only plain-text bodies belong here. Code-owned fragments (mode suffixes, conditional
/// sections, interpolated values) stay in Swift and are appended by the caller.
enum BuiltInPromptID: String, CaseIterable, Codable {
    /// Oracle Plan / `[Architect]` system prompt body (`PromptViewModel.architectPrompt`).
    case oraclePlan = "oracle-plan"
    /// Oracle Review / `[Review]` stored-prompt body (`PromptViewModel.reviewPrompt`).
    case oracleReview = "oracle-review"
    /// Oracle Chat system prompt when at least one root folder is visible.
    case oracleChat = "oracle-chat"
    /// Oracle Chat system prompt when no root folder is visible.
    case oracleChatNoRoots = "oracle-chat-no-roots"

    static let promptFileName = "prompt.md"
}

/// One loaded built-in prompt resource.
struct BuiltInPromptResource: Equatable {
    let id: BuiltInPromptID
    /// Effective prompt text: the file's UTF-8 content with exactly one trailing LF removed.
    let text: String
    /// Lowercase hex SHA-256 of the resource file bytes as stored on disk.
    let sha256: String
}

/// A candidate prompt body scoped to one evaluation of one prompt.
///
/// Overrides are never stored in the registry; callers pass one explicitly to
/// `BuiltInPromptRegistry.render(_:override:)`. Production code has no override.
struct BuiltInPromptOverride: Equatable {
    let promptID: BuiltInPromptID
    let text: String
}

/// Rendered prompt text plus the baseline resource it was derived from.
struct RenderedBuiltInPrompt: Equatable {
    let promptID: BuiltInPromptID
    let text: String
    /// SHA-256 of the baseline resource file, recorded even when an override was applied.
    let baselineSHA256: String
    let isOverridden: Bool
}

enum BuiltInPromptRegistryError: Error, Equatable, LocalizedError {
    case resourcesDirectoryUnavailable
    case resourceUnreadable(BuiltInPromptID, path: String)
    case resourceNotRegularFile(BuiltInPromptID, path: String)
    case invalidUTF8(BuiltInPromptID)
    case emptyResource(BuiltInPromptID)
    case overridePromptMismatch(expected: BuiltInPromptID, actual: BuiltInPromptID)

    var errorDescription: String? {
        switch self {
        case .resourcesDirectoryUnavailable:
            "The built-in prompt resources directory is unavailable."
        case let .resourceUnreadable(id, path):
            "Built-in prompt '\(id.rawValue)' could not be read at \(path)."
        case let .resourceNotRegularFile(id, path):
            "Built-in prompt '\(id.rawValue)' at \(path) is not a regular file."
        case let .invalidUTF8(id):
            "Built-in prompt '\(id.rawValue)' is not valid UTF-8."
        case let .emptyResource(id):
            "Built-in prompt '\(id.rawValue)' is empty."
        case let .overridePromptMismatch(expected, actual):
            "A prompt override for '\(actual.rawValue)' cannot render '\(expected.rawValue)'."
        }
    }
}

/// Loads built-in prompt bodies from versioned UTF-8 resources.
///
/// The packaged app reads `Contents/Resources/Prompts` (copied from `AppResources/Prompts`
/// by `Scripts/package_app.sh`). DEBUG builds without a bundled copy, including XCTest,
/// read the checked-in `AppResources/Prompts` directory directly, so tests and the app
/// load the same bytes.
final class BuiltInPromptRegistry: Sendable {
    let promptsDirectory: URL?
    private let cache = OSAllocatedUnfairLock<[BuiltInPromptID: BuiltInPromptResource]>(initialState: [:])

    init(promptsDirectory: URL?) {
        self.promptsDirectory = promptsDirectory
    }

    /// Directory that holds `prompt.md` and any sibling suite resources for `id`.
    func directory(for id: BuiltInPromptID) throws -> URL {
        guard let promptsDirectory else {
            throw BuiltInPromptRegistryError.resourcesDirectoryUnavailable
        }
        return promptsDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    func resource(_ id: BuiltInPromptID) throws -> BuiltInPromptResource {
        if let cached = cache.withLock({ $0[id] }) {
            return cached
        }
        let loaded = try load(id)
        cache.withLock { $0[id] = loaded }
        return loaded
    }

    /// Renders `id`, substituting `override` for the baseline body when supplied.
    func render(_ id: BuiltInPromptID, override: BuiltInPromptOverride? = nil) throws -> RenderedBuiltInPrompt {
        let baseline = try resource(id)
        if let override {
            guard override.promptID == id else {
                throw BuiltInPromptRegistryError.overridePromptMismatch(expected: id, actual: override.promptID)
            }
            return RenderedBuiltInPrompt(promptID: id, text: override.text, baselineSHA256: baseline.sha256, isOverridden: true)
        }
        return RenderedBuiltInPrompt(promptID: id, text: baseline.text, baselineSHA256: baseline.sha256, isOverridden: false)
    }

    /// Exact previous canonical bodies archived by reviewed source-patch application.
    /// Malformed or symlinked archives are ignored rather than trusted as upgrade evidence.
    func previousCanonicalTexts(_ id: BuiltInPromptID) -> [String] {
        guard let directory = try? directory(for: id).appendingPathComponent("previous", isDirectory: true),
              let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return [] }
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".md"),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: url),
                  String(name.dropLast(3)) == Self.sha256Hex(data),
                  var text = String(data: data, encoding: .utf8)
            else { return nil }
            if text.hasSuffix("\n") { text.removeLast() }
            return text
        }
    }

    /// Production accessor. Never applies an override.
    ///
    /// A missing or invalid resource means the app bundle is broken; failing loudly is
    /// preferable to silently sending an empty system prompt.
    func text(_ id: BuiltInPromptID) -> String {
        do {
            return try resource(id).text
        } catch {
            fatalError("Built-in prompt resource failure: \(error.localizedDescription)")
        }
    }

    static func defaultPromptsDirectory(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.resourceURL?.appendingPathComponent("Prompts", isDirectory: true),
           isDirectory(bundled)
        {
            return bundled
        }
        #if DEBUG
            // <repo>/Sources/RepoPrompt/Infrastructure/AI/Prompts/BuiltInPromptRegistry.swift
            var repositoryRoot = URL(fileURLWithPath: #filePath)
            for _ in 0 ..< 6 {
                repositoryRoot.deleteLastPathComponent()
            }
            let sourceTree = repositoryRoot.appendingPathComponent("AppResources/Prompts", isDirectory: true)
            if isDirectory(sourceTree) {
                return sourceTree
            }
        #endif
        return nil
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func load(_ id: BuiltInPromptID) throws -> BuiltInPromptResource {
        let url = try directory(for: id).appendingPathComponent(BuiltInPromptID.promptFileName)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard let values else {
            throw BuiltInPromptRegistryError.resourceUnreadable(id, path: url.path)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BuiltInPromptRegistryError.resourceNotRegularFile(id, path: url.path)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BuiltInPromptRegistryError.resourceUnreadable(id, path: url.path)
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw BuiltInPromptRegistryError.invalidUTF8(id)
        }
        if text.hasSuffix("\n") {
            text.removeLast()
        }
        guard !text.isEmpty else {
            throw BuiltInPromptRegistryError.emptyResource(id)
        }
        return BuiltInPromptResource(id: id, text: text, sha256: Self.sha256Hex(data))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
