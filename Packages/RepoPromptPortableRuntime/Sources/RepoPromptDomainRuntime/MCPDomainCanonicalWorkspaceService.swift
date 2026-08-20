#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import MCP
import RepoPromptC
import RepoPromptCodeMapCore

public extension DomainPhysicalToolRequest {
    func mcpArguments() throws -> [String: Value] {
        try JSONDecoder().decode([String: Value].self, from: argumentsJSON)
    }
}

public extension DomainPhysicalToolResult {
    static func mcp(_ value: Value) throws -> DomainPhysicalToolResult {
        try DomainPhysicalToolResult(json: JSONEncoder().encode(value))
    }

    static func object(_ value: [String: Value]) throws -> DomainPhysicalToolResult {
        try mcp(.object(value))
    }
}

public struct DomainCanonicalWorkspaceSnapshot: Sendable {
    public let identity: DomainContextIdentity
    public let roots: [URL]
    public let prompt: String
    public let selection: [String]

    public init(
        identity: DomainContextIdentity,
        roots: [URL],
        prompt: String,
        selection: [String]
    ) {
        self.identity = identity
        self.roots = roots
        self.prompt = prompt
        self.selection = selection
    }
}

public enum DomainCanonicalWorkspaceMutation: Sendable {
    case setPrompt(String)
    case setSelection([String])
}

public struct DomainCanonicalWorkspaceAdapter: Sendable {
    public typealias ToolSnapshot = @Sendable (DomainPhysicalToolRequest) async throws -> DomainCanonicalWorkspaceSnapshot
    public typealias ReadSnapshot = @Sendable (DomainPhysicalReadRequest) async throws -> DomainCanonicalWorkspaceSnapshot
    public typealias Mutate = @Sendable (
        DomainPhysicalToolRequest,
        DomainCanonicalWorkspaceMutation
    ) async throws -> DomainCanonicalWorkspaceSnapshot
    public typealias ResolvePath = @Sendable (
        _ rawPath: String,
        _ roots: [URL],
        _ allowMissingLeaf: Bool
    ) throws -> URL

    public let toolSnapshot: ToolSnapshot
    public let readSnapshot: ReadSnapshot
    public let mutate: Mutate
    public let resolvePath: ResolvePath

    public init(
        toolSnapshot: @escaping ToolSnapshot,
        readSnapshot: @escaping ReadSnapshot,
        mutate: @escaping Mutate,
        resolvePath: @escaping ResolvePath
    ) {
        self.toolSnapshot = toolSnapshot
        self.readSnapshot = readSnapshot
        self.mutate = mutate
        self.resolvePath = resolvePath
    }
}

/// Canonical transport-neutral implementation of the standalone workspace capability family.
/// The executable supplies only authoritative snapshot/mutation/path adapters; argument parsing,
/// selection semantics, file reads, search, tree rendering, codemaps, prompt/context projection,
/// mutation admission, and response shapes are owned here.
public struct MCPDomainCanonicalWorkspaceService: Sendable {
    private let adapter: DomainCanonicalWorkspaceAdapter

    public init(adapter: DomainCanonicalWorkspaceAdapter) {
        self.adapter = adapter
    }

