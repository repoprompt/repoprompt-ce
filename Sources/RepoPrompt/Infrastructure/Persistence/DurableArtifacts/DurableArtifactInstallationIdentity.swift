import CryptoKit
import Foundation

struct DurableArtifactCommonDirectoryIdentity: Hashable {
    let resolvedPathBytes: Data
    let device: UInt64
    let inode: UInt64
}

struct WorkspaceDurableRepositoryNamespace: Hashable, CustomStringConvertible {
    let digest: DurableArtifactDigest

    var description: String {
        digest.hex
    }
}

final class DurableArtifactInstallationIdentity: @unchecked Sendable {
    private let layout: DurableArtifactLayout
    private let hooks: DurableArtifactStoreHooks
    private let cacheLock = NSLock()
    private var cachedSalt: Data?

    init(layout: DurableArtifactLayout, hooks: DurableArtifactStoreHooks) {
        self.layout = layout
        self.hooks = hooks
    }

    func repositoryNamespace(
        for commonDirectory: DurableArtifactCommonDirectoryIdentity
    ) throws -> WorkspaceDurableRepositoryNamespace {
        let salt = try installationSalt()
        var writer = DurableArtifactBinaryWriter()
        writer.append(Data("workspace-durable-repository-namespace-v1".utf8))
        writer.append(UInt64(commonDirectory.resolvedPathBytes.count))
        writer.append(commonDirectory.resolvedPathBytes)
        writer.append(commonDirectory.device)
        writer.append(commonDirectory.inode)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: writer.data,
            using: SymmetricKey(data: salt)
        )
        return try WorkspaceDurableRepositoryNamespace(
            digest: DurableArtifactDigest(bytes: Data(authentication))
        )
    }

    private func installationSalt() throws -> Data {
        cacheLock.lock()
        if let cachedSalt {
            cacheLock.unlock()
            return cachedSalt
        }
        cacheLock.unlock()

        let layoutLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.root,
            name: ".layout.lock",
            exclusive: true,
            nonBlocking: false
        )!
        defer { layoutLock.close() }
        try DurableArtifactSecureIO.validateDirectoryPath(layout.root, parent: layout.parent, name: layout.rootName)
        let salt = try loadOrCreateSalt()
        cacheLock.lock()
        cachedSalt = salt
        cacheLock.unlock()
        return salt
    }

    private func loadOrCreateSalt() throws -> Data {
        try DurableArtifactSecureIO.forEachEntry(in: layout.root) { name in
            guard name.hasPrefix(".salt.tmp.") else { return }
            guard let abandoned = try DurableArtifactSecureIO.openRegularFile(parent: layout.root, name: name) else {
                throw DurableArtifactStoreError.insecureEntry
            }
            defer { abandoned.0.close() }
            _ = try DurableArtifactSecureIO.removeIfSame(
                parent: layout.root,
                name: name,
                descriptor: abandoned.0.rawValue,
                identity: abandoned.1
            )
        }
        if let opened = try DurableArtifactSecureIO.openRegularFile(parent: layout.root, name: "installation.salt") {
            defer { opened.0.close() }
            return try validateSalt(descriptor: opened.0.rawValue, identity: opened.1, name: "installation.salt")
        }

        let temporaryName = ".salt.tmp.\(hooks.token())"
        let temporary = try DurableArtifactSecureIO.createExclusiveFile(parent: layout.root, name: temporaryName)
        var identity: DurableArtifactFileIdentity? = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: temporary.rawValue,
            parent: layout.root,
            name: temporaryName
        )
        var preserve = false
        defer {
            if !preserve,
               let current = try? DurableArtifactSecureIO.validateRegularFile(
                   descriptor: temporary.rawValue,
                   parent: layout.root,
                   name: temporaryName
               )
            {
                _ = try? DurableArtifactSecureIO.removeIfSame(
                    parent: layout.root,
                    name: temporaryName,
                    descriptor: temporary.rawValue,
                    identity: current
                )
            }
            temporary.close()
        }
        do {
            let salt = try hooks.randomBytes(32)
            guard salt.count == 32 else { throw DurableArtifactStoreError.invalidFraming }
            try DurableArtifactSecureIO.writeAll(temporary.rawValue, data: salt)
            try DurableArtifactSecureIO.synchronize(temporary.rawValue, operation: "salt-file-sync")
            identity = try DurableArtifactSecureIO.validateRegularFile(
                descriptor: temporary.rawValue,
                parent: layout.root,
                name: temporaryName
            )
            _ = try validateSalt(descriptor: temporary.rawValue, identity: identity!, name: temporaryName)
            try hooks.crash(.afterSaltFileSync)
            if let installed = try DurableArtifactSecureIO.installValidatedDescriptorNoReplace(
                sourceDescriptor: temporary.rawValue,
                sourceIdentity: identity!,
                destinationParent: layout.root,
                destinationName: "installation.salt"
            ) {
                defer { installed.0.close() }
                let installedSalt = try validateSalt(
                    descriptor: installed.0.rawValue,
                    identity: installed.1,
                    name: "installation.salt"
                )
                guard installedSalt == salt else { throw DurableArtifactStoreError.insecureEntry }
                try hooks.crash(.afterSaltRename)
                try DurableArtifactSecureIO.synchronize(layout.root.descriptor.rawValue, operation: "salt-directory-sync")
                return salt
            }
            guard let winner = try DurableArtifactSecureIO.openRegularFile(
                parent: layout.root,
                name: "installation.salt"
            ) else { throw DurableArtifactStoreError.insecureEntry }
            defer { winner.0.close() }
            return try validateSalt(
                descriptor: winner.0.rawValue,
                identity: winner.1,
                name: "installation.salt"
            )
        } catch let error as DurableArtifactStoreError {
            if case .simulatedCrash = error { preserve = true }
            throw error
        }
    }

    private func validateSalt(
        descriptor: Int32,
        identity: DurableArtifactFileIdentity,
        name: String
    ) throws -> Data {
        guard identity.size == 32 else { throw DurableArtifactStoreError.invalidFraming }
        let salt = try DurableArtifactSecureIO.preadExactly(descriptor, offset: 0, count: 32)
        guard try DurableArtifactSecureIO.identity(descriptor) == identity,
              try DurableArtifactSecureIO.pathIdentity(parent: layout.root, name: name) == identity
        else { throw DurableArtifactStoreError.insecureEntry }
        return salt
    }
}
