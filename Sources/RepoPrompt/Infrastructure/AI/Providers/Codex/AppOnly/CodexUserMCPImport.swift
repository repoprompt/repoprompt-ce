import Darwin
import Foundation

/// Explicit, additive snapshot import. Never imports the user's whole Codex configuration.
/// Existing entries and permission selections remain authoritative; no background resync occurs.
enum CodexUserMCPImport {
    struct Result {
        let content: String
        let importedNames: [String]
        let skipped: [String]
        var importedCount: Int {
            importedNames.count
        }

        var summary: String {
            let names = importedNames.prefix(20).map(\.debugDescription).joined(separator: ", ")
            let issues = skipped.prefix(20).joined(separator: "; ")
            return "\(importedCount) new server(s): \(names)." + (issues.isEmpty ? "" : " Skipped: \(issues)")
        }
    }

    enum Failure: Error, LocalizedError {
        case unsupportedConfiguration
        case unreadableFile
        case destinationChanged
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedConfiguration:
                "MCP import needs supported [mcp_servers.name] command/URL definitions with valid, unique keys and values. Ambiguous, malformed, or unsupported TOML layouts were rejected. No configuration was changed."
            case .unreadableFile:
                "MCP import could not read a regular UTF-8 configuration file (maximum 2 MiB). The managed destination must not be a symbolic link. No configuration was changed."
            case .destinationChanged:
                "The managed Codex configuration changed during import. Nothing was imported; try again."
            case .writeFailed:
                "MCP import could not save the private managed configuration."
            }
        }
    }

    private struct Section {
        let path: [String]
        let header: String
        var lines: [String]
        var isArray = false
        var invalid = false
    }

    private static let maximumBytes = 2 * 1024 * 1024

    static func merge(source: String, destination: String) throws -> Result {
        let (sourceSections, scanIssues) = try sections(in: source, tolerant: true)
        let (destinationSections, _) = try sections(in: destination)
        let occupied = Set(destinationSections.compactMap { section in
            section.path.first == "mcp_servers" && section.path.count >= 2 ? normalized(section.path[1]) : nil
        })
        let grouped = Dictionary(grouping: sourceSections.filter { $0.path.first == "mcp_servers" && $0.path.count >= 2 }, by: { $0.path[1] })
        let names = grouped.keys.sorted()
        let aliases = Dictionary(grouping: names, by: normalized)
        var additions: [String] = []
        var imported: [String] = []
        var skipped = scanIssues
        for name in names where !occupied.contains(normalized(name)) && !MCPIntegrationHelper.isReservedMCPServerIdentifier(name) {
            let selected = grouped[name] ?? []
            do {
                guard !normalized(name).isEmpty, aliases[normalized(name)]?.count == 1,
                      name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                      !selected.contains(where: \.invalid) else { throw Failure.unsupportedConfiguration }
                try validate(selected)
                let roots = selected.filter { $0.path.count == 2 }
                var rootLines: [String] = []
                var lexer = ValueLexer()
                for line in roots.first?.lines ?? [] {
                    let assignment = lexer.isAtTopLevel ? CodexIntegrationConfiguration.importAssignment(line) : nil
                    try lexer.consume(line)
                    if assignment?.path == ["enabled"] { continue }
                    rootLines.append(line)
                }
                let key = CodexIntegrationConfiguration.cliPathComponent(forNormalizedServerName: name)
                var rendered = ["[mcp_servers.\(key)]", "enabled = false"] + rootLines
                for section in selected where section.path.count > 2 {
                    rendered.append(section.header)
                    rendered += section.lines
                }
                additions.append(rendered.joined(separator: "\n"))
                imported.append(name)
            } catch let error as CodexUserMCPImportValidation.InvalidKey {
                skipped.append("server \(name.debugDescription), key \(error.path.joined(separator: ".").debugDescription)")
            } catch {
                skipped.append("server \(name.debugDescription): malformed or ambiguous definition")
            }
        }
        guard !additions.isEmpty else { return Result(content: destination, importedNames: [], skipped: skipped) }
        let separator = destination.isEmpty || destination.hasSuffix("\n") ? "\n" : "\n\n"
        return Result(content: destination + separator + additions.joined(separator: "\n\n") + "\n", importedNames: imported, skipped: skipped)
    }

    /// Validate the supported MCP schema as well as syntax before appending anything. In particular,
    /// balanced delimiters alone would accept missing values, duplicate keys, and table/key conflicts.
    private static func validate(_ sections: [Section]) throws {
        typealias Value = CodexUserMCPImportValidation.Value
        var object: [String: Value] = [:]
        var tables = Set<[String]>()
        var assigned: [[String]] = []
        for section in sections {
            let prefix = Array(section.path.dropFirst(2))
            guard prefix.count <= 8, !section.isArray || prefix == ["env_vars"],
                  section.isArray || tables.insert(prefix).inserted,
                  !assigned.contains(where: { prefix.starts(with: $0) || (!prefix.isEmpty && $0.starts(with: prefix)) }) else { throw CodexUserMCPImportValidation.InvalidKey(path: prefix) }
            guard ([section.header] + section.lines).allSatisfy({ line in
                line.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 32 && $0.value != 127) }
            }) else { throw Failure.unsupportedConfiguration }
            var fields: [String: Value] = [:]
            var valuePaths: [[String]] = []
            var lexer = ValueLexer()
            var statement = ""
            for line in section.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if statement.isEmpty, trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                statement += (statement.isEmpty ? "" : "\n") + line
                try lexer.consume(line)
                guard lexer.isAtTopLevel else { continue }
                guard let assignment = CodexIntegrationConfiguration.importAssignment(statement), !assignment.path.isEmpty, assignment.path.count <= 8 else { throw Failure.unsupportedConfiguration }
                do {
                    guard !valuePaths.contains(where: { assignment.path.starts(with: $0) }) else { throw Failure.unsupportedConfiguration }
                    try insert(CodexUserMCPImportValidation.parse(assignment.value), at: assignment.path, into: &fields)
                    valuePaths.append(assignment.path)
                } catch { throw CodexUserMCPImportValidation.InvalidKey(path: prefix + assignment.path) }
                if !section.isArray { assigned.append(prefix + assignment.path) }
                statement = ""
            }
            guard statement.isEmpty else { throw Failure.unsupportedConfiguration }
            if section.isArray {
                if case var .array(entries) = object["env_vars"] {
                    entries.append(.object(fields))
                    object["env_vars"] = .array(entries)
                } else {
                    guard object["env_vars"] == nil else { throw CodexUserMCPImportValidation.InvalidKey(path: prefix) }
                    object["env_vars"] = .array([.object(fields)])
                }
            } else {
                try combine(fields, at: prefix, into: &object)
            }
        }
        try CodexUserMCPImportValidation.validate(object)
    }

    private static func insert(_ value: CodexUserMCPImportValidation.Value, at path: [String], into object: inout [String: CodexUserMCPImportValidation.Value]) throws {
        guard let key = path.first else { throw Failure.unsupportedConfiguration }
        if path.count == 1 {
            guard object[key] == nil else { throw Failure.unsupportedConfiguration }
            object[key] = value
        } else {
            var child: [String: CodexUserMCPImportValidation.Value] = [:]
            if let existing = object[key] {
                guard case let .object(fields) = existing else { throw Failure.unsupportedConfiguration }
                child = fields
            }
            try insert(value, at: Array(path.dropFirst()), into: &child)
            object[key] = .object(child)
        }
    }

    private static func combine(_ fields: [String: CodexUserMCPImportValidation.Value], at path: [String], into object: inout [String: CodexUserMCPImportValidation.Value]) throws {
        if let key = path.first {
            var child: [String: CodexUserMCPImportValidation.Value] = [:]
            if let existing = object[key] {
                guard case let .object(values) = existing else { throw CodexUserMCPImportValidation.InvalidKey(path: path) }
                child = values
            }
            try combine(fields, at: Array(path.dropFirst()), into: &child)
            object[key] = .object(child)
        } else {
            for (key, value) in fields {
                guard object[key] == nil else { throw CodexUserMCPImportValidation.InvalidKey(path: [key]) }
                object[key] = value
            }
        }
    }

    /// The caller holds the same lock as all other managed-config writers.
    static func sourceConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directory: URL = if raw.isEmpty { home.appendingPathComponent(".codex") }
        else if raw == "~" { home }
        else if raw.hasPrefix("~/") { home.appendingPathComponent(String(raw.dropFirst(2))) }
        else { URL(fileURLWithPath: raw, isDirectory: true) }
        return directory.appendingPathComponent("config.toml")
    }

    /// Read-only discovery used by Settings. Only names and redacted diagnostics leave this API.
    static func pendingSummary(sourceURL: URL, destinationURL: URL) throws -> String? {
        let result = try merge(source: read(sourceURL, missingAllowed: true, followSymlinks: true) ?? "", destination: read(destinationURL, missingAllowed: true) ?? "")
        guard result.importedCount > 0 || !result.skipped.isEmpty else { return nil }
        return "User Codex MCP servers are not automatically shared with Agent Mode. Available to import: " + result.summary
    }

    static func importFile(sourceURL: URL, destinationURL: URL, resetPermissions: ([String]) throws -> Void) throws -> Result {
        let parent = destinationURL.deletingLastPathComponent().standardizedFileURL
        var parentMetadata = stat()
        guard parent == parent.resolvingSymlinksInPath(),
              lstat(parent.path, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_uid == getuid(),
              parentMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw Failure.unreadableFile }
        guard sourceURL.resolvingSymlinksInPath() != destinationURL.resolvingSymlinksInPath() else {
            throw Failure.unreadableFile
        }
        let source = try read(sourceURL, missingAllowed: false, followSymlinks: true)
        let previous = try read(destinationURL, missingAllowed: true)
        let result = try merge(source: source ?? "", destination: previous ?? "")
        guard result.importedCount > 0 else { return result }
        guard result.content.utf8.count <= maximumBytes else { throw Failure.unreadableFile }
        // A fresh private inode avoids a world-readable credential copy, including during replacement.
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(".mcp-import-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Failure.writeFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw Failure.writeFailed }
            try handle.write(contentsOf: Data(result.content.utf8))
            try handle.synchronize()
        } catch {
            throw Failure.writeFailed
        }
        guard try read(destinationURL, missingAllowed: true) == previous else { throw Failure.destinationChanged }
        // Reset stale selections before publishing new definitions. Failure is conservative:
        // no definition becomes available unless its disabled permission was persisted.
        try resetPermissions(result.importedNames)
        guard rename(temporary.path, destinationURL.path) == 0 else { throw Failure.writeFailed }
        return result
    }

    private static func read(_ url: URL, missingAllowed: Bool, followSymlinks: Bool = false) throws -> String? {
        let descriptor = open(url.path, O_RDONLY | (followSymlinks ? 0 : O_NOFOLLOW) | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if missingAllowed, errno == ENOENT { return nil }
            throw Failure.unreadableFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= maximumBytes else { throw Failure.unreadableFile }
        do {
            var data = Data()
            while data.count <= maximumBytes {
                let chunk = try handle.read(upToCount: min(65536, maximumBytes + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count <= maximumBytes, let content = String(data: data, encoding: .utf8) else {
                throw Failure.unreadableFile
            }
            return content
        } catch {
            throw Failure.unreadableFile
        }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Lexical state matters: apparent headers inside multiline strings/arrays are only values.
    /// Copy complete table bodies, not selected lines from arbitrary user configuration.
    private static func sections(in content: String, tolerant: Bool = false) throws -> ([Section], [String]) {
        var result = [Section(path: [], header: "", lines: [])]
        var issues: [String] = []
        var lexer = ValueLexer()
        for (index, originalLine) in content.components(separatedBy: "\n").enumerated() {
            var line = originalLine.hasSuffix("\r") ? String(originalLine.dropLast()) : originalLine
            if index == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            let text = line.trimmingCharacters(in: .whitespaces)
            let startsHeader = lexer.isAtTopLevel && text.hasPrefix("[")
            do {
                if startsHeader {
                    var headerLexer = ValueLexer()
                    try headerLexer.consume(line)
                    guard headerLexer.isAtTopLevel else { throw Failure.unsupportedConfiguration }
                    guard let header = CodexIntegrationConfiguration.importTableHeader(line) else {
                        throw Failure.unsupportedConfiguration
                    }
                    if header.path.first == "mcp_servers", header.isArray, header.path.count <= 2 { throw Failure.unsupportedConfiguration }
                    result.append(Section(path: header.path, header: line, lines: [], isArray: header.isArray))
                    continue
                }
                if lexer.isAtTopLevel,
                   let assignment = CodexIntegrationConfiguration.importAssignment(line),
                   result.last?.path.isEmpty == true, assignment.path.first == "mcp_servers"
                {
                    throw Failure.unsupportedConfiguration
                }
                if result.last?.path == ["mcp_servers"], !text.isEmpty, !text.hasPrefix("#") {
                    throw Failure.unsupportedConfiguration
                }
                // The managed-config repairer is line-oriented. Do not import value text that it
                // could later mistake for a real table and mutate outside the intended scope.
                if !lexer.isAtTopLevel, result.last?.path.first == "mcp_servers",
                   CodexIntegrationConfiguration.importTableHeader(line) != nil
                {
                    if tolerant { result[result.count - 1].invalid = true } else { throw Failure.unsupportedConfiguration }
                }
                try lexer.consume(line)
                result[result.count - 1].lines.append(line)
            } catch {
                guard tolerant else { throw error }
                let possibleRoot = String(text.drop(while: { $0 == "[" }).split(separator: ".", maxSplits: 1).first ?? "")
                let isMCPHeader = startsHeader && CodexIntegrationConfiguration.importAssignment(possibleRoot + " = false")?.path == ["mcp_servers"]
                if !startsHeader || isMCPHeader { result[result.count - 1].invalid = true }
                // Never echo the line: it may contain credentials. A line number identifies an
                // unparseable unrelated section without guessing at its quoted contents.
                issues.append("section at line \(index + 1): invalid TOML")
                lexer = ValueLexer()
                // A malformed header cannot attach its body to the previous valid server.
                if startsHeader { result.append(Section(path: [], header: "", lines: [], invalid: true)) }
            }
        }
        if !lexer.isAtTopLevel {
            guard tolerant else { throw Failure.unsupportedConfiguration }
            result[result.count - 1].invalid = true
            let path = result.last?.path.map(\.debugDescription).joined(separator: ".") ?? "root"
            issues.append("section \(path): incomplete TOML")
        }
        return (result, issues)
    }

    private struct ValueLexer {
        var quote: Character?
        var multiline = false
        var escaped = false
        var brackets: [Character] = []

        var isAtTopLevel: Bool {
            quote == nil && brackets.isEmpty
        }

        mutating func consume(_ line: String) throws {
            let characters = Array(line)
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if let active = quote {
                    if active == "\"", escaped {
                        escaped = false
                    } else if active == "\"", character == "\\" {
                        escaped = true
                    } else if character == active {
                        if multiline {
                            var end = index
                            while end < characters.count, characters[end] == active {
                                end += 1
                            }
                            if end - index >= 3 {
                                guard end - index <= 5 else { throw Failure.unsupportedConfiguration }
                                quote = nil
                                multiline = false
                            }
                            index = end
                            continue
                        }
                        quote = nil
                    }
                } else if character.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
                          character != " ", character != "\t"
                {
                    // TOML structural whitespace is ASCII space/tab, not Foundation's broader set.
                    throw Failure.unsupportedConfiguration
                } else if character == "#" {
                    break
                } else if character == "\"" || character == "'" {
                    quote = character
                    if index + 2 < characters.count, characters[index + 1] == character, characters[index + 2] == character {
                        multiline = true
                        index += 2
                    }
                } else if character == "[" || character == "{" {
                    brackets.append(character)
                } else if character == "]" || character == "}" {
                    guard brackets.popLast() == (character == "]" ? "[" : "{") else {
                        throw Failure.unsupportedConfiguration
                    }
                }
                index += 1
            }
            guard quote == nil || multiline else { throw Failure.unsupportedConfiguration }
            escaped = false
        }
    }
}
