import Foundation

/// Pure static helper for path matching logic without UI dependencies
enum PathMatcher {
    /// Controls whether debug logging is enabled for path matching operations
    static let isLoggingEnabled = false

    /// Fast ASCII-first probe: returns the lowercased ASCII byte of the first alphanumeric char, if any.
    /// Avoids per-scalar `String(...)`/`lowercased()` allocations in hot loops.
    @inline(__always)
    private static func firstAlnumLowercasedByte(_ s: some StringProtocol) -> UInt8? {
        for b in s.utf8 {
            // '0'..'9' or 'A'..'Z' or 'a'..'z'
            if b >= 0x30, b <= 0x39 { return b }
            if b >= 0x41, b <= 0x5A { return b &+ 32 }
            if b >= 0x61, b <= 0x7A { return b }
            // skip anything else (e.g., '_' '-')
        }
        return nil
    }

    // MARK: - Heap-safe similarity (Swift-only, bounded Levenshtein)

    //
    // IMPORTANT: We intentionally do NOT use String.similarity(to:) here.
    // That API calls into C (repo_similarity_score / levenshtein / dice),
    // which is a potential source of heap corruption.
    //
    // This implementation is:
    // - bounded (banded DP) for speed
    // - case-policy aware (caseSensitive parameter)
    // - separator-fold aware (treat '-' and '_' as optional)

    /// Small cap so we don't allocate huge temporary buffers on the stack.
    /// Path components should be short; if not, we fall back to a cheap equality check.
    private static let maxSimilarityByteLen = 256

    @inline(__always)
    private static func appendStandardizedRelativePath(rootPath: String, relativePath: String) -> String {
        guard !relativePath.isEmpty else { return rootPath }
        return rootPath.hasSuffix("/") ? rootPath + relativePath : rootPath + "/" + relativePath
    }

    @inline(__always)
    private static func containsParentTraversal(_ relativePath: String) -> Bool {
        relativePath == ".."
            || relativePath.hasPrefix("../")
            || relativePath.hasSuffix("/..")
            || relativePath.contains("/../")
    }

    @inline(__always)
    private static func standardizedLookupPath(rootPath: String, relativePath: String) -> String {
        let normalizedRelativePath = StandardizedPath.relative(relativePath)
        let joinedPath = appendStandardizedRelativePath(rootPath: rootPath, relativePath: normalizedRelativePath)
        guard containsParentTraversal(normalizedRelativePath) else {
            return joinedPath
        }
        return StandardizedPath.absolute(joinedPath)
    }

    @inline(__always)
    private static func similarityScoreMax(
        _ a: String,
        _ b: String,
        threshold: Double,
        caseSensitive: Bool
    ) -> Double {
        // Base + separator-folded (treat '-' and '_' as ignorable)
        let base = similarityScore(a, b, threshold: threshold, caseSensitive: caseSensitive, stripSeparators: false)
        let fold = similarityScore(a, b, threshold: threshold, caseSensitive: caseSensitive, stripSeparators: true)
        return max(base, fold)
    }

    @inline(__always)
    private static func similarityScore(
        _ a: String,
        _ b: String,
        threshold: Double,
        caseSensitive: Bool,
        stripSeparators: Bool
    ) -> Double {
        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        // Clamp internally to avoid negative maxDist math when callers pass > 1.0
        let t = min(max(threshold, 0.0), 1.0)

        // Fast ASCII/UTF-8 byte path (no heap allocations; uses bounded DP)
        let aByteCount = a.utf8.count
        let bByteCount = b.utf8.count
        let maxByteCount = max(aByteCount, bByteCount)

        if maxByteCount <= maxSimilarityByteLen {
            // Stack temp buffers
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: aByteCount) { aTmp in
                withUnsafeTemporaryAllocation(of: UInt8.self, capacity: bByteCount) { bTmp in
                    var aLen = 0
                    var bLen = 0

                    // Copy/lower/strip while validating ASCII (byte < 0x80)
                    for byte in a.utf8 {
                        if byte >= 0x80 { return unicodeSimilarityScore(a, b, threshold: t, caseSensitive: caseSensitive, stripSeparators: stripSeparators) }
                        if stripSeparators && (byte == 0x2D || byte == 0x5F) { continue } // '-' or '_'
                        aTmp[aLen] = caseSensitive ? byte : PathCharPolicy.toLowerASCII(byte)
                        aLen += 1
                    }
                    for byte in b.utf8 {
                        if byte >= 0x80 { return unicodeSimilarityScore(a, b, threshold: t, caseSensitive: caseSensitive, stripSeparators: stripSeparators) }
                        if stripSeparators && (byte == 0x2D || byte == 0x5F) { continue }
                        bTmp[bLen] = caseSensitive ? byte : PathCharPolicy.toLowerASCII(byte)
                        bLen += 1
                    }

                    let maxLen = max(aLen, bLen)
                    if maxLen == 0 { return 1.0 } // both became empty after stripping

                    // If threshold is 1.0, only exact matches can pass.
                    if t >= 1.0 {
                        if aLen != bLen { return 0.0 }
                        for i in 0 ..< aLen where aTmp[i] != bTmp[i] {
                            return 0.0
                        }
                        return 1.0
                    }

                    let maxDist = Int(ceil((1.0 - t) * Double(maxLen)))
                    let aBuf = UnsafeBufferPointer(start: aTmp.baseAddress, count: aLen)
                    let bBuf = UnsafeBufferPointer(start: bTmp.baseAddress, count: bLen)

                    let dist = levenshteinDistanceCapped(aBuf, bBuf, maxDist: maxDist)
                    if dist > maxDist { return 0.0 }
                    return 1.0 - Double(dist) / Double(maxLen)
                }
            }
        }

