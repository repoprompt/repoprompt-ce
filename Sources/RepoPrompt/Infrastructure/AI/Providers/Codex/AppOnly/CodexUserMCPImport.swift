import Darwin
import Foundation

/// Explicit, additive snapshot import. Never imports the user's whole Codex configuration.
/// Existing entries and permission selections remain authoritative; no background resync occurs.
enum CodexUserMCPImport {
    struct Result {
        let content: String
        let importedCount: Int
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
                "MCP import could not read a regular UTF-8 configuration file (maximum 2 MiB). Symbolic links are not supported. No configuration was changed."
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
    }

    private static let maximumBytes = 2 * 1024 * 1024

    static func merge(source: String, destination: String) throws -> Result {
        let sourceSections = try sections(in: source)
        let destinationSections = try sections(in: destination)
        let occupied = Set(destinationSections.compactMap { section in
            section.path.first == "mcp_servers" && section.path.count >= 2 ? normalized(section.path[1]) : nil
        }).union([
            normalized(MCPIntegrationHelper.repoPromptMCPServerName),
            normalized(MCPIntegrationHelper.computerUseMCPServerName)
        ])
        let serverSections = sourceSections.filter { $0.path.first == "mcp_servers" && $0.path.count >= 2 }
        let grouped = Dictionary(grouping: serverSections, by: { $0.path[1] })
        let names = grouped.keys.sorted()
        guard Set(serverSections.map(\.path)).count == serverSections.count else {
            throw Failure.unsupportedConfiguration
        }
        // The permission store normalizes names. Do not create aliases with ambiguous selection state.
        guard names.allSatisfy({ !normalized($0).isEmpty }), Set(names.map(normalized)).count == names.count else {
            throw Failure.unsupportedConfiguration
        }
        var additions: [String] = []
        for name in names where !occupied.contains(normalized(name)) {
            let selected = grouped[name] ?? []
            let roots = selected.filter { $0.path.count == 2 }
            guard roots.count <= 1 else { throw Failure.unsupportedConfiguration }
            try validate(selected)
            var rootLines: [String] = []
            var lexer = ValueLexer()
            for line in roots.first?.lines ?? [] {
                let assignment = lexer.isAtTopLevel ? CodexIntegrationConfiguration.importAssignment(line) : nil
                try lexer.consume(line)
                if let assignment, assignment.path.first == "enabled" {
                    let value = assignment.value.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard assignment.path == ["enabled"], value == "true" || value == "false" else {
                        throw Failure.unsupportedConfiguration
                    }
                } else {
                    rootLines.append(line)
                }
            }
            // Keep subprocess startup disabled. Existing CE permission choices still apply per thread.
            let key = CodexIntegrationConfiguration.cliPathComponent(forNormalizedServerName: name)
            var rendered = ["[mcp_servers.\(key)]", "enabled = false"] + rootLines
            for section in selected where section.path.count > 2 {
                rendered.append(section.header)
                rendered += section.lines
            }
            additions.append(rendered.joined(separator: "\n"))
        }
        guard !additions.isEmpty else { return Result(content: destination, importedCount: 0) }
        let separator = destination.isEmpty || destination.hasSuffix("\n") ? "\n" : "\n\n"
        return Result(content: destination + separator + additions.joined(separator: "\n\n") + "\n", importedCount: additions.count)
    }

    /// Validate the supported MCP schema as well as syntax before appending anything. In particular,
    /// balanced delimiters alone would accept missing values, duplicate keys, and table/key conflicts.
    private static func validate(_ sections: [Section]) throws {
        let nested = Set(sections.filter { $0.path.count > 2 }.map { $0.path[2] })
        let maps: Set = ["env", "http_headers", "env_http_headers"]
        var rootKeys = Set<String>()
        for section in sections {
            guard ([section.header] + section.lines).allSatisfy({ line in
                line.unicodeScalars.allSatisfy { $0.value == 9 || ($0.value >= 32 && $0.value != 127) }
            }) else { throw Failure.unsupportedConfiguration }
            guard section.path.count <= 3,
                  section.path.count == 2 || maps.contains(section.path[2]) else { throw Failure.unsupportedConfiguration }
            var keys = Set<String>()
            var lexer = ValueLexer()
            var statement = ""
            for line in section.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if statement.isEmpty, trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                statement += (statement.isEmpty ? "" : "\n") + line
                try lexer.consume(line)
                guard lexer.isAtTopLevel else { continue }
                guard let assignment = CodexIntegrationConfiguration.importAssignment(statement),
                      assignment.path.count == 1, let key = assignment.path.first,
                      keys.insert(key).inserted else { throw Failure.unsupportedConfiguration }
                let kind: CodexUserMCPImportValidation.Kind
                if section.path.count == 2 {
                    guard !nested.contains(key), let expected = CodexUserMCPImportValidation.rootKinds[key] else {
                        throw Failure.unsupportedConfiguration
                    }
                    kind = expected
                    rootKeys.insert(key)
                } else {
                    kind = .string
                }
                try CodexUserMCPImportValidation.validate(assignment.value, as: kind)
                statement = ""
            }
            guard statement.isEmpty else { throw Failure.unsupportedConfiguration }
        }
        guard rootKeys.contains("command") != rootKeys.contains("url") else { throw Failure.unsupportedConfiguration }
    }

    /// The caller holds the same lock as all other managed-config writers.
    static func importFile(sourceURL: URL, destinationURL: URL) throws -> Result {
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
        let source = try read(sourceURL, missingAllowed: false)
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
        guard rename(temporary.path, destinationURL.path) == 0 else { throw Failure.writeFailed }
        return result
    }

    private static func read(_ url: URL, missingAllowed: Bool) throws -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
    private static func sections(in content: String) throws -> [Section] {
        var result = [Section(path: [], header: "", lines: [])]
        var lexer = ValueLexer()
        for (index, originalLine) in content.components(separatedBy: "\n").enumerated() {
            var line = originalLine.hasSuffix("\r") ? String(originalLine.dropLast()) : originalLine
            if index == 0, line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            let text = line.trimmingCharacters(in: .whitespaces)
            if lexer.isAtTopLevel, text.hasPrefix("[") {
                var headerLexer = ValueLexer()
                try headerLexer.consume(line)
                guard headerLexer.isAtTopLevel else { throw Failure.unsupportedConfiguration }
                guard let header = CodexIntegrationConfiguration.importTableHeader(line) else {
                    throw Failure.unsupportedConfiguration
                }
                if header.path.first == "mcp_servers", header.isArray { throw Failure.unsupportedConfiguration }
                result.append(Section(path: header.path, header: line, lines: []))
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
                throw Failure.unsupportedConfiguration
            }
            try lexer.consume(line)
            result[result.count - 1].lines.append(line)
        }
        guard lexer.isAtTopLevel else { throw Failure.unsupportedConfiguration }
        return result
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
