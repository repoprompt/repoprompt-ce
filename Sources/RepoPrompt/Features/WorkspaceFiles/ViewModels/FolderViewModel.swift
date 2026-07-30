import Combine
import Foundation

/// A folder in the file tree, with subfolders and files.
/// Keeps a single `children` array, sorted by the last known sort method.
/// Ensures stable ordering (folders first, then files).
class FolderViewModel: ObservableObject, Identifiable, FileSystemItemViewModel, Equatable, Hashable {
    private(set) var id: UUID
    let name: String
    let nameSortKey: String
    let relativePath: String
    let fullPath: String
    let standardizedFullPath: String
    let rootPath: String
    let isSystemRoot: Bool
    let fileExtension: String?

    @Published private(set) var isLoading: Bool

    /// Whether this folder is expanded in the UI.
    @Published var isExpanded: Bool = false

    /// Canonical storage for subfolders, kept sorted by `storageSortedBy`.
    @Published private(set) var subfolders: [FolderViewModel] = []
    /// Canonical storage for files, kept sorted by `storageSortedBy`.
    @Published private(set) var files: [FileViewModel] = []

    /// A single published array for UI consumption, sorted & stable (folders first).
    @Published private(set) var children: [FileSystemItemType] = []

    /// Whether we need to re-apply ordering to storage/children.
    /// Not published - UI doesn't read this; publishing causes unnecessary objectWillChange noise.
    private var sortDirty: Bool = false

    /// The user's last selected sort method (before any override).
    private var currentSortMethod: SortMethod = .nameAscending

    /// Tracks which (effective) sort method is currently applied to storage.
    private var storageSortedBy: SortMethod = .nameAscending

    /// Optional override for sorting, used by system roots like _git_data to always sort newest-first
    /// regardless of the user's selected sort method.
    private let sortMethodOverride: SortMethod?

    @Published private(set) var checkboxState: CheckboxState
    @Published private(set) var wasExpandedBySearch: Bool = false
    @Published private(set) var isValid: Bool = true
    @Published private(set) var modificationDate: Date

    private struct CheckboxMetrics {
        var checkedFiles: Int = 0
        var checkedSubfolders: Int = 0
        var mixedSubfolders: Int = 0
    }

    private var checkboxMetrics = CheckboxMetrics()

    let hierarchyLevel: Int
    weak var parent: FolderViewModel?

    #if DEBUG
        struct FolderDateSortMutationEvent: Equatable {
            enum ChildKind: Equatable {
                case file
                case folder
            }

            enum Outcome: Equatable {
                case alreadySorted
                case repositioned
                case resortedDirtyStorage
            }

            let parentID: UUID
            let childID: UUID
            let childKind: ChildKind
            let sortMethod: SortMethod
            let outcome: Outcome
        }

        @MainActor
        static var dateSortMutationObserverForTesting: ((FolderDateSortMutationEvent) -> Void)?
    #endif

    init(
        folder: Folder,
        rootPath: String,
        hierarchyLevel: Int = 0,
        isExpanded: Bool = false,
        sortMethod: SortMethod = .nameAscending,
        sortMethodOverride: SortMethod? = nil,
        relativePathOverride: String? = nil,
        isSystemRoot: Bool = false
    ) {
        id = folder.id
        name = folder.name
        nameSortKey = folder.name.lowercased()
        fileExtension = nil
        fullPath = folder.path
        let stdFull = StandardizedPath.absolute(folder.path)
        standardizedFullPath = stdFull
        let stdRoot = StandardizedPath.absolute(rootPath)
        relativePath = relativePathOverride.map(StandardizedPath.relative)
            ?? RelativePath.fromStandardized(
                standardizedAbsolutePath: stdFull,
                standardizedRootPath: stdRoot
            )
        modificationDate = folder.modificationDate
        isLoading = false
        checkboxState = .unchecked
        self.hierarchyLevel = hierarchyLevel
        self.rootPath = rootPath
        self.isSystemRoot = isSystemRoot
        self.isExpanded = isExpanded
        currentSortMethod = sortMethod
        self.sortMethodOverride = sortMethodOverride
        storageSortedBy = sortMethodOverride ?? sortMethod
    }

