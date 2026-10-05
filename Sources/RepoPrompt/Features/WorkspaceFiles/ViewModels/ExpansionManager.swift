import RepoPromptFileSystem

// File: RepoPrompt/ViewModels/ExpansionManager.swift
import Combine
import Foundation
import SwiftUI

@MainActor
class ExpansionManager: ObservableObject {
    @Published private var expandedFolderIDs: Set<UUID> = []

    /// Maps folder IDs to relative paths for persistence
    private var folderIDToRelativePath: [UUID: String] = [:]

    /// Track work by root folder ID
    private var pendingWorkByRoot: [UUID: [(UUID, Bool)]] = [:]

    /// Queue of root folders to process in order
    private var rootFolderQueue: [UUID] = []

    /// Map of tasks by root folder ID
    private var expansionTasks: [UUID: Task<Void, Never>] = [:]

    /// Current active root folder being processed
    private var activeRootFolder: UUID?

    private let batchSize = 200 // Number of folders to process in one batch
    private let batchDelay: UInt64 = 5_000_000 // 5ms delay between batches

    // MARK: - Basic expansion operations

    func isExpanded(_ folderID: UUID) -> Bool {
        expandedFolderIDs.contains(folderID)
    }

    @MainActor
    func setExpanded(_ folderID: UUID, expanded: Bool) {
        // Only post notification if the state actually changes
        let wasExpanded = expandedFolderIDs.contains(folderID)
        if wasExpanded != expanded {
            // Update internal state
            var workingSet = expandedFolderIDs
            if expanded {
                workingSet.insert(folderID)
            } else {
                workingSet.remove(folderID)
            }
            expandedFolderIDs = workingSet
        }
    }

    @MainActor
    func toggleExpanded(_ folderID: UUID) {
        let newIsExpanded = !isExpanded(folderID)
        setExpanded(folderID, expanded: newIsExpanded)
        // No need to post notification here since setExpanded already does it
    }

    // MARK: - Folder path registration

    func registerFolder(id: UUID, relativePath: String) {
        folderIDToRelativePath[id] = relativePath
    }

    func unregisterFolder(id: UUID) {
        // Cancel all tasks when any folder is unregistered
        cancelAllTasks()

        folderIDToRelativePath.removeValue(forKey: id)
        var workingSet = expandedFolderIDs
        workingSet.remove(id)
        expandedFolderIDs = workingSet
    }

    func unregisterAllFolders() {
        cancelAllTasks()
        folderIDToRelativePath.removeAll()
        expandedFolderIDs = []
    }

    // MARK: - Staggered recursive operations

    func expandRecursively(_ folder: FolderViewModel) {
        let rootID = folder.id

        // Cancel existing tasks for this root folder
        cancelTask(for: rootID)

        var workItems: [(UUID, Bool)] = []

        // Collect all folders to expand
        var stack = [folder]
        while let current = stack.popLast() {
            workItems.append((current.id, true))

            for child in current.children {
                if case let .folder(subFolder) = child {
                    stack.append(subFolder)
                }
            }
        }

        // Store the work for this root folder
        pendingWorkByRoot[rootID] = workItems

        // Add to the queue and start processing if not already running
        enqueueRootFolder(rootID)
    }

    func collapseRecursively(_ folder: FolderViewModel) {
        let rootID = folder.id

        // Cancel existing tasks for this root folder
        cancelTask(for: rootID)

        var workItems: [(UUID, Bool)] = []

        // Collect all folders to collapse
        var stack = [folder]
        while let current = stack.popLast() {
            workItems.append((current.id, false))

            for child in current.children {
                if case let .folder(subFolder) = child {
                    stack.append(subFolder)
                }
            }
        }

        // Store the work for this root folder
        pendingWorkByRoot[rootID] = workItems

        // Add to the queue and start processing if not already running
        enqueueRootFolder(rootID)
    }

