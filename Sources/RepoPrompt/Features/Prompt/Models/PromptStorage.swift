//
//  PromptStorage.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-21.
//

import Foundation

struct StoredPromptRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    /// Tracks whether the user has manually edited a built-in prompt.
    /// When true, auto-upgrades of built-in content are skipped.
    var isUserEdited: Bool

    init(id: UUID, title: String, content: String, isUserEdited: Bool = false) {
        self.id = id
        self.title = title
        self.content = content
        self.isUserEdited = isUserEdited
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        content = try container.decode(String.self, forKey: .content)
        isUserEdited = try container.decodeIfPresent(Bool.self, forKey: .isUserEdited) ?? false
    }

    static func == (lhs: StoredPromptRecord, rhs: StoredPromptRecord) -> Bool {
        lhs.id == rhs.id &&
            lhs.title == rhs.title &&
            lhs.content == rhs.content
    }
}

/// <summary>
/// Represents the external structure used for importing and exporting prompts,
/// without relying on our internal UUID.
/// </summary>
struct PromptExport: Codable, Equatable {
    let title: String
    let content: String
}

/// <summary>
/// Manages reading and writing the user's saved prompts as JSON
/// in the app's Application Support/com.pvncher.repoprompt directory,
/// using a static dispatch queue for safe, atomic operations.
/// </summary>
class PromptStorage {
    static let shared = PromptStorage()

    private let filename = "SavedPrompts.json"
    private let configuredFileURL: URL?

    /// This serial queue ensures file reads/writes are never interleaved.
    private static let queue = DispatchQueue(label: "com.pvncher.repoprompt.PromptStorageQueue")

    init(fileURL: URL? = nil) {
        configuredFileURL = fileURL
    }

    /// Compute the file URL in Application Support under com.pvncher.repoprompt.
    private var fileURL: URL {
        if let configuredFileURL {
            try? FileManager.default.createDirectory(
                at: configuredFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return configuredFileURL
        }

        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        // Create a subfolder "com.pvncher.repoprompt" if it doesn't exist
        let appSupportFolder = supportDir.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appSupportFolder,
            withIntermediateDirectories: true
        )

        return appSupportFolder.appendingPathComponent(filename)
    }

    /// <summary>
    /// Reads the user's saved prompts from the JSON file.
    /// Returns a Result containing either the loaded prompts or an error.
    /// Returns .success([]) if the file doesn't exist (first run scenario).
    /// Returns .failure(error) if the file exists but can't be read/decoded.
    /// </summary>
    func loadPrompts() -> Result<[StoredPromptRecord], Error> {
        var result: Result<[StoredPromptRecord], Error> = .success([])

        // Use a synchronous block so we can return the result directly
        Self.queue.sync {
            // Check if the file exists first
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                // First run - no prompts file exists yet, return empty array
                result = .success([])
                return
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let prompts = try JSONDecoder().decode([StoredPromptRecord].self, from: data)
                result = .success(prompts)
            } catch {
                // File exists but can't be read or decoded - this is an error!
                print("⚠️ ERROR: Failed to load prompts from \(fileURL.path): \(error)")
                print("⚠️ This could indicate file corruption or permissions issues.")
                print("⚠️ User prompts will NOT be overwritten to prevent data loss.")
                result = .failure(error)
            }
        }

        return result
    }

    /// <summary>
    /// Writes (overwrites) the user's prompts to the JSON file atomically.
    /// This version supports an optional callback that fires after success/failure.
    /// </summary>
    func savePrompts(
        _ prompts: [StoredPromptRecord],
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        Self.queue.async {
            let result = Result { try self.writePrompts(prompts) }
            if case let .failure(error) = result {
                print("Failed to write prompts: \(error)")
            }
            DispatchQueue.main.async {
                completion?(result)
            }
        }
    }

    func mutatePrompts<Value>(
        _ mutation: (inout [StoredPromptRecord]) -> (value: Value, shouldSave: Bool)
    ) -> Result<(value: Value, prompts: [StoredPromptRecord]), Error> {
        Self.queue.sync {
            Result {
                var prompts = try readPrompts()
                let result = mutation(&prompts)
                if result.shouldSave {
                    try writePrompts(prompts)
                }
                return (result.value, prompts)
            }
        }
    }

    private func readPrompts() throws -> [StoredPromptRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([StoredPromptRecord].self, from: data)
    }

    private func writePrompts(_ prompts: [StoredPromptRecord]) throws {
        let data = try JSONEncoder().encode(prompts)
        try data.write(to: fileURL, options: .atomicWrite)
    }
}

extension PromptStorage {
    /// <summary>
    /// Export our internal `StoredPromptRecord` array into an array of `PromptExport` for writing to disk.
    /// </summary>
    func exportPrompts(to url: URL, prompts: [StoredPromptRecord]) throws {
        let exports = prompts.map { PromptExport(title: $0.title, content: $0.content) }
        let data = try JSONEncoder().encode(exports)

        // Use atomic write
        try data.write(to: url, options: .atomicWrite)
    }

    /// <summary>
    /// Reads a JSON file from the specified URL and decodes it into an array of `PromptExport`.
    /// </summary>
    func loadExternalPrompts(from url: URL) throws -> [PromptExport] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PromptExport].self, from: data)
    }

    /// <summary>
    /// Given the array of existing `StoredPromptRecord` and newly loaded external `PromptExport`,
    /// convert the external prompts into new records, skipping duplicates.
    /// Returns a tuple: (merged array, count of new items).
    ///
    /// Duplicates are checked by matching (title, content).
    /// If a prompt with the same title + content already exists, we skip adding a new one.
    /// Otherwise, create a new record with a fresh UUID.
    /// </summary>
    func mergeExternalPrompts(
        current: [StoredPromptRecord],
        external: [PromptExport]
    ) -> (merged: [StoredPromptRecord], addedCount: Int) {
        var merged = current
        var addedCount = 0

        for item in external {
            // Check duplicates by (title, content)
            let duplicateExists = merged.contains(where: {
                $0.title == item.title && $0.content == item.content
            })

            if !duplicateExists {
                let newPrompt = StoredPromptRecord(
                    id: UUID(), // Always new ID
                    title: item.title,
                    content: item.content
                )
                merged.append(newPrompt)
                addedCount += 1
            }
        }
        return (merged, addedCount)
    }
}