    /// Converts a full path to a relative path from the root.
    private static func calculateRelativePath(fullPath: String, rootPath: String) -> String {
        RelativePath.from(absolutePath: fullPath, rootPath: rootPath)
    }

    // MARK: - Public update methods (all @MainActor)

    /// Update modificationDate.
    @MainActor
    func setModificationDate(_ newValue: Date) {
        guard modificationDate != newValue else { return }
        modificationDate = newValue
        parent?.childDidUpdateModificationDate(self)
    }

    /// Whether the folder is currently loading children.
    @MainActor
    func setIsLoading(_ newValue: Bool) {
        isLoading = newValue
    }

    /// Mark this folder as needing a re-sort.
    @MainActor
    func markDirty() {
        sortDirty = true
    }

    /// Mark this folder AND all subfolders as needing a re-sort.
    @MainActor
    func markDirtyRecursively() {
        sortDirty = true
        for subfolder in subfolders {
            subfolder.markDirtyRecursively()
        }
    }

    enum SortRecursionPolicy {
        case all
        case expandedOnly
        case depth(Int)
    }

    /// Sort this folder's children if flagged dirty, and ensure subfolders are also sorted.
    /// Uses the given `method` for ordering, then updates `children` accordingly.
    /// - Parameter recomputeCheckbox: If `true`, recalculates checkbox state after sorting.
    ///   Defaults to `true` for backwards compatibility, but callers performing ordering-only
    ///   changes (e.g., user-initiated sort) should pass `false` to avoid unnecessary traversal.
    @MainActor
    func sortChildrenIfNeeded(
        _ method: SortMethod,
        recomputeCheckbox: Bool = true,
        recursion: SortRecursionPolicy = .all
    ) {
        let effective = effectiveSortMethod(requested: method)

        // Record the user's chosen sort method for future updates.
        currentSortMethod = method

        // First, recursively sort subfolders in case they're also dirty.
        switch recursion {
        case .all:
            for sub in subfolders {
                sub.sortChildrenIfNeeded(method, recomputeCheckbox: recomputeCheckbox, recursion: .all)
            }
        case .expandedOnly:
            for sub in subfolders where sub.isExpanded {
                sub.sortChildrenIfNeeded(method, recomputeCheckbox: recomputeCheckbox, recursion: .expandedOnly)
            }
        case let .depth(depth):
            if depth > 0 {
                for sub in subfolders {
                    sub.sortChildrenIfNeeded(method, recomputeCheckbox: recomputeCheckbox, recursion: .depth(depth - 1))
                }
            }
        }

        guard sortDirty || storageSortedBy != effective else { return }

        // Now apply ordering for this folder.
        applySort(requested: method)

        // Only recompute checkbox state if requested.
        if recomputeCheckbox {
            updateCheckboxState()
        }
    }

    /// Reposition a file when its modification date changes (only for date-based sorting).
    @MainActor
    func childDidUpdateModificationDate(_ file: FileViewModel) {
        let effective = effectiveSortMethod(requested: currentSortMethod)
        guard effective == .dateNewest || effective == .dateOldest else { return }

        // If storage isn't in a known sorted state, just re-apply ordering.
        guard !sortDirty, storageSortedBy == effective else {
            #if DEBUG
                emitDateSortMutationEvent(childID: file.id, childKind: .file, sortMethod: effective, outcome: .resortedDirtyStorage)
            #endif
            applySort(requested: currentSortMethod)
            return
        }

        guard let currentIndex = files.firstIndex(where: { $0.id == file.id }) else { return }
        guard !isElementAtSortedPosition(file, in: files, at: currentIndex, by: effective) else {
            #if DEBUG
                emitDateSortMutationEvent(childID: file.id, childKind: .file, sortMethod: effective, outcome: .alreadySorted)
            #endif
            return
        }
        #if DEBUG
            emitDateSortMutationEvent(childID: file.id, childKind: .file, sortMethod: effective, outcome: .repositioned)
        #endif

        files.remove(at: currentIndex)
        removeChildFromChildren(id: file.id, expectedIndex: subfolders.count + currentIndex)

        let newIndex = insertionIndex(of: file, in: files, by: effective)
        files.insert(file, at: newIndex)
        children.insert(.file(file), at: subfolders.count + newIndex)
    }