    private func enqueueRootFolder(_ rootID: UUID) {
        // Check if this root folder is already in the queue
        if !rootFolderQueue.contains(rootID) {
            rootFolderQueue.append(rootID)
        }

        // Start processing if not already running
        if activeRootFolder == nil {
            processNextRootFolder()
        }
    }

    private func processNextRootFolder() {
        guard activeRootFolder == nil, !rootFolderQueue.isEmpty else {
            return
        }

        // Get the next root folder ID
        let rootID = rootFolderQueue.removeFirst()
        activeRootFolder = rootID

        // Process the pending work for this root folder
        guard let workItems = pendingWorkByRoot[rootID] else {
            // No work to do, move to the next one
            activeRootFolder = nil
            processNextRootFolder()
            return
        }

        // Create a task for this root folder
        expansionTasks[rootID] = Task {
            var remainingWork = workItems

            while !remainingWork.isEmpty, !Task.isCancelled {
                // Process a batch of folders
                let batchCount = min(batchSize, remainingWork.count)
                let batch = Array(remainingWork.prefix(batchCount))
                remainingWork.removeFirst(batchCount)

                // Apply the batch update
                var workingSet = expandedFolderIDs
                for (folderID, shouldExpand) in batch {
                    if shouldExpand {
                        workingSet.insert(folderID)
                    } else {
                        workingSet.remove(folderID)
                    }
                }
                expandedFolderIDs = workingSet

                // Wait a bit to allow UI to breathe
                if !remainingWork.isEmpty, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: batchDelay)
                }
            }

            // Clean up
            pendingWorkByRoot.removeValue(forKey: rootID)
            expansionTasks.removeValue(forKey: rootID)
            activeRootFolder = nil

            // Process the next root folder in the queue
            processNextRootFolder()
        }
    }

    private func cancelTask(for rootID: UUID) {
        // Cancel the task for this root folder
        expansionTasks[rootID]?.cancel()
        expansionTasks.removeValue(forKey: rootID)

        // Remove pending work
        pendingWorkByRoot.removeValue(forKey: rootID)

        // Remove from queue
        if let index = rootFolderQueue.firstIndex(of: rootID) {
            rootFolderQueue.remove(at: index)
        }

        // Reset active root folder if it was this one
        if activeRootFolder == rootID {
            activeRootFolder = nil
            processNextRootFolder()
        }
    }

    private func cancelAllTasks() {
        // Cancel all expansion tasks
        for (_, task) in expansionTasks {
            task.cancel()
        }

        // Clear all tracking structures
        expansionTasks.removeAll()
        pendingWorkByRoot.removeAll()
        rootFolderQueue.removeAll()
        activeRootFolder = nil
    }

    // MARK: - State persistence

    /// Get all expanded folder paths for saving state
    func getExpandedFolderPaths() -> [String] {
        expandedFolderIDs.compactMap { folderIDToRelativePath[$0] }
    }

    /// Restore expansion state from paths
    func restoreFromPaths(_ paths: [String], resolvePathFn: (String) -> FolderViewModel?) {
        cancelAllTasks()

        // For large restores, use the staggered approach
        if paths.count > batchSize {
            var workItems: [(UUID, Bool)] = []

            for path in paths {
                if let folderVM = resolvePathFn(path) {
                    workItems.append((folderVM.id, true))
                }
            }

            // Create a special task ID for restore operation
            let restoreTaskID = UUID()
            pendingWorkByRoot[restoreTaskID] = workItems
            enqueueRootFolder(restoreTaskID)
        } else {
            // For small restores, apply immediately
            var workingSet = expandedFolderIDs
            for path in paths {
                if let folderVM = resolvePathFn(path) {
                    workingSet.insert(folderVM.id)
                }
            }
            expandedFolderIDs = workingSet
        }
    }

    /// Register entire folder hierarchy recursively
    func registerFolderHierarchy(_ folder: FolderViewModel) {
        registerFolder(id: folder.id, relativePath: folder.relativePath)

        for child in folder.children {
            if case let .folder(subFolder) = child {
                registerFolderHierarchy(subFolder)
            }
        }
    }
}
