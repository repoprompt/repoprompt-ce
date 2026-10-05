import Foundation
import SystemPackage

package enum WorkspaceNativePathError: Error, Equatable {
    case emptyPath
    case embeddedNUL
    case absolutePathRequired
    case relativePathRequired
    case invalidFilename
    case escapesRoot
    case notWithinRoot
    case unsupportedTextEncoding
}

/// A presentation value. Its text must never be used to reconstruct filesystem identity.
package struct WorkspacePathDisplay: Equatable {
    package let text: String

    fileprivate init(text: String) {
        self.text = text
    }
}

/// Human search input is deliberately distinct from an exact native path.
package struct WorkspacePathSearchQuery: Equatable {
    package let searchText: String

    package init(userText: String) {
        searchText = userText
    }
}

/// Native user input with an explicitly supplied home-directory expansion policy.
/// Unlike WorkspaceExactFileInput, this does not interpret workspace root aliases.
package enum WorkspaceNativePathInput: Hashable {
    case absolute(WorkspaceAbsolutePath)
    case relative(WorkspaceRelativePath)

    package static func userText(_ text: String, homeDirectory: WorkspaceAbsolutePath) throws -> Self {
        if text == "~" { return .absolute(homeDirectory.requiringDirectory()) }
        if text.hasPrefix("/") { return try .absolute(WorkspaceAbsolutePath.nativeText(text)) }
        if text.hasPrefix("~/") {
            let suffix = String(text.dropFirst(2))
            if suffix.isEmpty { return .absolute(homeDirectory.requiringDirectory()) }
            return try .absolute(homeDirectory.appending(WorkspaceRelativePath.nativeText(suffix)))
        }
        return try .relative(WorkspaceRelativePath.nativeText(text))
    }

    package func utf8ForPlatform() throws -> String {
        switch self {
        case let .absolute(path): try path.utf8ForPlatform()
        case let .relative(path): try path.utf8ForPlatform()
        }
    }

    package func utf8ForWire() throws -> String {
        switch self {
        case let .absolute(path): try path.utf8ForWire()
        case let .relative(path): try path.utf8ForWire()
        }
    }
}

/// A directory's lexical native spelling. All roots address directories, so an
/// incoming trailing separator does not create a second root key. This is still
/// byte equality, not a claim about case-insensitive volumes or physical aliases.
package struct WorkspaceDirectoryPathKey: Hashable {
    private let path: FilePath

    fileprivate init(path: FilePath) {
        self.path = path
    }

    package func utf8ForWire() throws -> String {
        guard let text = String(validating: path) else { throw WorkspaceNativePathError.unsupportedTextEncoding }
        return text
    }
}