    /// Reposition a subfolder when its modification date changes (only for date-based sorting).
    @MainActor
    func childDidUpdateModificationDate(_ folder: FolderViewModel) {
        let effective = effectiveSortMethod(requested: currentSortMethod)
        guard effective == .dateNewest || effective == .dateOldest else { return }

        guard !sortDirty, storageSortedBy == effective else {
            #if DEBUG
                emitDateSortMutationEvent(childID: folder.id, childKind: .folder, sortMethod: effective, outcome: .resortedDirtyStorage)
            #endif
            applySort(requested: currentSortMethod)
            return
        }

        guard let currentIndex = subfolders.firstIndex(where: { $0.id == folder.id }) else { return }
        guard !isElementAtSortedPosition(folder, in: subfolders, at: currentIndex, by: effective) else {
            #if DEBUG
                emitDateSortMutationEvent(childID: folder.id, childKind: .folder, sortMethod: effective, outcome: .alreadySorted)
            #endif
            return
        }
        #if DEBUG
            emitDateSortMutationEvent(childID: folder.id, childKind: .folder, sortMethod: effective, outcome: .repositioned)
        #endif

        subfolders.remove(at: currentIndex)
        removeChildFromChildren(id: folder.id, expectedIndex: currentIndex)

        let newIndex = insertionIndex(of: folder, in: subfolders, by: effective)
        subfolders.insert(folder, at: newIndex)
        children.insert(.folder(folder), at: newIndex)
    }

    /// Whether the folder is still valid for display (not removed, etc).
    @MainActor
    func setIsValid(_ newValue: Bool) {
        isValid = newValue
    }

    /// Use only through `WorkspaceFilesViewModel` so ID-keyed bookkeeping is re-keyed with the identity change.
    @MainActor
    func adoptCanonicalIDForStoreCorrelation(_ canonicalID: UUID) {
        guard id != canonicalID else { return }
        objectWillChange.send()
        id = canonicalID
    }

    /// Add a subfolder, maintaining sorted storage and children.
    @MainActor
    func addSubfolder(_ folderVM: FolderViewModel) {
        folderVM.parent = self
        let effective = effectiveSortMethod(requested: currentSortMethod)
        if !sortDirty, storageSortedBy == effective {
            let idx = insertionIndex(of: folderVM, in: subfolders, by: effective)
            subfolders.insert(folderVM, at: idx)
            children.insert(.folder(folderVM), at: idx)
        } else {
            subfolders.append(folderVM)
            applySort(requested: currentSortMethod)
        }
        switch folderVM.checkboxState {
        case .checked:
            checkboxMetrics.checkedSubfolders += 1
        case .mixed:
            checkboxMetrics.mixedSubfolders += 1
        case .unchecked:
            break
        }
        updateCheckboxState()
    }

    /// Add a file, maintaining sorted storage and children.
    @MainActor
    func addFile(_ fileVM: FileViewModel) {
        fileVM.parentFolder = self
        let effective = effectiveSortMethod(requested: currentSortMethod)
        if !sortDirty, storageSortedBy == effective {
            let idx = insertionIndex(of: fileVM, in: files, by: effective)
            files.insert(fileVM, at: idx)
            children.insert(.file(fileVM), at: subfolders.count + idx)
        } else {
            files.append(fileVM)
            applySort(requested: currentSortMethod)
        }
        if fileVM.isChecked {
            checkboxMetrics.checkedFiles += 1
        }
        updateCheckboxState()
    }

