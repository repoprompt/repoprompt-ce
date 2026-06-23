package enum StoredSelectionSliceMutation {
    package static func rebasedSelection(
        _ selection: StoredSelection,
        for fullPath: String,
        transform: ([LineRange]) -> [LineRange]
    ) -> StoredSelection? {
        guard let standardizedFullPath = StoredSelectionPathNormalization.standardizedPath(fullPath) else {
            return nil
        }

        let normalizedSlices = StoredSelectionPathNormalization.standardizedSlices(selection.slices)
        guard let existingRanges = normalizedSlices[standardizedFullPath] else {
            return nil
        }

        let nextRanges = SliceRangeMath.normalize(transform(existingRanges))
        var nextSlices = normalizedSlices
        if nextRanges.isEmpty {
            nextSlices.removeValue(forKey: standardizedFullPath)
        } else {
            nextSlices[standardizedFullPath] = nextRanges
        }

        guard nextSlices != selection.slices else { return nil }
        return StoredSelection(
            selectedPaths: selection.selectedPaths,
            autoCodemapPaths: selection.autoCodemapPaths,
            slices: nextSlices,
            codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }
}