/// An absolute native path, not an authorization grant or a physical file identity.
/// FilePath normalizes separators; directory intent is retained separately. Dot
/// components, filename whitespace, Unicode, and case are never changed at ingress.
package struct WorkspaceAbsolutePath: Hashable, Codable {
    fileprivate let storage: WorkspaceNativePathStorage

    private init(storage: WorkspaceNativePathStorage) {
        self.storage = storage
    }

    package static func nativeText(_ text: String) throws -> Self {
        try nativeBytes(Array(text.utf8))
    }

    package static func nativeBytes(_ bytes: [UInt8]) throws -> Self {
        let storage = try WorkspaceNativePathStorage(bytes: bytes)
        guard storage.path.isAbsolute else { throw WorkspaceNativePathError.absolutePathRequired }
        return Self(storage: storage)
    }

    package var requiresDirectory: Bool {
        storage.requiresDirectory
    }

    package var display: WorkspacePathDisplay {
        storage.display
    }

    package var directoryKey: WorkspaceDirectoryPathKey {
        WorkspaceDirectoryPathKey(path: storage.path)
    }

    package func requiringDirectory() -> Self {
        Self(storage: WorkspaceNativePathStorage(path: storage.path, requiresDirectory: true))
    }

    /// Only a platform adapter may export this text for a String-only OS/catalog API.
    package func utf8ForPlatform() throws -> String {
        try storage.validatedUTF8()
    }

    /// The legacy wire contract is a Unicode string. Non-Unicode paths fail explicitly.
    package func utf8ForWire() throws -> String {
        try storage.validatedUTF8()
    }

    package func appending(_ relative: WorkspaceRelativePath) -> Self {
        Self(storage: WorkspaceNativePathStorage(
            path: storage.path.appending(relative.storage.path.components),
            requiresDirectory: relative.requiresDirectory
        ))
    }

    /// Component-aware lexical comparison. This does not resolve symlinks or grant access.
    package func isLexicallyWithin(_ root: Self) -> Bool {
        storage.path.lexicallyNormalized().starts(with: root.storage.path.lexicallyNormalized())
    }

    /// Removes a component prefix without resolving symlinks or collapsing dot components.
    /// A root itself has no nonempty relative file path and is rejected.
    package func relative(to root: Self) throws -> WorkspaceRelativePath {
        var relative = storage.path
        guard relative.removePrefix(root.storage.path) else { throw WorkspaceNativePathError.notWithinRoot }
        guard !relative.isEmpty else { throw WorkspaceNativePathError.emptyPath }
        return WorkspaceRelativePath(storage: WorkspaceNativePathStorage(
            path: relative,
            requiresDirectory: requiresDirectory
        ))
    }

    package init(from decoder: Decoder) throws {
        self = try Self.nativeText(decoder.singleValueContainer().decode(String.self))
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(utf8ForWire())
    }
}

/// A relative native path. A relative path may contain dot components; callers
/// needing a workspace-qualified input must invoke the explicit lexical policy.
package struct WorkspaceRelativePath: Hashable, Codable {
    fileprivate let storage: WorkspaceNativePathStorage

    fileprivate init(storage: WorkspaceNativePathStorage) {
        self.storage = storage
    }

    package static func nativeText(_ text: String) throws -> Self {
        try nativeBytes(Array(text.utf8))
    }

    package static func nativeBytes(_ bytes: [UInt8]) throws -> Self {
        let storage = try WorkspaceNativePathStorage(bytes: bytes)
        guard storage.path.root == nil else { throw WorkspaceNativePathError.relativePathRequired }
        return Self(storage: storage)
    }

    package var requiresDirectory: Bool {
        storage.requiresDirectory
    }

    package var display: WorkspacePathDisplay {
        storage.display
    }

    package func utf8ForPlatform() throws -> String {
        try storage.validatedUTF8()
    }

    package func utf8ForWire() throws -> String {
        try storage.validatedUTF8()
    }

    package func appending(_ filename: WorkspaceFilename) -> Self {
        Self(storage: WorkspaceNativePathStorage(
            path: storage.path.appending(filename.storage.path.components),
            requiresDirectory: false
        ))
    }

    package func appending(_ relative: Self) -> Self {
        Self(storage: WorkspaceNativePathStorage(
            path: storage.path.appending(relative.storage.path.components),
            requiresDirectory: relative.requiresDirectory
        ))
    }

    package var parent: Self? {
        let parentPath = storage.path.removingLastComponent()
        guard !parentPath.isEmpty else { return nil }
        return Self(storage: WorkspaceNativePathStorage(path: parentPath, requiresDirectory: true))
    }

    package var firstFilename: WorkspaceFilename? {
        guard let component = storage.path.components.first else { return nil }
        return WorkspaceFilename(regularComponent: component)
    }

    package var lastFilename: WorkspaceFilename? {
        guard let component = storage.path.lastComponent else { return nil }
        return WorkspaceFilename(regularComponent: component)
    }

    package func droppingFirstComponent() -> Self? {
        let components = storage.path.components.dropFirst()
        guard !components.isEmpty else { return nil }
        return Self(storage: WorkspaceNativePathStorage(
            path: FilePath().appending(components),
            requiresDirectory: requiresDirectory
        ))
    }

    /// Parent directories of a file target, deepest first. These are lexical
    /// candidates only; the caller must verify directory type and physical access.
    package var directoryPrefixes: [Self] {
        var prefixes: [Self] = []
        var candidate = parent
        while let directory = candidate {
            prefixes.append(directory)
            candidate = directory.parent
        }
        return prefixes
    }

    package func filenameComponents() throws -> [WorkspaceFilename] {
        try storage.path.components.map { component in
            guard let filename = WorkspaceFilename(regularComponent: component) else {
                throw WorkspaceNativePathError.invalidFilename
            }
            return filename
        }
    }

    /// Compatibility with the existing workspace-user-input grammar only. Native
    /// filesystem ingress must not call this: link/.. can have different physical meaning.
    package func lexicallyNormalizedForWorkspaceInput() throws -> Self {
        let normalized = storage.path.lexicallyNormalized()
        guard !normalized.isEmpty else { throw WorkspaceNativePathError.emptyPath }
        guard normalized.components.first?.kind != .parentDirectory else {
            throw WorkspaceNativePathError.escapesRoot
        }
        return Self(storage: WorkspaceNativePathStorage(
            path: normalized,
            requiresDirectory: requiresDirectory
        ))
    }

    package init(from decoder: Decoder) throws {
        self = try Self.nativeText(decoder.singleValueContainer().decode(String.self))
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(utf8ForWire())
    }
}