    /// Remove a subfolder, maintaining sorted storage and children.
    @MainActor
    func removeSubfolder(_ folderVM: FolderViewModel) {
        guard let idx = subfolders.firstIndex(where: { $0.id == folderVM.id }) else { return }
        subfolders.remove(at: idx)
        folderVM.parent = nil
        let effective = effectiveSortMethod(requested: currentSortMethod)
        if !sortDirty, storageSortedBy == effective {
            removeChildFromChildren(id: folderVM.id, expectedIndex: idx)
        } else {
            applySort(requested: currentSortMethod)
        }
        switch folderVM.checkboxState {
        case .checked:
            checkboxMetrics.checkedSubfolders -= 1
        case .mixed:
            checkboxMetrics.mixedSubfolders -= 1
        case .unchecked:
            break
        }
        updateCheckboxState()
    }

    /// Remove a file, maintaining sorted storage and children.
    @MainActor
    func removeFile(_ fileVM: FileViewModel) {
        guard let idx = files.firstIndex(where: { $0.id == fileVM.id }) else { return }
        files.remove(at: idx)
        fileVM.parentFolder = nil
        let effective = effectiveSortMethod(requested: currentSortMethod)
        if !sortDirty, storageSortedBy == effective {
            removeChildFromChildren(id: fileVM.id, expectedIndex: subfolders.count + idx)
        } else {
            applySort(requested: currentSortMethod)
        }
        if fileVM.isChecked {
            checkboxMetrics.checkedFiles -= 1
        }
        updateCheckboxState()
    }

    @MainActor
    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    // MARK: - Legacy Support (used by existing code)

    @MainActor
    func setChildren(_ newChildren: [FileSystemItemType]) {
        // Clear existing arrays
        subfolders.removeAll()
        files.removeAll()

        // Separate subfolders and files
        for child in newChildren {
            switch child {
            case let .folder(folderVM):
                folderVM.parent = self
                subfolders.append(folderVM)
            case let .file(fileVM):
                fileVM.parentFolder = self
                files.append(fileVM)
            }
        }

        // Re-apply ordering with the current sort method
        applySort(requested: currentSortMethod)
        rebuildCheckboxMetricsFromChildren()
    }

    @MainActor
    func addChild(_ child: FileSystemItemType) {
        switch child {
        case let .folder(folderVM):
            addSubfolder(folderVM)
        case let .file(fileVM):
            addFile(fileVM)
        }
    }

    @MainActor
    func removeChild(_ child: FileSystemItemType) {
        switch child {
        case let .folder(folderVM):
            removeSubfolder(folderVM)
        case let .file(fileVM):
            removeFile(fileVM)
        }
    }

    @MainActor
    func addChild(_ child: FileSystemItemType, at index: Int) {
        let totalItems = subfolders.count + files.count
        guard index <= totalItems else { return }

        // Insert into the raw arrays first
        switch child {
        case let .folder(folderVM):
            folderVM.parent = self
            subfolders.insert(folderVM, at: min(index, subfolders.count))
            switch folderVM.checkboxState {
            case .checked:
                checkboxMetrics.checkedSubfolders += 1
            case .mixed:
                checkboxMetrics.mixedSubfolders += 1
            case .unchecked:
                break
            }
        case let .file(fileVM):
            fileVM.parentFolder = self
            // If index is bigger than subfolders.count, we might be trying to insert among the files
            let adjustedFileIndex = max(0, index - subfolders.count)
            files.insert(fileVM, at: min(adjustedFileIndex, files.count))
            if fileVM.isChecked {
                checkboxMetrics.checkedFiles += 1
            }
        }

        // Ensure sorted storage/children after legacy insertion.
        applySort(requested: currentSortMethod)
        updateCheckboxState()
    }

    @MainActor
    private func removeChild(at index: Int) {
        // Combine the raw arrays to find the correct target
        let allItems = subfolders.map { FileSystemItemType.folder($0) }
            + files.map { FileSystemItemType.file($0) }

        guard allItems.indices.contains(index) else { return }

        switch allItems[index] {
        case let .folder(folderVM):
            removeSubfolder(folderVM)
        case let .file(fileVM):
            removeFile(fileVM)
        }
    }