    public func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.mcpArguments()
        let snapshot = try await adapter.toolSnapshot(request)
        let op = args["op"]?.stringValue ?? "get"
        var paths = snapshot.selection
        let requested = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        switch op {
        case "get", "preview":
            break
        case "clear":
            paths = []
        case "set":
            paths = requested
        case "add":
            for path in requested where !paths.contains(path) {
                paths.append(path)
            }
        case "remove":
            let removed = Set(requested)
            paths.removeAll { removed.contains($0) }
        case "promote", "demote":
            break
        default:
            throw MCPError.invalidParams("unknown manage_selection op: \(op)")
        }
        if paths != snapshot.selection {
            _ = try await adapter.mutate(request, .setSelection(paths))
        }
        return try .object([
            "selection": .array(paths.map(Value.string)),
            "count": .int(paths.count),
            "operation": .string(op)
        ])
    }

    public func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        let requested = args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? snapshot.selection
        let candidates: [URL] = if requested.isEmpty {
            Self.files(under: snapshot.roots).filter {
                CodeMapSyntaxEngine.supportsCodeMap(fileExtension: $0.pathExtension)
            }
        } else {
            try requested.prefix(256).flatMap { raw -> [URL] in
                let resolved = try adapter.resolvePath(raw, snapshot.roots, false)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return Self.files(under: [resolved])
                }
                return [resolved]
            }
        }
        let limited = Array(candidates.filter {
            CodeMapSyntaxEngine.supportsCodeMap(fileExtension: $0.pathExtension)
        }.prefix(256))
        let files = try await Self.runBlocking {
            try limited.map(Self.codeMapResult)
        }
        return try .object([
            "files": .array(files),
            "updates_pending": .bool(false),
            "backend": .string("headless")
        ])
    }

    public func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        if args["type"]?.stringValue == "roots" {
            return try .mcp(.string(snapshot.roots.map(\.path).joined(separator: "\n")))
        }
        let maxDepth = max(0, min(args["max_depth"]?.intValue ?? 6, 32))
        let roots: [URL] = if let path = args["path"]?.stringValue {
            try [adapter.resolvePath(path, snapshot.roots, false)]
        } else {
            snapshot.roots
        }
        let lines = roots.flatMap { root in Self.treeLines(root: root, maxDepth: maxDepth) }
        return try .mcp(.string(lines.joined(separator: "\n")))
    }

    public func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        guard let rawPath = args["path"]?.stringValue else {
            throw MCPError.invalidParams("missing path")
        }
        let url = try adapter.resolvePath(rawPath, snapshot.roots, false)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let start = args["start_line"]?.intValue
        let limit = args["limit"]?.intValue
        let selected: ArraySlice<String>
        if let start, start < 0 {
            selected = lines.suffix(min(lines.count, abs(start)))
        } else if let start {
            let index = max(0, start - 1)
            guard index < lines.count else { return try .mcp(.string("")) }
            selected = lines[index ..< min(lines.count, index + max(0, limit ?? lines.count))]
        } else {
            selected = lines[...]
        }
        return try .mcp(.string(selected.joined(separator: "\n")))
    }

    public func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        guard let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern cannot be empty")
        }
        let maxResults = max(1, min(args["max_results"]?.intValue ?? 50, 1000))
        let regexEnabled = args["regex"]?.boolValue ?? Self.looksLikeRegex(pattern)
        let wholeWord = args["whole_word"]?.boolValue ?? false
        let regexPattern = wholeWord ? "\\b(?:\(pattern))\\b" : pattern
        let regex = regexEnabled ? try NSRegularExpression(pattern: regexPattern) : nil
        let mode = (args["mode"]?.stringValue ?? "auto").lowercased()
        guard ["auto", "path", "content", "both"].contains(mode) else {
            throw MCPError.invalidParams("mode must be auto, path, content, or both")
        }
        let filter = Self.searchFilter(args)
        let searchesPaths = mode == "path" || mode == "both" || (mode == "auto" && pattern.contains("*"))
        let searchesContent = mode == "content" || mode == "both" || (mode == "auto" && !searchesPaths)
        let relativeRoots = Self.relativeRoots(snapshot.roots)
        var results: [Value] = []
        for file in Self.files(under: snapshot.roots) {
            try Task.checkCancellation()
            if results.count >= maxResults { break }
            let relative = Self.relativePath(file, roots: relativeRoots)
            guard Self.includes(relativePath: relative, file: file, filter: filter) else {
                continue
            }
            if searchesPaths,
               Self.matches(pattern, value: relative, regex: regex, wholeWord: wholeWord)
            {
                results.append(.object(["path": .string(relative)]))
                if results.count >= maxResults { break }
            }
            guard searchesContent else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                if Self.matches(pattern, value: line, regex: regex, wholeWord: wholeWord) {
                    results.append(.object([
                        "path": .string(relative),
                        "line": .int(index + 1),
                        "text": .string(line)
                    ]))
                    if results.count >= maxResults { break }
                }
            }
        }
        if args["count_only"]?.boolValue == true {
            return try .object(["count": .int(results.count)])
        }
        return try .object(["matches": .array(results), "count": .int(results.count)])
    }

    private struct SearchFilter {
        let extensions: Set<String>
        let paths: [String]
        let excludes: [String]
    }

    private static func searchFilter(_ args: [String: Value]) -> SearchFilter {
        let object = args["filter"]?.objectValue ?? [:]
        let extensions = Set(strings(object["extensions"]).map {
            let normalized = $0.lowercased()
            return normalized.hasPrefix(".") ? normalized : "." + normalized
        })
        var paths = strings(object["paths"])
        if let path = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
            paths.append(path)
        }
        return SearchFilter(
            extensions: extensions,
            paths: paths,
            excludes: strings(object["exclude"])
        )
    }

    private static func strings(_ value: Value?) -> [String] {
        guard let value else { return [] }
        switch value {
        case let .array(values):
            return values.compactMap(\.stringValue).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        case let .string(value):
            return value.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        default:
            return []
        }
    }

    private static func includes(relativePath: String, file: URL, filter: SearchFilter) -> Bool {
        if !filter.extensions.isEmpty {
            let fileExtension = file.pathExtension.isEmpty ? "" : "." + file.pathExtension.lowercased()
            guard filter.extensions.contains(fileExtension) else { return false }
        }
        if !filter.paths.isEmpty,
           !filter.paths.contains(where: { matchesPathFilter($0, relativePath: relativePath) })
        {
            return false
        }
        return !filter.excludes.contains(where: { matchesExclude($0, relativePath: relativePath) })
    }

    private static func matchesPathFilter(_ rawPattern: String, relativePath: String) -> Bool {
        let pattern = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !pattern.isEmpty else { return true }
        if containsWildcard(pattern) {
            return globMatches(pattern, relativePath)
        }
        let candidate = pattern.lowercased()
        let relative = relativePath.lowercased()
        return relative == candidate || relative.hasPrefix(candidate + "/")
    }

    private static func matchesExclude(_ pattern: String, relativePath: String) -> Bool {
        if containsWildcard(pattern) {
            return globMatches(pattern, relativePath)
        }
        return relativePath.localizedCaseInsensitiveContains(pattern)
    }

    private static func containsWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?") || pattern.contains("[")
    }

    private static func globMatches(_ pattern: String, _ path: String) -> Bool {
        let wildstar: UInt32 = 0x40
        let casefold: UInt32 = 0x10
        let flags = (pattern.contains("**") ? wildstar : 0) | casefold
        return pattern.withCString { patternCString in
            path.withCString { pathCString in
                repo_wildmatch(patternCString, pathCString, flags) == 0
            }
        }
    }

    public func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        let op = args["op"]?.stringValue ?? "snapshot"
        switch op {
        case "snapshot":
            return try .object([
                "prompt": .string(snapshot.prompt),
                "selection": .array(snapshot.selection.map(Value.string)),
                "roots": .array(snapshot.roots.map { .string($0.path) }),
                "workspace_id": .string(snapshot.identity.workspaceID.uuidString),
                "context_id": .string(snapshot.identity.contextID.uuidString)
            ])
        case "export":
            guard let path = args["path"]?.stringValue else {
                throw MCPError.invalidParams("export requires path")
            }
            let destination = try adapter.resolvePath(path, snapshot.roots, true)
            try await admitExport(destination, roots: snapshot.roots)
            let content = "Prompt:\n\(snapshot.prompt)\n\nSelection:\n\(snapshot.selection.joined(separator: "\n"))\n"
            try content.write(to: destination, atomically: true, encoding: .utf8)
            return try .object(["path": .string(destination.path), "exported": .bool(true)])
        case "list_presets":
            return try .object(["presets": .array([])])
        case "select_preset":
            throw MCPError.invalidRequest("copy presets are unavailable without an extracted preset backend")
        default:
            throw MCPError.invalidParams("unknown workspace_context op: \(op)")
        }
    }

    public func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        let args = try request.request.mcpArguments()
        let snapshot = try await adapter.readSnapshot(request)
        let op = args["op"]?.stringValue ?? "get"
        switch op {
        case "get":
            return try .object(["prompt": .string(snapshot.prompt)])
        case "set", "append", "clear":
            let prompt: String = switch op {
            case "set": args["text"]?.stringValue ?? ""
            case "append": snapshot.prompt + (args["text"]?.stringValue ?? "")
            default: ""
            }
            let physical = DomainPhysicalToolRequest(
                argumentsJSON: request.request.argumentsJSON,
                securityContext: request.request.securityContext
            )
            let updated = try await adapter.mutate(physical, .setPrompt(prompt))
            return try .object(["prompt": .string(updated.prompt), "operation": .string(op)])
        case "export":
            guard let path = args["path"]?.stringValue else {
                throw MCPError.invalidParams("export requires path")
            }
            let destination = try adapter.resolvePath(path, snapshot.roots, true)
            try await admitExport(destination, roots: snapshot.roots)
            try snapshot.prompt.write(to: destination, atomically: true, encoding: .utf8)
            return try .object(["path": .string(destination.path), "exported": .bool(true)])
        case "list_presets":
            return try .object(["presets": .array([])])
        case "select_preset":
            throw MCPError.invalidRequest("select_preset is unavailable without an extracted preset backend")
        default:
            throw MCPError.invalidParams("unknown prompt op: \(op)")
        }
    }

    private func admitExport(_ destination: URL, roots: [URL]) async throws {
        let mappings = roots.map {
            DomainMutationPhysicalRootMapping(canonicalRoot: $0.path, physicalRoot: $0.path)
        }
        try await MCPDomainMutationCommitContext.admitPhysicalTargets(
            [destination.path],
            rootMappings: mappings
        )
        try await MCPDomainMutationCommitContext.willCommit()
    }

    private static func codeMapResult(_ url: URL) throws -> Value {
        let data = try Data(contentsOf: url)
        guard let content = String(data: data, encoding: .utf8) else {
            return .object(["path": .string(url.path), "diagnostic": .string("undecodable_source")])
        }
        guard let language = CodeMapSyntaxEngine.shared.language(forFileExtension: url.pathExtension) else {
            return .object(["path": .string(url.path), "diagnostic": .string("unsupported_language")])
        }
        let snapshot = CodeMapCoreSourceSnapshot(
            rawByteCount: data.count,
            rawSHA256: CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data))),
            decoderPolicy: .workspaceAutomaticV1,
            decodeResult: .decoded(
                CodeMapDecodedSource(text: content, detectedEncodingRawValue: String.Encoding.utf8.rawValue)
            )
        )
        let outcome = try CodeMapSyntaxArtifactBuilder.build(source: snapshot, language: language)
        switch outcome {
        case let .ready(artifact):
            return .object([
                "path": .string(url.path),
                "language": .string(language.rawValue),
                "signatures": .string(artifact.apiDescription)
            ])
        case .readyNoSymbols:
            return .object([
                "path": .string(url.path),
                "language": .string(language.rawValue),
                "signatures": .string(""),
                "diagnostic": .string("no_symbols")
            ])
        case .oversize:
            return .object(["path": .string(url.path), "diagnostic": .string("source_oversize")])
        case .parseFailed:
            return .object(["path": .string(url.path), "diagnostic": .string("parse_failed")])
        case .decodeFailed:
            return .object(["path": .string(url.path), "diagnostic": .string("decode_failed")])
        }
    }

    private static func runBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try operation() })
            }
        }
        try Task.checkCancellation()
        return value
    }

    private static func files(under roots: [URL]) -> [URL] {
        roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL,
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { return nil }
                return url
            }
        }
    }

    private static func treeLines(root: URL, maxDepth: Int) -> [String] {
        var lines = [root.lastPathComponent + "/"]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return lines }
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let depth = relative.split(separator: "/").count
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            lines.append(String(repeating: "  ", count: depth) + url.lastPathComponent + (isDirectory ? "/" : ""))
        }
        return lines
    }

    private struct RelativeRoot {
        let rawPath: String
        let canonicalPath: String
    }

    private static func relativeRoots(_ roots: [URL]) -> [RelativeRoot] {
        roots.map {
            RelativeRoot(
                rawPath: $0.standardizedFileURL.path,
                canonicalPath: $0.resolvingSymlinksInPath().standardizedFileURL.path
            )
        }
    }

    private static func relativePath(_ url: URL, roots: [RelativeRoot]) -> String {
        let path = url.standardizedFileURL.path
        for root in roots {
            for rootPath in [root.rawPath, root.canonicalPath] {
                guard path.hasPrefix(rootPath + "/") else { continue }
                return String(path.dropFirst(rootPath.count + 1))
            }
        }
        return path
    }

    private static func matches(
        _ pattern: String,
        value: String,
        regex: NSRegularExpression?,
        wholeWord: Bool
    ) -> Bool {
        if let regex {
            return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        if containsWildcard(pattern) {
            return globMatches(pattern, value)
        }
        guard wholeWord else { return value.localizedCaseInsensitiveContains(pattern) }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
        return (try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive))?
            .firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func looksLikeRegex(_ pattern: String) -> Bool {
        pattern.range(of: #"[\[\](){}|+?^$\\]"#, options: .regularExpression) != nil
    }
}