/// One literal native filename, validated before FilePath can normalize separators.
package struct WorkspaceFilename: Hashable, Codable {
    fileprivate let storage: WorkspaceNativePathStorage

    private init(storage: WorkspaceNativePathStorage) {
        self.storage = storage
    }

    fileprivate init?(regularComponent component: FilePath.Component) {
        guard component.kind == .regular else { return nil }
        storage = WorkspaceNativePathStorage(
            path: component.withPlatformString { FilePath(platformString: $0) },
            requiresDirectory: false
        )
    }

    package static func nativeText(_ text: String) throws -> Self {
        try nativeBytes(Array(text.utf8))
    }

    package static func nativeBytes(_ bytes: [UInt8]) throws -> Self {
        guard !bytes.isEmpty else { throw WorkspaceNativePathError.emptyPath }
        guard !bytes.contains(0) else { throw WorkspaceNativePathError.embeddedNUL }
        guard !bytes.contains(0x2F), bytes != [0x2E], bytes != [0x2E, 0x2E] else {
            throw WorkspaceNativePathError.invalidFilename
        }
        return try Self(storage: WorkspaceNativePathStorage(bytes: bytes))
    }

    package var display: WorkspacePathDisplay {
        storage.display
    }

    package func utf8ForPlatform() throws -> String {
        try storage.validatedUTF8()
    }

    package func utf8ForWire() throws -> String {
        try storage.validatedUTF8()
    }

    package init(from decoder: Decoder) throws {
        self = try Self.nativeText(decoder.singleValueContainer().decode(String.self))
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(utf8ForWire())
    }
}

private struct WorkspaceNativePathStorage: Hashable {
    let path: FilePath
    let requiresDirectory: Bool

    init(bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { throw WorkspaceNativePathError.emptyPath }
        guard !bytes.contains(0) else { throw WorkspaceNativePathError.embeddedNUL }
        path = FilePath(platformString: bytes.map { CChar(bitPattern: $0) } + [0])
        guard !path.isEmpty else { throw WorkspaceNativePathError.emptyPath }
        requiresDirectory = bytes.last == 0x2F || path.lastComponent?.kind == .currentDirectory
            || path.lastComponent?.kind == .parentDirectory
    }

    init(path: FilePath, requiresDirectory: Bool) {
        self.path = path
        self.requiresDirectory = requiresDirectory
    }

    func validatedUTF8() throws -> String {
        guard var text = String(validating: path) else { throw WorkspaceNativePathError.unsupportedTextEncoding }
        if requiresDirectory, !text.hasSuffix("/") { text.append("/") }
        return text
    }

    var display: WorkspacePathDisplay {
        var text = String(decoding: path)
        if requiresDirectory, !text.hasSuffix("/") { text.append("/") }
        return WorkspacePathDisplay(text: StandardizedPath.diagnosticEscaped(text))
    }
}