    /// Batch-add multiple children at once for performance.
    /// - Parameter recomputeCheckbox: If `false`, skips checkbox state update (useful during initial load).
    @MainActor
    func addChildrenBatch(_ newChildren: [FileSystemItemType], recomputeCheckbox: Bool = true) {
        addChildrenBatch(newChildren, options: .init(recomputeCheckbox: recomputeCheckbox))
    }

    struct AddChildrenBatchOptions {
        var recomputeCheckbox: Bool = true
        var ensureSorted: Bool = true
        var rebuildChildren: Bool = true
        var assumeAllUnchecked: Bool = false
    }

    @MainActor
    func addChildrenBatch(_ newChildren: [FileSystemItemType], options: AddChildrenBatchOptions) {
        guard !newChildren.isEmpty else { return }

        var newSubfolders: [FolderViewModel] = []
        var newFiles: [FileViewModel] = []
        newSubfolders.reserveCapacity(newChildren.count)
        newFiles.reserveCapacity(newChildren.count)

        var addedCheckedFiles = 0
        var addedCheckedSubfolders = 0
        var addedMixedSubfolders = 0
        for child in newChildren {
            switch child {
            case let .folder(folderVM):
                folderVM.parent = self
                newSubfolders.append(folderVM)
                if !options.assumeAllUnchecked {
                    switch folderVM.checkboxState {
                    case .checked:
                        addedCheckedSubfolders += 1
                    case .mixed:
                        addedMixedSubfolders += 1
                    case .unchecked:
                        break
                    }
                }
            case let .file(fileVM):
                fileVM.parentFolder = self
                newFiles.append(fileVM)
                if !options.assumeAllUnchecked, fileVM.isChecked {
                    addedCheckedFiles += 1
                }
            }
        }

        if !newSubfolders.isEmpty {
            subfolders.reserveCapacity(subfolders.count + newSubfolders.count)
            subfolders.append(contentsOf: newSubfolders)
        }
        if !newFiles.isEmpty {
            files.reserveCapacity(files.count + newFiles.count)
            files.append(contentsOf: newFiles)
        }

        if options.ensureSorted {
            applySort(requested: currentSortMethod)
        } else {
            sortDirty = true
            if options.rebuildChildren {
                rebuildChildrenFromStorage()
            }
        }

        checkboxMetrics.checkedFiles += addedCheckedFiles
        checkboxMetrics.checkedSubfolders += addedCheckedSubfolders
        checkboxMetrics.mixedSubfolders += addedMixedSubfolders
        if options.recomputeCheckbox {
            updateCheckboxState()
        }
    }

    /// Immediately override the checkbox state.
    @MainActor
    func updateCheckboxStateImmediately(newState: CheckboxState) {
        applyCheckboxState(newState)
    }

    /// Force a recalc of the existing checkbox state.
    @MainActor
    func updateCheckboxStateImmediately() {
        updateCheckboxState()
    }

    @MainActor
    func removeEmptyFoldersRecursively(
        isRoot: Bool,
        allowSorting: Bool = true
    ) -> [(fullPath: String, relativePath: String)] {
        var removedFolders: [(fullPath: String, relativePath: String)] = []

        // 1. Recurse into subfolders to remove their empties first.
        for subFolder in subfolders {
            let subRemoved = subFolder.removeEmptyFoldersRecursively(isRoot: false, allowSorting: allowSorting)
            removedFolders.append(contentsOf: subRemoved)
        }

        // 2. Remove any subfolder that is now empty (and clear its parent pointer).
        subfolders.removeAll { subFolder in
            if subFolder.subfolders.isEmpty, subFolder.files.isEmpty {
                removedFolders.append((subFolder.fullPath, subFolder.relativePath))
                subFolder.parent = nil
                return true
            }
            return false
        }

        // 3. Rebuild (and optionally re-sort) the children array.
        let effective = effectiveSortMethod(requested: currentSortMethod)
        if allowSorting {
            if sortDirty || storageSortedBy != effective {
                applySort(requested: currentSortMethod)
            } else {
                rebuildChildrenFromStorage()
            }
        } else {
            if sortDirty || storageSortedBy != effective {
                sortDirty = true
            }
            rebuildChildrenFromStorage()
        }

        // 4. Update the folder’s checkbox state.
        rebuildCheckboxMetricsFromChildren()

        return removedFolders
    }