        // Too long: avoid expensive work; keep it deterministic and safe
        // (Path components shouldn't be this long; if they are, treat only exact equality as "similar".)
        return (caseSensitive ? (a == b) : (a.caseInsensitiveCompare(b) == .orderedSame)) ? 1.0 : 0.0
    }

    private static func unicodeSimilarityScore(
        _ a: String,
        _ b: String,
        threshold: Double,
        caseSensitive: Bool,
        stripSeparators: Bool
    ) -> Double {
        let t = min(max(threshold, 0.0), 1.0)

        let a0 = caseSensitive ? a : a.lowercased()
        let b0 = caseSensitive ? b : b.lowercased()

        var aScalars: [UInt32] = []
        var bScalars: [UInt32] = []
        aScalars.reserveCapacity(a0.unicodeScalars.count)
        bScalars.reserveCapacity(b0.unicodeScalars.count)

        for sc in a0.unicodeScalars {
            if stripSeparators, sc.value == 0x2D || sc.value == 0x5F { continue }
            aScalars.append(sc.value)
        }
        for sc in b0.unicodeScalars {
            if stripSeparators, sc.value == 0x2D || sc.value == 0x5F { continue }
            bScalars.append(sc.value)
        }

        let maxLen = max(aScalars.count, bScalars.count)
        if maxLen == 0 { return 1.0 }
        if t >= 1.0 { return aScalars == bScalars ? 1.0 : 0.0 }

        // Keep it bounded
        let maxDist = Int(ceil((1.0 - t) * Double(maxLen)))
        return aScalars.withUnsafeBufferPointer { aBuf in
            bScalars.withUnsafeBufferPointer { bBuf in
                let dist = levenshteinDistanceCapped(aBuf, bBuf, maxDist: maxDist)
                if dist > maxDist { return 0.0 }
                return 1.0 - Double(dist) / Double(maxLen)
            }
        }
    }

    @inline(__always)
    private static func levenshteinDistanceCapped<T: Equatable>(
        _ aIn: UnsafeBufferPointer<T>,
        _ bIn: UnsafeBufferPointer<T>,
        maxDist: Int
    ) -> Int {
        let big = maxDist + 1
        if maxDist < 0 { return big }

        var a = aIn
        var b = bIn

        if a.count == 0 { return b.count }
        if b.count == 0 { return a.count }

        // Ensure a is the shorter string
        if a.count > b.count {
            let tmp = a
            a = b
            b = tmp
        }

        let lenA = a.count
        let lenB = b.count

        if abs(lenA - lenB) > maxDist { return big }
        if maxDist == 0 {
            if lenA != lenB { return big }
            for i in 0 ..< lenA where a[i] != b[i] {
                return big
            }
            return 0
        }

        return withUnsafeTemporaryAllocation(of: Int.self, capacity: lenB + 1) { prev in
            withUnsafeTemporaryAllocation(of: Int.self, capacity: lenB + 1) { curr in
                // init to big
                for j in 0 ... lenB {
                    prev[j] = big
                    curr[j] = big
                }
                prev[0] = 0

                let hi0 = min(lenB, maxDist)
                if hi0 >= 1 {
                    for j in 1 ... hi0 {
                        prev[j] = j
                    }
                }

                for i in 1 ... lenA {
                    let jLo = max(1, i - maxDist)
                    let jHi = min(lenB, i + maxDist)

                    // reset curr
                    for j in 0 ... lenB {
                        curr[j] = big
                    }
                    if jLo == 1 { curr[0] = i }

                    var rowMin = big

                    for j in jLo ... jHi {
                        let ins = curr[j - 1] + 1
                        let del = prev[j] + 1
                        let sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                        let v = min(ins, del, sub)
                        curr[j] = v
                        if v < rowMin { rowMin = v }
                    }

                    if rowMin > maxDist { return big }

                    // swap prev/curr
                    for j in 0 ... lenB {
                        prev[j] = curr[j]
                    }
                }

                let dist = prev[lenB]
                return dist > maxDist ? big : dist
            }
        }
    }

    /// Bonus added to a candidate's score when its root contains at least one selected file
    private static let rootSelectionBonus: Double = 0.5

    /// Common helper: compute roots that own any selected file
    private static func rootsWithSelection(_ snapshot: PathMatchSnapshot) -> Set<String> {
        var set = Set<String>()
        for root in snapshot.rootFolders {
            if snapshot.selectedFileFullPaths.contains(where: { isUnder($0, root: root.fullPath) }) {
                set.insert(root.fullPath)
            }
        }
        return set
    }

    /// Root-alias matching: use canonical root.name first, then lastPathComponent as compatibility fallback.
    private static func aliasRootCandidates(for component: String, snapshot: PathMatchSnapshot) -> [FolderRecord] {
        let canonicalMatches = snapshot.rootFolders.filter {
            $0.name.caseInsensitiveCompare(component) == .orderedSame
        }
        if !canonicalMatches.isEmpty {
            return canonicalMatches
        }
        return snapshot.rootFolders.filter {
            (($0.fullPath as NSString).lastPathComponent).caseInsensitiveCompare(component) == .orderedSame
        }
    }

    // Absolute-path fallback tuning
    static let absoluteSuffixFallbackEnabled = true
    static let absSuffixMinComponents = 2
    static let absSuffixMaxComponents = 20

    static func locate(
        userPath: String,
        exactMatchOnly: Bool = false,
        snapshot: PathMatchSnapshot
    ) -> PathMatchLocation? {
        locate(
            userPath: userPath,
            options: PathLocateOptions(
                exactMatchOnly: exactMatchOnly,
                allowLeadingRootAliasTrim: true,
                allowHeadTrimAliases: true,
                allowAbsoluteSuffixFallback: !exactMatchOnly,
                useSelectedRootBias: true
            ),
            snapshot: snapshot
        )
    }

    /// Main entry point - equivalent to pathLocation
    static func locate(
        userPath: String,
        options: PathLocateOptions,
        snapshot: PathMatchSnapshot
    ) -> PathMatchLocation? {
        let exactMatchOnly = options.exactMatchOnly

        if Self.isLoggingEnabled {
            print("\n=== PathMatcher.locate ===\n- userPath: '\(userPath)'\n- exactMatchOnly: \(exactMatchOnly)")
        }

        // 0) Normalize & split
        // NEW: Preserve absolute paths to maintain root information in multi-root scenarios
        let raw = PathCharPolicy.foldHomoglyphsIfNeeded(
            userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !raw.isEmpty else { return nil }

        let trimmedPath = raw.hasPrefix("/") ? raw : normalizeUserInputPath(raw, snapshot: snapshot)
        let standardizedPath = StandardizedPath.absolute(trimmedPath)
        guard !standardizedPath.isEmpty else {
            if Self.isLoggingEnabled {
                print("Empty standardized path, returning nil")
            }
            return nil
        }

        let isAbsolute = standardizedPath.hasPrefix("/")
        let userComponents = standardizedPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)

        if Self.isLoggingEnabled {
            print("- trimmedPath: '\(trimmedPath)'")
            print("- standardizedPath: '\(standardizedPath)'")
            print("- isAbsolute: \(isAbsolute)")
            print("- userComponents: \(userComponents)")
        }

        // ─────────────────────────────────────────────────────────────────────────
        // A) ABSOLUTE‑PATH LOGIC
        // ─────────────────────────────────────────────────────────────────────────
        if isAbsolute {
            if Self.isLoggingEnabled {
                print("\n=== Absolute path logic ===")
            }

            // 1) Direct full-path match (now case-insensitive)
            if let directFullMatch = snapshot.file(standardizedPath) {
                if Self.isLoggingEnabled {
                    print("Found direct full-path match: \(directFullMatch.relativePath)")
                }
                return PathMatchLocation(
                    rootPath: directFullMatch.rootFolderPath,
                    correctedPath: directFullMatch.relativePath
                )
            }

            // 2) Gather candidate roots (string-only, avoid URL bridging)
            var candidateRoots = getCandidateRoots(forFullPath: standardizedPath, snapshot: snapshot)

            if Self.isLoggingEnabled {
                print("Full path: \(standardizedPath)")
                print("Candidate roots (std): \(candidateRoots)")
            }

            // If none matched by simple prefix, try symlink-resolved comparisons
            if candidateRoots.isEmpty {
                let resolvedFull = (standardizedPath as NSString).resolvingSymlinksInPath
                candidateRoots = getCandidateRoots(forFullPath: resolvedFull, snapshot: snapshot)
                if Self.isLoggingEnabled {
                    print("Candidate roots (resolved): \(candidateRoots)")
                }
            }

            // If no candidate root matches, allow a conservative, parent-qualified suffix fallback.
            if candidateRoots.isEmpty {
                if !exactMatchOnly, options.allowAbsoluteSuffixFallback, absoluteSuffixFallbackEnabled,
                   let hit = findAbsoluteParentQualifiedTail(
                       userComponents: userComponents,
                       minTail: absSuffixMinComponents,
                       maxTail: min(absSuffixMaxComponents, userComponents.count),
                       snapshot: snapshot
                   )
                {
                    return hit
                }
                return nil
            }

            // 3) Parent‑folder optimization
            if userComponents.count > 1, !candidateRoots.isEmpty {
                let fileName = userComponents.last!
                let parentRel = userComponents.dropLast().joined(separator: "/")

                // Try each candidate root
                let standardizedParentRel = StandardizedPath.relative(parentRel)
                for rootPath in candidateRoots {
                    let folderAbs = standardizedLookupPath(rootPath: rootPath, relativePath: standardizedParentRel)

                    if snapshot.folderRecord(forStandardizedFullPath: folderAbs) != nil {
                        let expectedFilePath = appendStandardizedRelativePath(rootPath: folderAbs, relativePath: fileName)
                        if let fileVM = snapshot.fileRecord(forStandardizedFullPath: expectedFilePath) {
                            return PathMatchLocation(
                                rootPath: fileVM.rootFolderPath,
                                correctedPath: fileVM.relativePath
                            )
                        }
                    }
                }
            }

            if exactMatchOnly {
                return nil
            }

            // 4) Fuzzy match single vs. multi component
            if userComponents.count == 1 {
                if let result = findSingleComponentMatch(
                    name: userComponents[0],
                    exactMatchOnly: exactMatchOnly,
                    snapshot: snapshot
                ) {
                    if !candidateRoots.isEmpty {
                        guard candidateRoots.contains(result.rootPath) else { return nil }
                    }
                    return result
                }
                return nil
            } else {
                guard let multi = findBestMultiComponentMatch(
                    fullPath: standardizedPath,
                    userComponents: userComponents,
                    exactMatchOnly: exactMatchOnly,
                    snapshot: snapshot
                ) else { return nil }
                if !candidateRoots.isEmpty {
                    guard candidateRoots.contains(multi.rootPath) else { return nil }
                }
                return multi
            }
        }

        // ─────────────────────────────────────────────────────────────────────────
        // B) RELATIVE‑PATH LOGIC
        // ─────────────────────────────────────────────────────────────────────────

        if Self.isLoggingEnabled {
            print("\n=== Relative path logic ===")
        }

        // Alias-aware normalization: if first component equals a root alias, drop it for matching and bias that root
        let aliasRoot: FolderRecord? = {
            guard let first = userComponents.first else { return nil }
            return aliasRootCandidates(for: first, snapshot: snapshot).first
        }()
        let relForMatch: String = {
            if let _ = aliasRoot, userComponents.count > 1 {
                return userComponents.dropFirst().joined(separator: "/")
            }
            return standardizedPath
        }()
        let compsForMatch: [String] = {
            if let _ = aliasRoot, userComponents.count > 1 {
                return Array(userComponents.dropFirst())
            }
            return userComponents
        }()

        // NEW: compute roots that own any selected file (for ordering/bias)
        let rootsWithSel = rootsWithSelection(snapshot)

        // NEW (macOS only): Head‑trim rescue — generate variants that drop leading
        // components until we hit a component equal to a loaded root's name.
        // We will try strict checks (absolute candidate & parent-folder) on these
        // variants *without* altering any other valid checks.
        let variantComponentLists: [([String], FolderRecord?)] = buildHeadTrimVariants(
            userComponents: userComponents,
            firstAliasRoot: aliasRoot,
            snapshot: snapshot,
            allowLeadingRootAliasTrim: options.allowLeadingRootAliasTrim,
            allowHeadTrimAliases: options.allowHeadTrimAliases
        )

        // Pass 1: strict absolute-candidate matches for each variant
        for (variantComps, biasRoot) in variantComponentLists {
            guard !variantComps.isEmpty else { continue }
            let variantRel = variantComps.joined(separator: "/")
            let standardizedVariantRel = StandardizedPath.relative(variantRel)

            // Scope to a single root when we discovered a bias root via head-trim.
            if let biasRoot {
                let abs = standardizedLookupPath(rootPath: biasRoot.fullPath, relativePath: standardizedVariantRel)
                if let hit = snapshot.fileRecord(forStandardizedFullPath: abs) {
                    return PathMatchLocation(
                        rootPath: hit.rootFolderPath,
                        correctedPath: hit.relativePath
                    )
                }
            } else {
                let orderedRoots = snapshot.rootFolders.sorted { lhs, rhs in
                    let lhsSel = rootsWithSel.contains(lhs.fullPath)
                    let rhsSel = rootsWithSel.contains(rhs.fullPath)
                    if lhsSel != rhsSel { return lhsSel }
                    if let alias = aliasRoot {
                        let lhsAlias = lhs.fullPath == alias.fullPath
                        let rhsAlias = rhs.fullPath == alias.fullPath
                        if lhsAlias != rhsAlias { return lhsAlias }
                    }
                    return lhs.fullPath < rhs.fullPath
                }
                for root in orderedRoots {
                    let abs = standardizedLookupPath(rootPath: root.fullPath, relativePath: standardizedVariantRel)
                    if let hit = snapshot.fileRecord(forStandardizedFullPath: abs) {
                        return PathMatchLocation(
                            rootPath: hit.rootFolderPath,
                            correctedPath: hit.relativePath
                        )
                    }
                }
            }
        }

        // Pass 2: parent-folder quick check for each variant
        for (variantComps, biasRoot) in variantComponentLists {
            guard variantComps.count > 1 else { continue }
            let fileName = variantComps.last!
            let folderRel = StandardizedPath.relative(variantComps.dropLast().joined(separator: "/"))

            let orderedRoots: [FolderRecord] = {
                if let biasRoot {
                    let others = snapshot.rootFolders.filter { $0.fullPath != biasRoot.fullPath }
                    return [biasRoot] + others
                }
                return snapshot.rootFolders
            }()

            for root in orderedRoots {
                let folderAbs = standardizedLookupPath(rootPath: root.fullPath, relativePath: folderRel)
                if snapshot.folderRecord(forStandardizedFullPath: folderAbs) != nil {
                    let expectedFilePath = appendStandardizedRelativePath(rootPath: folderAbs, relativePath: fileName)
                    if let fileVM = snapshot.fileRecord(forStandardizedFullPath: expectedFilePath) {
                        return PathMatchLocation(
                            rootPath: fileVM.rootFolderPath,
                            correctedPath: fileVM.relativePath
                        )
                    }
                }
            }
        }

        // If strict passes didn't find anything and the caller requires an exact match, stop here.
        if exactMatchOnly {
            if Self.isLoggingEnabled {
                print("Exact match only requested, returning nil")
            }
            return nil
        }

        // Once the caller has provided an explicit leading root alias, treat the
        // remainder as root-relative input. Do not fall back to suffix-based fuzzy
        // matching that could silently reinterpret "Root/..." as
        // "Root/Root/..." under the same workspace root.
        if aliasRoot != nil, options.allowLeadingRootAliasTrim {
            if Self.isLoggingEnabled {
                print("Explicit root alias consumed; skipping suffix-style fuzzy fallback")
            }
            return nil
        }

        // 3) Fuzzy logic on the original (untrimmed/alias-processed) components
        if Self.isLoggingEnabled {
            print("\nFuzzy matching logic:")
            print("- Component count: \(compsForMatch.count)")
        }

        if compsForMatch.count == 1 {
            if Self.isLoggingEnabled {
                print("Using single component match for: '\(compsForMatch[0])'")
            }
            return findSingleComponentMatch(
                name: compsForMatch[0],
                exactMatchOnly: exactMatchOnly,
                snapshot: snapshot
            )
        } else {
            if Self.isLoggingEnabled {
                print("Using multi-component match for path: '\(relForMatch)'")
            }
            if let result = findBestMultiComponentMatch(
                fullPath: relForMatch,
                userComponents: compsForMatch,
                exactMatchOnly: exactMatchOnly,
                snapshot: snapshot
            ) {
                if Self.isLoggingEnabled {
                    print("Multi-component match found: \(result.correctedPath)")
                }
                return result
            }
        }

        // 4) Last resort: Tolerate a single missing component (original comps)
        if Self.isLoggingEnabled {
            print("\nTrying last resort: match with one missing component")
        }

        if let tolerantHit = findBestMatchWithOneMissingComponent(
            userComponents: compsForMatch,
            exactMatchOnly: exactMatchOnly,
            snapshot: snapshot
        ) {
            if Self.isLoggingEnabled {
                print("Found match with missing component: \(tolerantHit.relativePath)")
            }
            return PathMatchLocation(
                rootPath: tolerantHit.rootFolderPath,
                correctedPath: tolerantHit.relativePath
            )
        }

        if Self.isLoggingEnabled {
            print("\n=== No match found, returning nil ===")
        }

        return nil
    }

    private static func folderExists(
        _ fullPath: String,
        snapshot: PathMatchSnapshot
    ) -> Bool {
        if snapshot.folder(fullPath) != nil { return true }
        let prefix = fullPath.hasSuffix("/") ? fullPath : fullPath + "/"
        return snapshot.foldersByFullPath.keys.contains { $0.hasPrefix(prefix) }
    }

    /// Find the best root folder for creating a new file
    static func findCreationPath(
        userPath: String,
        snapshot: PathMatchSnapshot
    ) -> FileCreationResult? {
        if isLoggingEnabled {
            print("\n=== findCreationPath ===")
            print("Input path: '\(userPath)'")
        }

        // 0) Sanitise & normalise
        let trimmed = PathCharPolicy.foldHomoglyphsIfNeeded(
            userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return nil }

        // Reject paths ending with "/" (no filename)
        guard !trimmed.hasSuffix("/") else { return nil }

        let standardizedInput = StandardizedPath.absolute(trimmed)
        let isAbsolute = standardizedInput.hasPrefix("/")
        let components = standardizedInput
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)

        guard let fileName = components.last else { return nil }
        let dirComps = Array(components.dropLast())

        // Bias inputs: alias root and selected roots
        let aliasRootCandidateRoots: [FolderRecord] = {
            guard let first = dirComps.first, !first.isEmpty else { return [] }
            return aliasRootCandidates(for: first, snapshot: snapshot)
        }()
        let aliasRoot = aliasRootCandidateRoots.first
        let aliasRootCandidatePaths = Set(aliasRootCandidateRoots.map(\.fullPath))
        let rootsWithSel = rootsWithSelection(snapshot)

        if Self.isLoggingEnabled {
            print("Components: \(components)")
            print("Directory components: \(dirComps)")
            print("Filename: \(fileName)")
            print("Is absolute: \(isAbsolute)")
        }

        // 1) Absolute paths
        if isAbsolute {
            let stdURL = URL(fileURLWithPath: trimmed).standardizedFileURL
            guard
                let root = snapshot.rootFolders
                .filter({ isUnder(stdURL.path, root: $0.fullPath) })
                .max(by: { $0.fullPath.count < $1.fullPath.count })
            else { return nil }

            let relative = String(
                stdURL.path.dropFirst(root.fullPath.count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            )
            var relativeComps = relative.isEmpty
                ? []
                : relative.split(separator: "/").map(String.init)

            if relativeComps.last != fileName {
                relativeComps.append(fileName)
            }
            return FileCreationResult(rootFolder: root, componentsToCreate: relativeComps)
        }

        // 2) Relative paths
        struct Candidate {
            let root: FolderRecord
            let deepFolder: FolderRecord
            let matchedDepth: Int // how many directory components matched (actual folder depth)
            let matchedRelPath: String // relative path of the matched folder
            let matchedRelDepth: Int // NEW – depth of the matched folder itself
            let startIdx: Int // 0 or 1 (did we skip first component?)
            let leftover: Int // yet-to-create components (dirs only)
        }

        func deepestMatch(from start: Int, in root: FolderRecord, snapshot: PathMatchSnapshot) -> (folder: FolderRecord, matchedCount: Int, folderDepth: Int, relativePath: String) {
            guard start < dirComps.count else {
                return (root, 0, 0, "")
            }

            func componentCount(_ relativePath: String) -> Int {
                guard !relativePath.isEmpty else { return 0 }
                return relativePath.utf8.reduce(into: 1) { count, byte in
                    if byte == 47 { count += 1 } // '/'
                }
            }

            func isBetterSuffixCandidate(
                _ candidate: FolderRecord,
                than current: FolderRecord?,
                pathSoFar: String,
                pathDepth: Int
            ) -> Bool {
                guard let current else { return true }

                let candidateRel = candidate.relativePath
                let currentRel = current.relativePath
                let candidateExact = candidateRel.caseInsensitiveCompare(pathSoFar) == .orderedSame
                let currentExact = currentRel.caseInsensitiveCompare(pathSoFar) == .orderedSame
                if candidateExact != currentExact { return candidateExact }

                let candidateExtraDepth = max(0, componentCount(candidateRel) - pathDepth)
                let currentExtraDepth = max(0, componentCount(currentRel) - pathDepth)
                if candidateExtraDepth != currentExtraDepth { return candidateExtraDepth < currentExtraDepth }

                if candidateRel != currentRel {
                    return candidateRel.utf8.lexicographicallyPrecedes(currentRel.utf8)
                }

                return candidate.fullPath.utf8.lexicographicallyPrecedes(current.fullPath.utf8)
            }

            if PathMatcher.isLoggingEnabled {
                print("  deepestMatch: start=\(start), root=\(root.fullPath), dirComps[start...]=\(Array(dirComps[start...]))")
            }

            var cur = root
            var matchedCount = 0

            for idx in start ..< dirComps.count {
                let pathSoFar = dirComps[start ... idx].joined(separator: "/")
                let pathDepth = idx - start + 1
                let exactPath = appendStandardizedRelativePath(rootPath: root.fullPath, relativePath: pathSoFar)

                if let exactFolder = snapshot.folderRecord(forStandardizedFullPath: exactPath), exactFolder.rootPath == root.fullPath {
                    if PathMatcher.isLoggingEnabled {
                        print("    Found exact match: \(exactFolder.fullPath) matches \(pathSoFar)")
                    }
                    cur = exactFolder
                    matchedCount = pathDepth
                    continue
                }

                var bestSuffixFolder: FolderRecord?
                for (_, folder) in snapshot.foldersByFullPath {
                    guard folder.rootPath == root.fullPath else { continue }

                    let folderRelPath = folder.relativePath
                    guard folderRelPath.hasSuffix("/" + pathSoFar) else { continue }

                    if isBetterSuffixCandidate(folder, than: bestSuffixFolder, pathSoFar: pathSoFar, pathDepth: pathDepth) {
                        bestSuffixFolder = folder
                    }
                }

                guard let suffixFolder = bestSuffixFolder else {
                    break
                }

                if PathMatcher.isLoggingEnabled {
                    print("    Found suffix match: \(suffixFolder.fullPath) matches \(pathSoFar)")
                }
                cur = suffixFolder
                matchedCount = pathDepth
            }

            if matchedCount > 0 {
                let folderDepth = componentCount(cur.relativePath)
                return (cur, matchedCount, folderDepth, cur.relativePath)
            } else {
                return (root, 0, 0, "")
            }
        }

        /// Alias-root preference: if the first directory component matches a root alias,
        /// constrain creation to that root and consume exactly one leading alias segment.
        /// If the user intends a literal same-name top-level folder inside that root,
        /// they must repeat the prefix: "RootName/RootName/...".
        func resolveAliasCreation(for alias: FolderRecord, aliasComps: [String]) -> FileCreationResult {
            func aliasDeepestMatch(from start: Int, in root: FolderRecord, snapshot: PathMatchSnapshot) -> (folder: FolderRecord, matchedCount: Int, folderDepth: Int, relativePath: String) {
                guard start < aliasComps.count else {
                    return (root, 0, 0, "")
                }
                func componentCount(_ relativePath: String) -> Int {
                    guard !relativePath.isEmpty else { return 0 }
                    return relativePath.utf8.reduce(into: 1) { count, byte in
                        if byte == 47 { count += 1 }
                    }
                }
                var cur = root
                var matchedCount = 0
                for idx in start ..< aliasComps.count {
                    let pathSoFar = aliasComps[start ... idx].joined(separator: "/")
                    let exactPath = appendStandardizedRelativePath(rootPath: root.fullPath, relativePath: pathSoFar)
                    guard let exactFolder = snapshot.folderRecord(forStandardizedFullPath: exactPath), exactFolder.rootPath == root.fullPath else { break }
                    cur = exactFolder
                    matchedCount = idx - start + 1
                }
                if matchedCount > 0 {
                    let folderDepth = componentCount(cur.relativePath)
                    return (cur, matchedCount, folderDepth, cur.relativePath)
                } else {
                    return (root, 0, 0, "")
                }
            }

            var bestMatchForRoot: (folder: FolderRecord, matchedCount: Int, folderDepth: Int, relativePath: String, startIdx: Int)?
            for startIdx in 0 ..< aliasComps.count {
                let match = aliasDeepestMatch(from: startIdx, in: alias, snapshot: snapshot)
                if let current = bestMatchForRoot {
                    if match.matchedCount > current.matchedCount {
                        bestMatchForRoot = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                    } else if match.matchedCount == current.matchedCount, startIdx < current.startIdx {
                        bestMatchForRoot = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                    }
                } else if match.matchedCount > 0 {
                    bestMatchForRoot = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                }
            }

            let selectedMatch = bestMatchForRoot ?? (alias, 0, 0, "", 0)

            var consumedFromDirComps = selectedMatch.4
            if selectedMatch.1 > 0 {
                let folderComps = selectedMatch.3.split(separator: "/").map(String.init)
                let dirCompsSlice = Array(aliasComps[selectedMatch.4...])
                for suffixLen in 1 ... min(folderComps.count, dirCompsSlice.count) {
                    let folderSuffix = folderComps.suffix(suffixLen)
                    let dirPrefix = dirCompsSlice.prefix(suffixLen)
                    var matches = true
                    for i in 0 ..< suffixLen {
                        if folderSuffix[folderSuffix.startIndex + i].caseInsensitiveCompare(dirPrefix[dirPrefix.startIndex + i]) != .orderedSame {
                            matches = false
                            break
                        }
                    }
                    if matches {
                        consumedFromDirComps = selectedMatch.4 + suffixLen
                    }
                }
            }

            let leftoverCnt = aliasComps.count - consumedFromDirComps
            let winner = Candidate(
                root: alias,
                deepFolder: selectedMatch.0,
                matchedDepth: selectedMatch.1,
                matchedRelPath: selectedMatch.3,
                matchedRelDepth: selectedMatch.2,
                startIdx: selectedMatch.4,
                leftover: leftoverCnt
            )

            var toCreate: [String] = []
            if !winner.matchedRelPath.isEmpty {
                toCreate.append(contentsOf: winner.matchedRelPath.split(separator: "/").map(String.init))
            }
            if winner.startIdx > 0 {
                toCreate.append(contentsOf: aliasComps.prefix(winner.startIdx))
            }
            let consumed = winner.startIdx + winner.matchedDepth
            if consumed < aliasComps.count {
                let tail = Array(aliasComps.dropFirst(consumed))
                toCreate.append(contentsOf: tail)
            }
            toCreate.append(fileName)

            if Self.isLoggingEnabled {
                print("\nAlias-root result:")
                print("Root: \(winner.root.fullPath)")
                print("Components to create: \(toCreate)")
                print("======================\n")
            }

            return FileCreationResult(rootFolder: winner.root, componentsToCreate: toCreate)
        }

        if let alias = aliasRoot {
            return resolveAliasCreation(for: alias, aliasComps: Array(dirComps.dropFirst()))
        }

        var best: Candidate?

        if Self.isLoggingEnabled {
            print("\nAvailable roots: \(snapshot.rootFolders.map(\.fullPath))")
        }

        for root in snapshot.rootFolders {
            if Self.isLoggingEnabled {
                print("\n--- Checking root: \(root.fullPath) ---")
            }

            // Try all possible start indices to find the deepest matching suffix
            var bestMatchForRoot: (folder: FolderRecord, matchedCount: Int, folderDepth: Int, relativePath: String, startIdx: Int)?

            for startIdx in 0 ..< dirComps.count {
                let match = deepestMatch(from: startIdx, in: root, snapshot: snapshot)
                if Self.isLoggingEnabled {
                    print("Match from index \(startIdx): folder=\(match.folder.fullPath), matchedCount=\(match.matchedCount), folderDepth=\(match.folderDepth), relPath=\(match.relativePath)")
                }

                // Keep the match with the highest matchedCount
                if let current = bestMatchForRoot {
                    if match.matchedCount > current.matchedCount {
                        bestMatchForRoot = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                    } else if match.matchedCount == current.matchedCount, startIdx < current.startIdx {
                        // Prefer lower startIdx when matchedCount is equal
                        bestMatchForRoot = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                    }
                } else if match.matchedCount > 0 {
                    bestMatchForRoot = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                }
            }

            // If no match found, use root with startIdx 0
            let selectedMatch = bestMatchForRoot ?? (root, 0, 0, "", 0)

            // Calculate leftover - we need to figure out how many components were actually consumed
            // When doing suffix matching, we consumed from startIdx to the end of the match
            var consumedFromDirComps = selectedMatch.4 // startIdx

            // Count how many components from dirComps were matched
            if selectedMatch.1 > 0 { // if matchedCount > 0
                // Find how many components from dirComps[startIdx...] match the tail of the folder
                let folderComps = selectedMatch.3.split(separator: "/").map(String.init)
                let dirCompsSlice = Array(dirComps[selectedMatch.4...])

                // Find the longest suffix match
                for suffixLen in 1 ... min(folderComps.count, dirCompsSlice.count) {
                    let folderSuffix = folderComps.suffix(suffixLen)
                    let dirPrefix = dirCompsSlice.prefix(suffixLen)

                    var matches = true
                    for i in 0 ..< suffixLen {
                        if folderSuffix[folderSuffix.startIndex + i].caseInsensitiveCompare(dirPrefix[dirPrefix.startIndex + i]) != .orderedSame {
                            matches = false
                            break
                        }
                    }

                    if matches {
                        consumedFromDirComps = selectedMatch.4 + suffixLen
                    }
                }
            }

            let leftoverCnt = dirComps.count - consumedFromDirComps

            // Skip candidates with negative leftover (impossible state)
            guard leftoverCnt >= 0 else { continue }

            let cand = Candidate(
                root: root,
                deepFolder: selectedMatch.0,
                matchedDepth: selectedMatch.1,
                matchedRelPath: selectedMatch.3,
                matchedRelDepth: selectedMatch.2,
                startIdx: selectedMatch.4,
                leftover: leftoverCnt
            )

            if Self.isLoggingEnabled {
                print("Candidate: matchedDepth=\(cand.matchedDepth), leftover=\(leftoverCnt), startIdx=\(cand.startIdx), deepFolder=\(cand.deepFolder.fullPath), relPath=\(cand.matchedRelPath)")
            }

            if let b = best {
                // Normalized comparison: treat all roots equally regardless of startIdx
                // Compare by: 1) matchedDepth, 2) leftover, 3) startIdx, 4) root path length

                if cand.matchedDepth > b.matchedDepth {
                    if Self.isLoggingEnabled {
                        print("New best: deeper match (\(cand.matchedDepth) > \(b.matchedDepth))")
                    }
                    best = cand
                } else if cand.matchedDepth == b.matchedDepth {
                    if cand.leftover < b.leftover {
                        if Self.isLoggingEnabled {
                            print("New best: fewer leftover (\(cand.leftover) < \(b.leftover))")
                        }
                        best = cand
                    } else if cand.leftover == b.leftover {
                        // Bias 1: explicit alias root if provided (soft preference)
                        if let alias = aliasRoot {
                            let candAlias = cand.root.fullPath == alias.fullPath
                            let bestAlias = b.root.fullPath == alias.fullPath
                            if candAlias != bestAlias {
                                if candAlias {
                                    if Self.isLoggingEnabled { print("New best: alias-root bias") }
                                    best = cand
                                }
                            } else {
                                // Bias 2: prefer roots containing any selected file when alias doesn't decide
                                let candSel = rootsWithSel.contains(cand.root.fullPath)
                                let bestSel = rootsWithSel.contains(b.root.fullPath)
                                if cand.matchedDepth > 0 || b.matchedDepth > 0, candSel != bestSel {
                                    if candSel {
                                        if Self.isLoggingEnabled { print("New best: selected-root bias (has matches)") }
                                        best = cand
                                    }
                                } else {
                                    // Existing tie-breakers
                                    if cand.matchedRelDepth < b.matchedRelDepth {
                                        if Self.isLoggingEnabled { print("New best: shallower matched folder") }
                                        best = cand
                                    } else if cand.matchedRelDepth == b.matchedRelDepth {
                                        if cand.startIdx < b.startIdx {
                                            if Self.isLoggingEnabled { print("New best: no skip preferred (\(cand.startIdx) < \(b.startIdx))") }
                                            best = cand
                                        } else if cand.startIdx == b.startIdx {
                                            // If still tied, prefer roots matching the alias candidates for the first component
                                            let candMatches = aliasRootCandidatePaths.contains(cand.root.fullPath)
                                            let bestMatches = aliasRootCandidatePaths.contains(b.root.fullPath)

                                            if candMatches, !bestMatches {
                                                if Self.isLoggingEnabled { print("New best: root name matches first component") }
                                                best = cand
                                            } else if !candMatches, !bestMatches {
                                                if Self.isLoggingEnabled { print("Tie: keep existing best (stable root order)") }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            // No alias present: prefer selected-root if it helps, otherwise existing logic
                            let candSel = rootsWithSel.contains(cand.root.fullPath)
                            let bestSel = rootsWithSel.contains(b.root.fullPath)
                            if cand.matchedDepth > 0 || b.matchedDepth > 0, candSel != bestSel {
                                if candSel {
                                    if Self.isLoggingEnabled { print("New best: selected-root bias (no-alias, has matches)") }
                                    best = cand
                                }
                            } else {
                                if cand.matchedRelDepth < b.matchedRelDepth {
                                    if Self.isLoggingEnabled { print("New best: shallower matched folder") }
                                    best = cand
                                } else if cand.matchedRelDepth == b.matchedRelDepth {
                                    if cand.startIdx < b.startIdx {
                                        if Self.isLoggingEnabled { print("New best: no skip preferred (\(cand.startIdx) < \(b.startIdx))") }
                                        best = cand
                                    } else if cand.startIdx == b.startIdx {
                                        let candMatches = aliasRootCandidatePaths.contains(cand.root.fullPath)
                                        let bestMatches = aliasRootCandidatePaths.contains(b.root.fullPath)
                                        if candMatches, !bestMatches {
                                            if Self.isLoggingEnabled { print("New best: root name matches first component") }
                                            best = cand
                                        } else if !candMatches, !bestMatches {
                                            if Self.isLoggingEnabled { print("Tie: keep existing best (stable root order)") }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                if Self.isLoggingEnabled {
                    print("First candidate, setting as best")
                }
                best = cand
            }
        }

        guard let winner = best else {
            if Self.isLoggingEnabled {
                print("\nNo winning candidate found")
            }
            return nil
        }

        if Self.isLoggingEnabled {
            print("\nWinner: root=\(winner.root.fullPath), deepFolder=\(winner.deepFolder.fullPath)")
        }

        // 2a) Inter-root tie prevention - check if another root would score equally
        _ = snapshot.rootFolders.contains { otherRoot in
            guard otherRoot.fullPath != winner.root.fullPath else { return false }

            // Check both normal and skip-first for the other root
            // Try all possible start indices for the other root to find its best match
            var otherBestMatch: (folder: FolderRecord, matchedCount: Int, folderDepth: Int, relativePath: String, startIdx: Int)?
            for startIdx in 0 ..< dirComps.count {
                let match = deepestMatch(from: startIdx, in: otherRoot, snapshot: snapshot)
                if let current = otherBestMatch {
                    if match.matchedCount > current.matchedCount {
                        otherBestMatch = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                    } else if match.matchedCount == current.matchedCount, startIdx < current.startIdx {
                        otherBestMatch = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                    }
                } else if match.matchedCount > 0 {
                    otherBestMatch = (match.folder, match.matchedCount, match.folderDepth, match.relativePath, startIdx)
                }
            }

            guard let otherMatch = otherBestMatch else { return false }

            // Calculate leftover for the other root
            var otherConsumedFromDirComps = otherMatch.startIdx

            if otherMatch.matchedCount > 0 {
                let folderComps = otherMatch.relativePath.split(separator: "/").map(String.init)
                let dirCompsSlice = Array(dirComps[otherMatch.startIdx...])

                for suffixLen in 1 ... min(folderComps.count, dirCompsSlice.count) {
                    let folderSuffix = folderComps.suffix(suffixLen)
                    let dirPrefix = dirCompsSlice.prefix(suffixLen)

                    var matches = true
                    for i in 0 ..< suffixLen {
                        if folderSuffix[folderSuffix.startIndex + i].caseInsensitiveCompare(dirPrefix[dirPrefix.startIndex + i]) != .orderedSame {
                            matches = false
                            break
                        }
                    }

                    if matches {
                        otherConsumedFromDirComps = otherMatch.startIdx + suffixLen
                    }
                }
            }

            let otherLeftover = dirComps.count - otherConsumedFromDirComps

            // Skip if negative leftover
            if otherLeftover < 0 { return false }

            // Compare using same normalized logic
            if otherMatch.matchedCount != winner.matchedDepth { return false }
            if otherLeftover != winner.leftover { return false }
            if otherMatch.folderDepth != winner.matchedRelDepth { return false }

            // Check if it would tie on path length
            return otherRoot.fullPath.count == winner.root.fullPath.count
        }

        /// ------------------------------------------------------------------
        /// New deterministic assembly:
        /// 1) everything that *already* exists (matchedRelPath)
        /// 2) skipped components (except when equal to root name and folder exists)
        /// 3) remaining unmatched components
        /// 4) file name
        /// ------------------------------------------------------------------
        func splitPath(_ str: String) -> [String] {
            str.isEmpty ? [] : str.split(separator: "/").map(String.init)
        }

        let rootName = winner.root.name
        var toCreate: [String] = []

        // Special case – user path started with an alias identical to the root
        // Always drop the alias from created components; it is a root indicator, not a directory
        if winner.startIdx == 1,
           let firstComp = dirComps.first,
           firstComp.caseInsensitiveCompare(rootName) == .orderedSame
        {
            let matchedComps = splitPath(winner.matchedRelPath) // already-existing parts
            toCreate.append(contentsOf: matchedComps)

            // Append any directory components that come after the matched portion (excluding alias)
            let consumed = winner.startIdx + winner.matchedDepth
            if consumed < dirComps.count {
                toCreate.append(contentsOf: dirComps.dropFirst(consumed))
            }

        } else {
            // 1️⃣ components that already exist under deepFolder
            toCreate.append(contentsOf: splitPath(winner.matchedRelPath))

            // 2️⃣ any user components we skipped (prefix before matching began)
            if winner.startIdx > 0 {
                toCreate.append(contentsOf: dirComps.prefix(winner.startIdx))
            }

            // 3️⃣ components after the matched portion
            let consumed = winner.startIdx + winner.matchedDepth
            if consumed < dirComps.count {
                var tail = Array(dirComps.dropFirst(consumed))
                // If the first component equals the root name, treat it as alias and drop it
                if consumed == 0,
                   let firstCompAll = dirComps.first,
                   firstCompAll.caseInsensitiveCompare(rootName) == .orderedSame
                {
                    if !tail.isEmpty { tail.removeFirst() }
                }
                toCreate.append(contentsOf: tail)
            }
        }

        // 4️⃣ finally the file name
        toCreate.append(fileName)

        if Self.isLoggingEnabled {
            print("\nFinal result:")
            print("Root: \(winner.root.fullPath)")
            print("Components to create: \(toCreate)")
            print("======================\n")
        }

        return FileCreationResult(rootFolder: winner.root, componentsToCreate: toCreate)
    }

    /// Resolves a creation path with optional ambiguity detection.
    ///
    /// In `.bestEffort` mode, this behaves identically to `findCreationPath`.
    /// In `.requireUnambiguous` mode, this returns `.ambiguous` if multiple roots
    /// tie on structural signals (matchedDepth, leftover) without a clear winner.
    ///
    /// - Parameters:
    ///   - userPath: The user-provided path (relative or absolute)
    ///   - snapshot: Current workspace state snapshot
    ///   - mode: Resolution mode controlling tie-breaking behavior
    /// - Returns: Resolution result, or `nil` if path cannot be resolved within the workspace
    static func resolveCreationPath(
        userPath: String,
        snapshot: PathMatchSnapshot,
        mode: CreationResolutionMode
    ) -> FileCreationResolution? {
        // For best-effort mode, just use the existing function
        if mode == .bestEffort {
            guard let result = findCreationPath(userPath: userPath, snapshot: snapshot) else {
                return nil
            }
            return .unique(result)
        }

        // For requireUnambiguous mode, we need to detect ties
        // Re-implement the candidate evaluation with tie detection

        let trimmed = PathCharPolicy.foldHomoglyphsIfNeeded(
            userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasSuffix("/") else { return nil }

        let standardizedInput = StandardizedPath.absolute(trimmed)
        let isAbsolute = standardizedInput.hasPrefix("/")
        let components = standardizedInput
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/")
            .map(String.init)

        guard components.last != nil else { return nil }
        let dirComps = Array(components.dropLast())

        // Absolute paths are always unambiguous
        if isAbsolute {
            guard let result = findCreationPath(userPath: userPath, snapshot: snapshot) else {
                return nil
            }
            return .unique(result)
        }

        // Check for alias prefix - if present, it's unambiguous under the shared alias policy.
        let aliasRoot: FolderRecord? = {
            guard let first = dirComps.first, !first.isEmpty else { return nil }
            let matches = aliasRootCandidates(for: first, snapshot: snapshot)
            return matches.count == 1 ? matches.first : nil
        }()

        // If alias is present and resolves uniquely, use standard resolution
        if aliasRoot != nil {
            guard let result = findCreationPath(userPath: userPath, snapshot: snapshot) else {
                return nil
            }
            return .unique(result)
        }

        // No alias prefix - check if the path can resolve unambiguously across roots
        // by evaluating structural signals (matchedDepth, leftover)

        struct Candidate {
            let root: FolderRecord
            let matchedDepth: Int
            let leftover: Int
        }

        func deepestMatch(from start: Int, in root: FolderRecord) -> (matchedCount: Int, consumed: Int) {
            guard start < dirComps.count else {
                return (0, start)
            }

            var matchedCount = 0
            var consumed = start

            for idx in start ..< dirComps.count {
                let pathSoFar = dirComps[start ... idx].joined(separator: "/")
                let exactPath = appendStandardizedRelativePath(rootPath: root.fullPath, relativePath: pathSoFar)
                if let exactFolder = snapshot.folderRecord(forStandardizedFullPath: exactPath), exactFolder.rootPath == root.fullPath {
                    matchedCount = idx - start + 1
                    continue
                }

                var found = false
                for (_, folder) in snapshot.foldersByFullPath {
                    guard folder.rootPath == root.fullPath else { continue }

                    let folderRelPath = folder.relativePath
                    if folderRelPath.hasSuffix("/" + pathSoFar) {
                        matchedCount = idx - start + 1
                        found = true
                        break
                    }
                }

                if !found { break }
            }

            if matchedCount > 0 {
                let folderCompsCount = matchedCount
                consumed = start + folderCompsCount
            }

            return (matchedCount, consumed)
        }

        var candidates: [Candidate] = []

        for root in snapshot.rootFolders {
            var bestMatch: (matchedCount: Int, consumed: Int)?

            for startIdx in 0 ..< max(1, dirComps.count) {
                let match = deepestMatch(from: startIdx, in: root)
                if let current = bestMatch {
                    if match.matchedCount > current.matchedCount {
                        bestMatch = match
                    } else if match.matchedCount == current.matchedCount, startIdx < (dirComps.count - current.consumed) {
                        bestMatch = match
                    }
                } else if match.matchedCount > 0 || startIdx == 0 {
                    bestMatch = match
                }
            }

            let selectedMatch = bestMatch ?? (0, 0)
            let leftover = dirComps.count - selectedMatch.consumed

            guard leftover >= 0 else { continue }

            candidates.append(Candidate(
                root: root,
                matchedDepth: selectedMatch.matchedCount,
                leftover: leftover
            ))
        }

        guard !candidates.isEmpty else {
            return nil
        }

        // Sort by structural signals: higher matchedDepth, then lower leftover
        let sorted = candidates.sorted { a, b in
            if a.matchedDepth != b.matchedDepth {
                return a.matchedDepth > b.matchedDepth
            }
            return a.leftover < b.leftover
        }

        let best = sorted[0]

        // Find all candidates that tie with the best on structural signals
        let tiedCandidates = sorted.filter { c in
            c.matchedDepth == best.matchedDepth && c.leftover == best.leftover
        }

        if tiedCandidates.count > 1 {
            // Multiple roots are equally valid - ambiguous
            let rootPaths = tiedCandidates.map(\.root.fullPath)
            return .ambiguous(candidateRootPaths: rootPaths)
        }

        // Unambiguous - use the standard resolver to get the full result
        guard let result = findCreationPath(userPath: userPath, snapshot: snapshot) else {
            return nil
        }
        return .unique(result)
    }

    private static func candidatesFor(
        userComponents: [String],
        snapshot: PathMatchSnapshot,
        suffixCount: Int,
        maxCap: Int = 20000
    ) -> [AnyItem] {
        let relevantComps = Array(userComponents.suffix(suffixCount))
        var fileMap: [String: FileRecord] = [:]

        func addFiles(_ arr: [FileRecord]?) {
            guard let arr, !arr.isEmpty else { return }
            for f in arr {
                if fileMap[f.fullPath] == nil {
                    fileMap[f.fullPath] = f
                    if fileMap.count >= maxCap { break }
                }
            }
        }

        if let last = relevantComps.last {
            let lastKey = snapshot.canonical(last)
            addFiles(snapshot.indexes.byFileName[lastKey])

            if relevantComps.count >= 2 {
                let lastTwo = relevantComps[relevantComps.count - 2] + "/" + relevantComps[relevantComps.count - 1]
                let lastTwoKey = snapshot.canonical(lastTwo)
                addFiles(snapshot.indexes.byLastTwo[lastTwoKey])
            }

            let ext = (last as NSString).pathExtension.lowercased()
            if !ext.isEmpty, let extGroup = snapshot.indexes.byExtension[ext] {
                if fileMap.isEmpty {
                    addFiles(extGroup)
                } else {
                    let extPaths = Set(extGroup.map(\.fullPath))
                    let filtered = fileMap.values.filter { extPaths.contains($0.fullPath) }
                    fileMap.removeAll(keepingCapacity: true)
                    for f in filtered {
                        fileMap[f.fullPath] = f
                        if fileMap.count >= maxCap { break }
                    }
                }
            }
        }

        var result: [AnyItem] = fileMap.values.map { AnyItem.file($0) }

        // Add a small set of folder candidates using previous directory component
        if relevantComps.count >= 2 {
            let prev = relevantComps[relevantComps.count - 2]
            let prevKey = snapshot.canonical(prev)
            if let folders = snapshot.indexes.foldersByLastComponent[prevKey] {
                for fo in folders {
                    result.append(.folder(fo))
                }
            }
        }

        return result
    }

    // MARK: - Helper Functions

    @inline(__always)
    private static func isUnder(_ path: String, root: String) -> Bool {
        // New pure‑Swift normalization and safe boundary check
        let p2 = standardizePathFast(path)
        let r2 = standardizePathFast(root)
        if p2 == r2 { return true }
        if r2.isEmpty { return false }

        // Ensure we only match when r2 is a full directory prefix of p2
        if p2.hasPrefix(r2) {
            if p2.count == r2.count { return true }
            let idx = p2.index(p2.startIndex, offsetBy: r2.count)
            return p2[idx] == "/"
        }
        if r2.hasSuffix("/") {
            return p2.hasPrefix(r2)
        } else {
            return p2.hasPrefix(r2 + "/")
        }
    }

    @inline(__always)
    private static func standardizePathFast(_ input: String) -> String {
        if input.isEmpty { return "" }
        let isAbsolute = input.hasPrefix("/")

        // Collapse separators + resolve '.' and '..' segments
        var stack = [String]()
        stack.reserveCapacity(16)

        for segSub in input.split(separator: "/", omittingEmptySubsequences: true) {
            let seg = String(segSub)
            if seg == "." { continue }
            if seg == ".." {
                if !stack.isEmpty {
                    _ = stack.popLast()
                } else if !isAbsolute {
                    // For relative paths, preserve leading '..'
                    stack.append("..")
                }
                continue
            }
            stack.append(seg)
        }

        if isAbsolute {
            // Root special case
            if stack.isEmpty { return "/" }
            return "/" + stack.joined(separator: "/")
        } else {
            return stack.joined(separator: "/")
        }
    }

    private static func normalizeUserInputPath(_ path: String, snapshot: PathMatchSnapshot) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return trimmed
        }

        // If the path starts with '/', attempt to see if it's actually inside any loaded root
        if trimmed.hasPrefix("/") {
            let candidateURL = URL(fileURLWithPath: trimmed).standardizedFileURL

            // Check if the candidate path is inside any root folder
            let isUnderAnyRoot = snapshot.rootFolders.contains {
                isUnder(candidateURL.path, root: $0.fullPath)
            }

            // If it's under a root, convert to relative path
            if isUnderAnyRoot {
                for root in snapshot.rootFolders {
                    if isUnder(candidateURL.path, root: root.fullPath) {
                        let relativePath = candidateURL.path.replacingOccurrences(of: root.fullPath, with: "")
                        return relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
                    }
                }
            }
        }

        return trimmed
    }

    private static func getCandidateRoots(forFullPath fullPath: String, snapshot: PathMatchSnapshot) -> [String] {
        let fullStd = StandardizedPath.absolute(fullPath)
        let fullRes = (fullStd as NSString).resolvingSymlinksInPath
        var out = Set<String>()
        out.reserveCapacity(snapshot.rootFolders.count)
        for root in snapshot.rootFolders {
            let rStd = root.fullPath
            let rRes = (rStd as NSString).resolvingSymlinksInPath
            if isUnder(fullStd, root: rStd) || isUnder(fullRes, root: rStd) ||
                isUnder(fullStd, root: rRes) || isUnder(fullRes, root: rRes)
            {
                out.insert(rStd)
            }
        }
        return Array(out)
    }

    /// Generate candidate component lists by optionally dropping leading components
    /// until we hit a component equal to a loaded root name (case-insensitive).
    /// The first element is always the original path as typed. Subsequent elements
    /// represent head‑trimmed variants (e.g. treating a component as a root alias).
    private static func buildHeadTrimVariants(
        userComponents: [String],
        firstAliasRoot: FolderRecord?,
        snapshot: PathMatchSnapshot,
        allowLeadingRootAliasTrim: Bool,
        allowHeadTrimAliases: Bool
    ) -> [([String], FolderRecord?)] {
        var variants: [([String], FolderRecord?)] = []

        // Explicit leading root aliases are consumed exactly once.
        // This makes:
        //   - "Root/file.swift"         → root-relative "file.swift"
        //   - "Root/Root/file.swift"    → root-relative "Root/file.swift"
        // and avoids silently collapsing repeated root-name prefixes.
        if allowLeadingRootAliasTrim,
           let alias = firstAliasRoot,
           userComponents.count > 1
        {
            variants.append((Array(userComponents.dropFirst()), alias))
        } else if !userComponents.isEmpty {
            variants.append((userComponents, firstAliasRoot))
        }

        // Once the first component has been claimed as an explicit root alias,
        // do not generate additional head-trim rescue variants from the original
        // path. The user can repeat the alias to address a literal same-name
        // folder under that root.
        guard allowHeadTrimAliases,
              userComponents.count > 1,
              firstAliasRoot == nil
        else {
            return variants
        }

        // Existing logic: additional head‑trimmed variants where any later
        //    component matches a root name (e.g., "apps/backend/Foo.swift"
        //    with a root named "backend").

        // Precompute canonical alias groups (case-insensitive) with compatibility fallback.
        let canonicalGroups: [String: [FolderRecord]] = Dictionary(grouping: snapshot.rootFolders) {
            $0.name.lowercased()
        }
        let lastComponentGroups: [String: [FolderRecord]] = Dictionary(grouping: snapshot.rootFolders) {
            (($0.fullPath as NSString).lastPathComponent).lowercased()
        }

        for idx in 1 ..< userComponents.count {
            let segLower = userComponents[idx].lowercased()
            let roots = canonicalGroups[segLower] ?? lastComponentGroups[segLower]
            guard let roots else { continue }

            // Drop everything up to *and including* this root-like component.
            let remainderStart = idx + 1
            guard remainderStart < userComponents.count else { continue } // nothing after root name

            let trimmed = Array(userComponents[remainderStart...])
            for root in roots {
                variants.append((trimmed, root))
            }
        }

        // Deduplicate while preserving insertion order.
        var seen = Set<String>()
        return variants.filter { comps, bias in
            let key = (bias?.fullPath ?? "all") + "|" + comps.joined(separator: "/")
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    static func absolutePathCandidates(forRelativePath relPath: String, snapshot: PathMatchSnapshot) -> [String] {
        let standardizedRelativePath = StandardizedPath.relative(relPath)
        return snapshot.rootFolders.map { root in
            standardizedLookupPath(rootPath: root.fullPath, relativePath: standardizedRelativePath)
        }
    }

    private static func makeLocation(folder: FolderRecord?, file: FileRecord?) -> PathMatchLocation? {
        if let f = file {
            return PathMatchLocation(
                rootPath: f.rootFolderPath,
                correctedPath: f.relativePath
            )
        }
        if let f = folder {
            return PathMatchLocation(
                rootPath: f.rootPath,
                correctedPath: f.relativePath
            )
        }
        return nil
    }

    // MARK: - Single Component Match

    private static func findSingleComponentMatch(
        name: String,
        exactMatchOnly: Bool,
        snapshot: PathMatchSnapshot
    ) -> PathMatchLocation? {
        let threshold = exactMatchOnly ? 0.9999 : 0.9
        // NEW: roots that contain any selected file
        let rootsWithSel = rootsWithSelection(snapshot)

        // 1) Exact name matches via byFileName index (canonical)
        let key = snapshot.canonical(name)
        let exactNameMatches = snapshot.indexes.byFileName[key] ?? []

        if exactNameMatches.count == 1 {
            return makeLocation(folder: nil, file: exactNameMatches[0])
        } else if exactNameMatches.count > 1 {
            let sortedMatches = exactNameMatches.sorted { lhs, rhs in
                // First priority: selected files
                let lhsSelected = snapshot.selectedFileFullPaths.contains(lhs.fullPath)
                let rhsSelected = snapshot.selectedFileFullPaths.contains(rhs.fullPath)
                if lhsSelected != rhsSelected { return lhsSelected }

                // Second priority: root contains any selected file
                let lhsRootSelected = rootsWithSel.contains(lhs.rootFolderPath)
                let rhsRootSelected = rootsWithSel.contains(rhs.rootFolderPath)
                if lhsRootSelected != rhsRootSelected { return lhsRootSelected }

                // Third priority: depth (shallower paths)
                let lhsDepth = lhs.relativePath.split(separator: "/").count
                let rhsDepth = rhs.relativePath.split(separator: "/").count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }

                // Deterministic tie-breaker
                return lhs.fullPath < rhs.fullPath
            }
            return makeLocation(folder: nil, file: sortedMatches[0])
        }

        // 2) Fuzzy approach bounded by indexes
        var candidates: [FileRecord] = []
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let byExt = snapshot.indexes.byExtension[ext] {
            candidates.append(contentsOf: byExt)
        } else if !exactMatchOnly {
            // No extension provided: use name-bucket prefilter by first alphanumeric character and reasonable length variance
            let canon = snapshot.canonical(name)
            let canonFC = firstAlnumLowercasedByte(canon)
            var added = 0
            // Iterate keys only (distinct file names), then append their groups to candidates
            for (k, group) in snapshot.indexes.byFileName {
                if let fc = canonFC {
                    guard let kfc = firstAlnumLowercasedByte(k), kfc == fc else { continue }
                }
                if abs(canon.count - k.count) > 6 { continue }
                candidates.append(contentsOf: group)
                added += group.count
                if added >= 12000 { break } // cap to avoid pathological growth
            }
        }

        guard !candidates.isEmpty else { return nil }

        var passingMatches: [(score: Double, file: FileRecord)] = []
        for file in candidates {
            // Compare canonicalized names with heap-safe similarity
            // (respects case policy and folds '-'/'_' equivalence)
            let q1 = snapshot.canonical(name)
            let f1 = snapshot.canonical(file.name)
            let sim = similarityScoreMax(q1, f1, threshold: threshold, caseSensitive: snapshot.caseSensitive)

            if sim >= threshold {
                passingMatches.append((sim, file))
            }
        }
        guard !passingMatches.isEmpty else { return nil }

        if passingMatches.count == 1 {
            let bestFile = passingMatches[0].file
            return makeLocation(folder: nil, file: bestFile)
        }

        // If multiple => selected files first, then selected roots, then depth, then similarity
        passingMatches.sort { lhs, rhs in
            let lhsSelected = snapshot.selectedFileFullPaths.contains(lhs.file.fullPath)
            let rhsSelected = snapshot.selectedFileFullPaths.contains(rhs.file.fullPath)
            if lhsSelected != rhsSelected { return lhsSelected }

            let lhsRootSelected = rootsWithSel.contains(lhs.file.rootFolderPath)
            let rhsRootSelected = rootsWithSel.contains(rhs.file.rootFolderPath)
            if lhsRootSelected != rhsRootSelected { return lhsRootSelected }

            let lhsDepth = lhs.file.relativePath.split(separator: "/").count
            let rhsDepth = rhs.file.relativePath.split(separator: "/").count
            if lhsDepth == rhsDepth {
                return lhs.score > rhs.score
            }
            return lhsDepth < rhsDepth
        }
        let bestFile = passingMatches[0].file
        return makeLocation(folder: nil, file: bestFile)
    }

    // MARK: - Multi Component Match

    private static func findBestMultiComponentMatch(
        fullPath: String,
        userComponents: [String],
        exactMatchOnly: Bool,
        snapshot: PathMatchSnapshot
    ) -> PathMatchLocation? {
        if isLoggingEnabled {
            print("\n=== findBestMultiComponentMatch ===")
            print("- fullPath: \(fullPath)")
            print("- userComponents: \(userComponents)")
            print("- exactMatchOnly: \(exactMatchOnly)")
        }

        // 1) First try strict suffix matching (no fuzzy logic)
        if let strictMatch = findStrictSuffixMatch(
            userComponents: userComponents,
            snapshot: snapshot
        ) {
            if isLoggingEnabled {
                print("Found strict suffix match: \(strictMatch.relativePath)")
            }
            return makeLocation(folder: nil, file: strictMatch)
        }

        // 2) Quick pre-check of final component using indexes
        let lastComponent = userComponents.last ?? ""
        let threshold = exactMatchOnly ? 0.9999 : 0.9

        if Self.isLoggingEnabled {
            print("\nPre-check last component: '\(lastComponent)'")
            print("- threshold: \(threshold)")
        }

        guard lastComponentExists(in: snapshot, lastComponent: lastComponent, threshold: threshold) else {
            if Self.isLoggingEnabled {
                print("Last component does not exist with sufficient similarity, returning nil")
            }
            return nil
        }

        // 3) Attempt standard "last 3 components" fuzzy match
        if Self.isLoggingEnabled {
            print("\nTrying fuzzy match with last 3 components")
        }

        if let result = fuzzyMatchWithSuffixLimit(
            fullPath: fullPath,
            userComponents: userComponents,
            suffixCount: 3,
            exactMatchOnly: exactMatchOnly,
            snapshot: snapshot
        ) {
            if Self.isLoggingEnabled {
                print("Found match with 3-component suffix: \(result.correctedPath)")
            }
            return result
        }

        // 4) If no match, try last 5
        if userComponents.count > 3 {
            if Self.isLoggingEnabled {
                print("\nTrying fuzzy match with last 5 components")
            }

            if let result = fuzzyMatchWithSuffixLimit(
                fullPath: fullPath,
                userComponents: userComponents,
                suffixCount: 5,
                exactMatchOnly: exactMatchOnly,
                snapshot: snapshot
            ) {
                if Self.isLoggingEnabled {
                    print("Found match with 5-component suffix: \(result.correctedPath)")
                }
                return result
            }
        }

        // 5) Fallback: entire path
        if Self.isLoggingEnabled {
            print("\nFallback: trying fuzzy match with entire path (\(userComponents.count) components)")
        }

        let finalResult = fuzzyMatchWithSuffixLimit(
            fullPath: fullPath,
            userComponents: userComponents,
            suffixCount: userComponents.count,
            exactMatchOnly: exactMatchOnly,
            snapshot: snapshot
        )

        if Self.isLoggingEnabled {
            if let result = finalResult {
                print("Found match with full path: \(result.correctedPath)")
            } else {
                print("No match found")
            }
        }

        return finalResult
    }

    // MARK: - Absolute path parent-qualified tail finder

    private static func findAbsoluteParentQualifiedTail(
        userComponents: [String],
        minTail: Int,
        maxTail: Int,
        snapshot: PathMatchSnapshot
    ) -> PathMatchLocation? {
        guard userComponents.count >= minTail else { return nil }
        let rootsWithSel = rootsWithSelection(snapshot)

        struct Cand { let file: FileRecord }
        var candidates: [Cand] = []

        let minN = max(2, minTail)
        let maxN = max(minN, maxTail)

        for n in minN ... min(maxN, userComponents.count) {
            // parent = last (n-1), filename = last
            let parentRel = userComponents.suffix(n).dropLast().joined(separator: "/")
            let fileName = userComponents.last ?? ""
            if parentRel.isEmpty || fileName.isEmpty { continue }

            let standardizedParentRel = StandardizedPath.relative(parentRel)
            for root in snapshot.rootFolders {
                let folderAbs = standardizedLookupPath(rootPath: root.fullPath, relativePath: standardizedParentRel)
                if snapshot.folderRecord(forStandardizedFullPath: folderAbs) != nil {
                    let fileAbs = appendStandardizedRelativePath(rootPath: folderAbs, relativePath: fileName)
                    if let fileVM = snapshot.fileRecord(forStandardizedFullPath: fileAbs) {
                        candidates.append(Cand(file: fileVM))
                    }
                }
            }
            if !candidates.isEmpty { break } // prefer the shortest qualifying tail
        }

        if candidates.isEmpty {
            // Fallback: match by last two components across all files.
            if userComponents.count >= 2 {
                let lowerSuffix = userComponents.suffix(2).joined(separator: "/").lowercased()
                for (_, file) in snapshot.filesByFullPath {
                    if file.relativePath.lowercased().hasSuffix(lowerSuffix) {
                        candidates.append(Cand(file: file))
                    }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Tie-breakers: selected roots, shallower depth, lexicographic fullPath
        candidates.sort { lhs, rhs in
            let lSel = rootsWithSel.contains(lhs.file.rootFolderPath)
            let rSel = rootsWithSel.contains(rhs.file.rootFolderPath)
            if lSel != rSel { return lSel }
            let lDepth = lhs.file.relativePath.split(separator: "/").count
            let rDepth = rhs.file.relativePath.split(separator: "/").count
            if lDepth != rDepth { return lDepth < rDepth }
            return lhs.file.fullPath < rhs.file.fullPath
        }
        let best = candidates[0].file
        return PathMatchLocation(rootPath: best.rootFolderPath, correctedPath: best.relativePath)
    }

    // MARK: - Helper Functions

    @inline(__always)
    private static func cleaned(_ str: String) -> String {
        // Quick ASCII probe: if all bytes < 0x80, skip folding entirely
        var isASCII = true
        for b in str.utf8 {
            if b >= 0x80 { isASCII = false
                break
            }
        }
        let input = isASCII ? str : PathCharPolicy.foldHomoglyphsIfNeeded(str)
        // Fast ASCII-only filter
        var sawNonASCII = false
        var out = [UInt8]()
        out.reserveCapacity(input.utf8.count)
        for b in input.utf8 {
            if b < 0x80 {
                if PathCharPolicy.isAllowedASCIIByte(b) { out.append(b) }
            } else {
                sawNonASCII = true
            }
        }
        if !sawNonASCII {
            return String(decoding: out, as: UTF8.self)
        }

        // Slow Unicode fallback: preserve alphanumerics
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(input.unicodeScalars.count)
        for sc in input.unicodeScalars {
            // After pre-folding, just keep allowed ASCII and all alphanumerics
            if sc.value < 0x80 {
                if PathCharPolicy.isAllowedASCIIByte(UInt8(truncatingIfNeeded: sc.value)) {
                    scalars.append(sc)
                }
            } else if CharacterSet.alphanumerics.contains(sc) {
                scalars.append(sc)
            }
        }
        return String(scalars)
    }

    private static func findStrictSuffixMatch(
        userComponents: [String],
        snapshot: PathMatchSnapshot
    ) -> FileRecord? {
        var bestMatch: FileRecord?
        var bestScore = 0.0

        // Candidate assembly via indexes
        var candMap: [String: FileRecord] = [:]
        if let last = userComponents.last {
            let k1 = snapshot.canonical(last)
            if let arr = snapshot.indexes.byFileName[k1] {
                for f in arr {
                    candMap[f.fullPath] = f
                }
            }
            if userComponents.count >= 2 {
                let lastTwo = userComponents[userComponents.count - 2] + "/" + userComponents[userComponents.count - 1]
                let k2 = snapshot.canonical(lastTwo)
                if let arr2 = snapshot.indexes.byLastTwo[k2] {
                    for f in arr2 {
                        candMap[f.fullPath] = f
                    }
                }
            }
        }

        // Verify strict suffix equality (case-insensitive on canonicalized components)
        for (_, file) in candMap {
            let fileComponents = file.relativePath.split(separator: "/").map(String.init)

            if fileComponents.count >= userComponents.count {
                let fileSuffix = Array(fileComponents.suffix(userComponents.count))

                var allMatch = true
                for (i, userComp) in userComponents.enumerated() {
                    if cleaned(userComp).lowercased() != cleaned(fileSuffix[i]).lowercased() {
                        allMatch = false
                        break
                    }
                }

                if allMatch {
                    let score = Double(userComponents.count * 2) - Double(fileComponents.count - userComponents.count)

                    if score > bestScore {
                        bestScore = score
                        bestMatch = file
                    } else if score == bestScore, let currentBest = bestMatch {
                        // Tie-breaker: prefer selected files
                        let currentIsSelected = snapshot.selectedFileFullPaths.contains(file.fullPath)
                        let bestIsSelected = snapshot.selectedFileFullPaths.contains(currentBest.fullPath)
                        if currentIsSelected, !bestIsSelected {
                            bestMatch = file
                        }
                    }
                }
            }
        }

        return bestMatch
    }

    private static func lastComponentExists(
        in snapshot: PathMatchSnapshot,
        lastComponent: String,
        threshold: Double
    ) -> Bool {
        let cleanedLast = cleaned(lastComponent)
        guard !cleanedLast.isEmpty else { return false }

        // O(1) checks using indexes
        let key = snapshot.canonical(cleanedLast)
        if let arr = snapshot.indexes.byFileName[key], !arr.isEmpty {
            return true
        }
        let ext = (cleanedLast as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let arr = snapshot.indexes.byExtension[ext], !arr.isEmpty {
            return true
        }

        // Allow progress if indexes can't preconfirm existence
        return true
    }

    private static func lastComponentExists(
        in allItems: [AnyItem],
        lastComponent: String,
        threshold: Double
    ) -> Bool {
        let cleanedLast = cleaned(lastComponent)
        guard !cleanedLast.isEmpty else { return false }

        // Precompute lowercase forms and split into base/ext once
        let lastLower = cleanedLast.lowercased()
        let lastExt = (cleanedLast as NSString).pathExtension.lowercased()
        let lastBaseLower = ((cleanedLast as NSString).deletingPathExtension).lowercased()

        // Known code-ish extensions where we want to be more tolerant in the pre-check
        let lenientExts: Set = [
            "java", "kt", "kts", "scala", "groovy",
            "swift", "m", "mm", "c", "cc", "cpp", "cxx", "hpp", "hh", "h",
            "js", "mjs", "cjs", "jsx", "ts", "tsx", "css",
            "py", "rb", "php", "rs", "go", "dart"
        ]

        // Slightly lowered threshold for base-name comparison in lenient mode
        let loweredThreshold = max(threshold - 0.05, 0.75)

        for item in allItems {
            let cleanedName = cleaned(item.name)
            let nameLower = cleanedName.lowercased()

            // 1) Fast path: exact filename (case-insensitive)
            if lastLower == nameLower {
                return true
            }

            // Derive candidate extension/base
            let itemExt = (cleanedName as NSString).pathExtension.lowercased()
            let itemBaseLower = ((cleanedName as NSString).deletingPathExtension).lowercased()

            // Decide leniency per candidate: if either the user's ext or the item's ext is a known code ext
            let pairIsCodey = (!lastExt.isEmpty && lenientExts.contains(lastExt))
                || (!itemExt.isEmpty && lenientExts.contains(itemExt))

            if pairIsCodey {
                // 2) Extension-aware lenient checks

                if lastExt.isEmpty {
                    // User omitted extension: compare against base name
                    if lastBaseLower == itemBaseLower { return true }

                    // Allow truncated typing for long basenames (only if reasonably specific)
                    if lastBaseLower.count >= 5, itemBaseLower.hasPrefix(lastBaseLower) {
                        return true
                    }

                    // Slightly lowered threshold for base-name similarity (heap-safe)
                    if similarityScoreMax(lastBaseLower, itemBaseLower, threshold: loweredThreshold, caseSensitive: true) >= loweredThreshold {
                        return true
                    }
                } else {
                    // User provided an extension
                    if lastExt == itemExt {
                        // Same code extension: base-name similarity with lowered threshold (heap-safe)
                        if similarityScoreMax(lastBaseLower, itemBaseLower, threshold: loweredThreshold, caseSensitive: true) >= loweredThreshold {
                            return true
                        }
                    } else if lenientExts.contains(lastExt), lenientExts.contains(itemExt) {
                        // Different code extensions (e.g., Foo.java vs Foo.kt): allow exact base-name equality
                        if lastBaseLower == itemBaseLower {
                            return true
                        }
                    }
                }

                // As a fallback in lenient mode, allow overall filename similarity at the normal threshold (heap-safe)
                if similarityScoreMax(lastLower, nameLower, threshold: threshold, caseSensitive: true) >= threshold {
                    return true
                }

                // Skip strict prefilters in lenient mode; continue scanning remaining items
                continue
            }

            // 3) Default heuristics for non-lenient cases
            if !lastLower.isEmpty, !nameLower.isEmpty {
                if lastLower.first != nameLower.first {
                    continue
                }
            }

            // Keep relaxed length variance to avoid false negatives on long names
            if abs(cleanedLast.count - cleanedName.count) > 32 {
                continue
            }

            // Heap-safe similarity check
            let sim = similarityScoreMax(lastLower, nameLower, threshold: threshold, caseSensitive: true)
            if sim >= threshold {
                return true
            }
        }

        return false
    }

    private static func fuzzyMatchWithSuffixLimit(
        fullPath: String,
        userComponents: [String],
        suffixCount: Int,
        exactMatchOnly: Bool,
        snapshot: PathMatchSnapshot
    ) -> PathMatchLocation? {
        let threshold = exactMatchOnly ? 0.9999 : 0.9
        let relevantComps = Array(userComponents.suffix(suffixCount))
        let relevantCompsClean = relevantComps.map { cleaned($0) }

        if Self.isLoggingEnabled {
            print("\n--- fuzzyMatchWithSuffixLimit ---")
            print("- suffixCount: \(suffixCount)")
            print("- relevantComps: \(relevantComps)")
            print("- threshold: \(threshold)")
        }

        // Index-driven candidates
        let candidates = candidatesFor(
            userComponents: userComponents,
            snapshot: snapshot,
            suffixCount: suffixCount
        )
        let rootsWithSel = rootsWithSelection(snapshot)

        var bestScore = -Double.infinity
        var bestItem: (folder: FolderRecord?, file: FileRecord?)?
        var candidateCount = 0

        for item in candidates {
            if let rawScore = computeWeightedMatchScorePrecleaned(
                item: item,
                userComponentsClean: relevantCompsClean,
                threshold: threshold
            ) {
                // Apply root-selection bonus
                let adjustedScore: Double = switch item {
                case let .file(f): rawScore + (rootsWithSel.contains(f.rootFolderPath) ? rootSelectionBonus : 0.0)
                case let .folder(f): rawScore + (rootsWithSel.contains(f.rootPath) ? rootSelectionBonus : 0.0)
                }

                candidateCount += 1

                if Self.isLoggingEnabled, candidateCount <= 5 {
                    print("  Candidate \(candidateCount): \(item.relativePath) - adjusted: \(adjustedScore)")
                }

                if adjustedScore > bestScore {
                    bestScore = adjustedScore
                    switch item {
                    case let .folder(f): bestItem = (f, nil)
                    case let .file(f): bestItem = (nil, f)
                    }

                    if Self.isLoggingEnabled {
                        print("  New best: \(item.relativePath) with score \(adjustedScore)")
                    }
                } else if adjustedScore == bestScore, bestItem != nil {
                    // Tie-breaker: prefer selected files
                    if case let .file(currentFile) = item,
                       let (_, existingFile) = bestItem,
                       let existingFileRecord = existingFile
                    {
                        let currentIsSelected = snapshot.selectedFileFullPaths.contains(currentFile.fullPath)
                        let existingIsSelected = snapshot.selectedFileFullPaths.contains(existingFileRecord.fullPath)

                        if currentIsSelected, !existingIsSelected {
                            bestItem = (nil, currentFile)
                        }
                    }
                }
            }
        }

        if Self.isLoggingEnabled {
            if candidateCount > 5 {
                print("  ... and \(candidateCount - 5) more candidates")
            }
            print("  Total candidates evaluated: \(candidateCount)")
        }

        guard let (foundFolder, foundFile) = bestItem else {
            if Self.isLoggingEnabled {
                print("  No suitable match found")
            }
            return nil
        }

        if Self.isLoggingEnabled {
            let path = foundFolder?.relativePath ?? foundFile?.relativePath ?? "unknown"
            print("  Final selection: \(path) with score \(bestScore)")
        }

        return makeLocation(folder: foundFolder, file: foundFile)
    }

    /// Variant that expects user components already cleaned (reduces per-candidate work).
    private static func computeWeightedMatchScorePrecleaned(
        item: AnyItem,
        userComponentsClean: [String],
        threshold: Double
    ) -> Double? {
        let pathComponents = item.relativePath.split(separator: "/")

        // Require at least as many path components as user components
        guard pathComponents.count >= userComponentsClean.count else { return nil }

        var totalScore = 0.0
        var matchedCount = 0

        // Match from right to left (suffix first)
        for i in 0 ..< userComponentsClean.count {
            let userIndex = userComponentsClean.count - 1 - i
            let pathIndex = pathComponents.count - 1 - i

            let userComp = userComponentsClean[userIndex]
            let pathComp = cleaned(String(pathComponents[pathIndex]))

            // Early exit: compare first *alphanumeric* char (ignores leading '_' / '-')
            if let uf = firstAlnumLowercasedByte(userComp),
               let pf = firstAlnumLowercasedByte(pathComp),
               uf != pf
            {
                return nil
            }

            // Early exit: check length difference
            if abs(userComp.count - pathComp.count) > 6 {
                return nil
            }

            // For the last component (file name), use stricter threshold
            let componentThreshold = (i == 0) ? threshold + 0.05 : threshold

            // Heap-safe similarity with separator folding
            let sim = similarityScoreMax(
                userComp,
                pathComp,
                threshold: componentThreshold,
                caseSensitive: false // userComponentsClean are already cleaned/canonicalized
            )

            if sim < componentThreshold {
                return nil
            }

            // Weight: 2 for filename, 1 for directories
            let weight = (i == 0) ? 2.0 : 1.0
            totalScore += sim * weight
            matchedCount += 1
        }

        // Depth penalty: -1 for each extra directory
        let depthPenalty = Double(pathComponents.count - userComponentsClean.count)

        // Match count bonus: +0.1 for each matched component
        let matchBonus = Double(matchedCount) * 0.1

        return totalScore - depthPenalty + matchBonus
    }

    /// Legacy wrapper kept for call-sites that haven’t been updated (e.g., missing-component fallback).
    @inline(__always)
    private static func computeWeightedMatchScore(
        item: AnyItem,
        userComponents: [String],
        threshold: Double
    ) -> Double? {
        computeWeightedMatchScorePrecleaned(
            item: item,
            userComponentsClean: userComponents.map { cleaned($0) },
            threshold: threshold
        )
    }

    // MARK: - Missing Component Tolerance

    private static func findBestMatchWithOneMissingComponent(
        userComponents: [String],
        exactMatchOnly: Bool,
        snapshot: PathMatchSnapshot
    ) -> FileRecord? {
        guard userComponents.count >= 2 else { return nil }

        let threshold = exactMatchOnly ? 0.9999 : 0.85
        var bestMatch: FileRecord?
        var bestScore = -Double.infinity

        // Try removing one component at a time
        for skipIndex in 0 ..< userComponents.count {
            var adjustedComponents = userComponents
            adjustedComponents.remove(at: skipIndex)

            let allItems = gatherAllFolderAndFileItems(snapshot: snapshot)

            for item in allItems {
                guard case let .file(file) = item else { continue }

                if let score = computeWeightedMatchScore(
                    item: .file(file),
                    userComponents: adjustedComponents,
                    threshold: threshold
                ) {
                    // Apply stronger penalty for missing component
                    let penalizedScore = score - 1.25

                    // When scores are equal, prefer shallower paths
                    let currentDepth = file.relativePath.split(separator: "/").count
                    let bestDepth = bestMatch?.relativePath.split(separator: "/").count ?? Int.max

                    if penalizedScore > bestScore || (penalizedScore == bestScore && currentDepth < bestDepth) {
                        bestScore = penalizedScore
                        bestMatch = file
                    }
                }
            }
        }

        return bestMatch
    }

    // MARK: - Item Gathering

    private static func gatherAllFolderAndFileItems(snapshot: PathMatchSnapshot) -> [AnyItem] {
        var result = [AnyItem]()

        // Add all files from the filesByFullPath dictionary
        for (_, file) in snapshot.filesByFullPath {
            result.append(.file(file))
        }

        // Add all folders from the foldersByFullPath dictionary
        for (_, folder) in snapshot.foldersByFullPath {
            result.append(.folder(folder))
        }

        return result
    }
}

// MARK: - PathMatchSnapshot Extensions

private extension PathMatchSnapshot {
    func file(_ full: String) -> FileRecord? {
        fileRecord(forFullPath: full)
    }

    func folder(_ full: String) -> FolderRecord? {
        folderRecord(forFullPath: full)
    }
}