    // MARK: - Private: Rebuild & Sort

    @MainActor
    private func effectiveSortMethod(requested: SortMethod) -> SortMethod {
        sortMethodOverride ?? requested
    }

    @MainActor
    private func sortStorage(by method: SortMethod) {
        subfolders.sort { compare($0, $1, by: method) }
        files.sort { compare($0, $1, by: method) }
    }

    #if DEBUG
        @MainActor
        private func emitDateSortMutationEvent(
            childID: UUID,
            childKind: FolderDateSortMutationEvent.ChildKind,
            sortMethod: SortMethod,
            outcome: FolderDateSortMutationEvent.Outcome
        ) {
            Self.dateSortMutationObserverForTesting?(
                FolderDateSortMutationEvent(
                    parentID: id,
                    childID: childID,
                    childKind: childKind,
                    sortMethod: sortMethod,
                    outcome: outcome
                )
            )
        }
    #endif

    @MainActor
    private func rebuildChildrenFromStorage() {
        var rebuilt: [FileSystemItemType] = []
        rebuilt.reserveCapacity(subfolders.count + files.count)
        for folder in subfolders {
            rebuilt.append(.folder(folder))
        }
        for file in files {
            rebuilt.append(.file(file))
        }
        children = rebuilt
    }

    @MainActor
    private func applySort(requested: SortMethod) {
        let effective = effectiveSortMethod(requested: requested)
        sortStorage(by: effective)
        rebuildChildrenFromStorage()
        storageSortedBy = effective
        sortDirty = false
    }

    @MainActor
    private func isElementAtSortedPosition<T: FileSystemItemViewModel>(
        _ element: T,
        in items: [T],
        at index: Int,
        by method: SortMethod
    ) -> Bool {
        let isAfterPrevious = index == items.startIndex || !compare(element, items[index - 1], by: method)
        let isBeforeNext = index == items.index(before: items.endIndex) || !compare(items[index + 1], element, by: method)
        return isAfterPrevious && isBeforeNext
    }

    @MainActor
    private func removeChildFromChildren(id: UUID, expectedIndex: Int) {
        if children.indices.contains(expectedIndex), children[expectedIndex].id == id {
            children.remove(at: expectedIndex)
            return
        }
        if let idx = children.firstIndex(where: { $0.id == id }) {
            children.remove(at: idx)
        }
    }

    // MARK: - Checkbox State Calculation

    /// Recompute the checkboxState based on cached metrics.
    @MainActor
    private func updateCheckboxState() {
        applyCheckboxState(computeCheckboxStateFromMetrics())
    }

    @MainActor
    private func computeCheckboxStateFromMetrics() -> CheckboxState {
        if checkboxMetrics.mixedSubfolders > 0 {
            return .mixed
        }
        let totalCount = files.count + subfolders.count
        if totalCount == 0 {
            return .unchecked
        }
        let checkedCount = checkboxMetrics.checkedFiles + checkboxMetrics.checkedSubfolders
        if checkedCount == 0 {
            return .unchecked
        }
        if checkedCount == totalCount {
            return .checked
        }
        return .mixed
    }

    @MainActor
    private func applyCheckboxState(_ newState: CheckboxState) {
        guard checkboxState != newState else { return }
        let old = checkboxState
        checkboxState = newState
        parent?.childFolderCheckboxStateDidChange(from: old, to: newState)
    }

    @MainActor
    func childFolderCheckboxStateDidChange(from old: CheckboxState, to new: CheckboxState) {
        guard old != new else { return }
        switch old {
        case .checked:
            checkboxMetrics.checkedSubfolders -= 1
        case .mixed:
            checkboxMetrics.mixedSubfolders -= 1
        case .unchecked:
            break
        }
        switch new {
        case .checked:
            checkboxMetrics.checkedSubfolders += 1
        case .mixed:
            checkboxMetrics.mixedSubfolders += 1
        case .unchecked:
            break
        }
        applyCheckboxState(computeCheckboxStateFromMetrics())
    }

    @MainActor
    func childFileCheckboxDidChange(from old: Bool, to new: Bool) {
        guard old != new else { return }
        checkboxMetrics.checkedFiles += new ? 1 : -1
        applyCheckboxState(computeCheckboxStateFromMetrics())
    }

    @MainActor
    private func rebuildCheckboxMetricsFromChildren() {
        var checkedFiles = 0
        var checkedSubfolders = 0
        var mixedSubfolders = 0
        for file in files {
            if file.isChecked {
                checkedFiles += 1
            }
        }
        for subfolder in subfolders {
            switch subfolder.checkboxState {
            case .checked:
                checkedSubfolders += 1
            case .mixed:
                mixedSubfolders += 1
            case .unchecked:
                break
            }
        }
        checkboxMetrics.checkedFiles = checkedFiles
        checkboxMetrics.checkedSubfolders = checkedSubfolders
        checkboxMetrics.mixedSubfolders = mixedSubfolders
        applyCheckboxState(computeCheckboxStateFromMetrics())
    }

    // MARK: - Recursive Checkbox & Expand/Collapse

    /// Toggle this folder’s checkbox from checked→unchecked or vice versa, applying to entire subtree.
    @MainActor
    func toggleCheckedRecursive() {
        let newState: CheckboxState = switch checkboxState {
        case .unchecked:
            .checked
        case .checked, .mixed:
            .unchecked
        }
        setCheckboxStateOnSubtree(newValue: newState)
        bubbleCheckboxStateUp()
    }

    // ------------------------------------------------------------------
    // MARK: Mention support

    // ------------------------------------------------------------------

    /// Forces the entire subtree to the `.checked` state, regardless of its
    /// current mixed/unchecked status. Called when a user selects a folder
    /// via an "@" mention token.
    @MainActor
    func forceCheckRecursive() {
        // Re-use the existing private recursive setter.
        setCheckboxStateOnSubtree(newValue: .checked)
        bubbleCheckboxStateUp()
    }

    /// Recursively sets the entire subtree's checkboxes to the specified state.
    @MainActor
    private func setCheckboxStateOnSubtree(newValue: CheckboxState) {
        for file in files {
            file.setIsChecked(newValue == .checked)
        }
        for subFolder in subfolders {
            subFolder.setCheckboxStateOnSubtree(newValue: newValue)
        }
        updateCheckboxStateImmediately(newState: newValue)
    }

    /// Forces parent folders to recalc state after a checkbox change.
    @MainActor
    func bubbleCheckboxStateUp() {
        var current = parent
        var visited = Set<UUID>()
        while let folder = current {
            if !visited.insert(folder.id).inserted {
                break
            } // cycle detected
            folder.updateCheckboxStateImmediately()
            current = folder.parent
        }
    }

    /// Recursively expand this folder and all its subfolders
    @MainActor
    func expandRecursively(levelCount: Int = 0) {
        if levelCount >= 5 {
            return
        }

        // Expand this folder first (top-down)
        setExpanded(true)

        // Then expand all subfolders
        for subfolder in subfolders {
            subfolder.expandRecursively(levelCount: levelCount + 1)
        }
    }

    @MainActor
    func collapseRecursively() {
        for subfolder in subfolders {
            subfolder.collapseRecursively()
        }
        setExpanded(false)
    }

    /// Returns `true` if *this* folder isExpanded,
    /// and *every ancestor* up the chain isExpanded.
    func shouldExpandInOutline() -> Bool {
        guard isExpanded else { return false }
        return parent?.shouldExpandInOutline() ?? true
    }

    @MainActor
    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if expanded {
            sortChildrenIfNeeded(currentSortMethod, recomputeCheckbox: false, recursion: .depth(0))
        }
    }

    // MARK: - Equatable & Hashable

    static func == (lhs: FolderViewModel, rhs: FolderViewModel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum CheckboxState: Equatable {
    case checked
    case unchecked
    case mixed
}
