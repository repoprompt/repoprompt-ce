import Foundation

private struct BenchmarkNoiseConfig {
    let lineCount: Int
}

struct BenchmarkGeneratedSeed {
    let seed: UInt32
    var fileSystem: BenchmarkMockFileSystem
    let baseline: BenchmarkMockFileSystemSnapshot
    let tasks: [BenchmarkTaskSpec]
}

struct BenchmarkTaskGenerator {
    /// Primary TypeScript work file for cumulative tasks.
    private let tsWorkPath = "src/ts/work/Work.ts"
    private let swiftWorkPath = "src/swift/work/Work.swift"
    private let goWorkPath = "src/go/work/Work.go"

    func generateSeed(_ seed: UInt32, config: BenchConfig, language: BenchmarkLanguage? = nil, subseedIndex: Int = 0) -> BenchmarkGeneratedSeed {
        var rng = Mulberry32(seed: seed)
        var fileSystem = BenchmarkMockFileSystem()
        var tasks: [BenchmarkTaskSpec] = []
        let noiseConfig = BenchmarkNoiseConfig(lineCount: targetLineCount(config))
        let taskLanguage = language ?? .ts

        // Pre-warm project once per seed
        let layout = BenchmarkProjectScaffolder.scaffoldProject(
            language: taskLanguage,
            rng: &rng,
            config: config,
            noise: noiseConfig.lineCount,
            into: &fileSystem
        )

        let difficulties = config.difficultyPlan()
        let casePlan = scheduleCasePlan(for: taskLanguage, difficulties: difficulties, subseedIndex: subseedIndex, enabled: config.enabledTypes)

        for (index, difficulty) in difficulties.enumerated() {
            guard index < casePlan.count else { break }
            let caseType = casePlan[index]
            if let task = generateTask(
                of: caseType,
                difficulty: difficulty,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                noise: noiseConfig,
                language: taskLanguage,
                layout: layout
            ) {
                tasks.append(task)
            }
        }

        let baseline = fileSystem.snapshot()
        return BenchmarkGeneratedSeed(seed: seed, fileSystem: fileSystem, baseline: baseline, tasks: tasks)
    }

    private func balancedTypePlan(count: Int, enabled: [BenchmarkCaseType], rng: inout Mulberry32, language: BenchmarkLanguage?) -> [BenchmarkCaseType] {
        guard count > 0, !enabled.isEmpty else { return [] }
        let filtered = language.flatMap { lang -> [BenchmarkCaseType]? in
            let subset = enabled.filter { typeBelongsToLanguage($0, lang) }
            return subset.isEmpty ? nil : subset
        } ?? enabled
        guard !filtered.isEmpty else { return [] }
        let order = filtered
        var planned: [BenchmarkCaseType] = []
        while planned.count < count {
            planned.append(contentsOf: order)
        }
        if planned.count > count {
            planned.removeLast(planned.count - count)
        }
        return planned
    }

    // MARK: - Difficulty-aware case scheduling

    private func casePool(for language: BenchmarkLanguage, difficulty: BenchmarkDifficulty) -> [BenchmarkCaseType] {
        switch (language, difficulty) {
        case (.ts, .medium):
            [.renameExportImportsTs, .removeXTs, .swapArgsInRegionTs, .indexOnlyAppsTs, .curlyFixTs]
        case (.ts, .hard):
            [.patchBlockTs, .insertGuardTs, .insertFunctionBottomTs]
        case (.ts, .veryHard):
            [.applyUnifiedPatchTs, .moveFunctionTs]
        case (.go, .medium):
            [.renameExportImportsGo, .removeXGo, .swapArgsInRegionGo, .indexOnlyAppsGo, .curlyFixGo, .moveFunctionGo]
        case (.go, .hard):
            [.insertFunctionBottomGo, .insertGuardGo, .patchBlockGo, .applyUnifiedPatchGo]
        case (.go, .veryHard):
            // Promote to VH using existing "VeryHard gauntlet" and multi-file exactness
            [.applyUnifiedPatchGo, .patchBlockGo]
        case (.swift, .medium):
            [.swapArgsInRegionSwift, .indexOnlyAppsSwift, .insertFunctionBottomSwift]
        case (.swift, .hard):
            [.moveFunctionSwift, .insertGuardSwift, .patchBlockSwift]
        case (.swift, .veryHard):
            // Provide VH options: unified patch gauntlet, exact block patching, and strengthened move_function
            [.applyUnifiedPatchSwift, .patchBlockSwift, .moveFunctionSwift]
        default:
            []
        }
    }

    private func scheduleCasePlan(for language: BenchmarkLanguage, difficulties: [BenchmarkDifficulty], subseedIndex: Int, enabled: [BenchmarkCaseType] = []) -> [BenchmarkCaseType] {
        var arr: [BenchmarkCaseType] = []

        for (i, diff) in difficulties.enumerated() {
            func pick(from pool: [BenchmarkCaseType]) -> BenchmarkCaseType? {
                let filtered = pool.filter { enabled.isEmpty || enabled.contains($0) }
                guard !filtered.isEmpty else { return nil }
                let idx = (subseedIndex + i) % filtered.count
                return filtered[idx]
            }

            // Try native pool for current difficulty
            var pool = casePool(for: language, difficulty: diff)
            if let chosen = pick(from: pool) {
                arr.append(chosen)
                continue
            }

            // Fallback to next-lower difficulty
            if diff == .veryHard {
                pool = casePool(for: language, difficulty: .hard)
                if let chosen = pick(from: pool) {
                    arr.append(chosen)
                    continue
                }
            }
            if diff == .hard {
                pool = casePool(for: language, difficulty: .medium)
                if let chosen = pick(from: pool) {
                    arr.append(chosen)
                    continue
                }
            }

            // Last resort: any enabled case for language
            let anyEnabledForLanguage = BenchmarkCaseType.allCases.filter {
                typeBelongsToLanguage($0, language) && (enabled.isEmpty || enabled.contains($0))
            }
            if let fallback = anyEnabledForLanguage.first {
                arr.append(fallback)
            }
            // else: omit slot
        }
        return arr
    }

    /// Legacy scheduler (kept for backward compatibility if needed)
    private func scheduleCasePlan(for language: BenchmarkLanguage, count: Int, subseedIndex: Int = 0) -> [BenchmarkCaseType] {
        let canonical: [BenchmarkCaseType] = switch language {
        case .ts:
            // TypeScript: 5 subseeds × 6 tasks = 30 tasks
            // Weighted to repeat more challenging tasks across all subseeds
            // Each subseed has diverse coverage of task types
            //   Subseed 1: curlyFix, insertGuard, patchBlock, rename, swapArgs, patch
            //   Subseed 2: moveFunction, removeX, insertBottom, rename, indexOnly, patch
            //   Subseed 3: swapArgs, patchBlock, moveFunction, indexOnly, insertBottom, patch
            //   Subseed 4: removeX, insertGuard, rename, patchBlock, moveFunction, patch
            //   Subseed 5: curlyFix, swapArgs, insertBottom, rename, indexOnly, patch
            [
                // Subseed 1 (warmup + fundamentals)
                .curlyFixTs,
                .insertGuardTs,
                .patchBlockTs,
                .renameExportImportsTs,
                .swapArgsInRegionTs,
                .applyUnifiedPatchTs,
                // Subseed 2 (advanced multi-file)
                .moveFunctionTs,
                .removeXTs,
                .insertFunctionBottomTs,
                .renameExportImportsTs,
                .indexOnlyAppsTs,
                .applyUnifiedPatchTs,
                // Subseed 3 (mixed complexity)
                .swapArgsInRegionTs,
                .patchBlockTs,
                .moveFunctionTs,
                .indexOnlyAppsTs,
                .insertFunctionBottomTs,
                .applyUnifiedPatchTs,
                // Subseed 4 (comprehensive coverage)
                .removeXTs,
                .insertGuardTs,
                .renameExportImportsTs,
                .patchBlockTs,
                .moveFunctionTs,
                .applyUnifiedPatchTs,
                // Subseed 5 (reinforcement)
                .curlyFixTs,
                .swapArgsInRegionTs,
                .insertFunctionBottomTs,
                .renameExportImportsTs,
                .indexOnlyAppsTs,
                .applyUnifiedPatchTs
            ]
        case .go:
            // Go: 5 subseeds × 6 tasks = 30 tasks
            // Comprehensive coverage across all task types
            [
                // Subseed 1 (warmup + fundamentals)
                .curlyFixGo,
                .insertGuardGo,
                .patchBlockGo,
                .renameExportImportsGo,
                .swapArgsInRegionGo,
                .applyUnifiedPatchGo,
                // Subseed 2 (advanced multi-file)
                .moveFunctionGo,
                .removeXGo,
                .insertFunctionBottomGo,
                .renameExportImportsGo,
                .indexOnlyAppsGo,
                .applyUnifiedPatchGo,
                // Subseed 3 (mixed complexity)
                .swapArgsInRegionGo,
                .patchBlockGo,
                .moveFunctionGo,
                .indexOnlyAppsGo,
                .insertFunctionBottomGo,
                .applyUnifiedPatchGo,
                // Subseed 4 (comprehensive coverage)
                .removeXGo,
                .insertGuardGo,
                .renameExportImportsGo,
                .patchBlockGo,
                .moveFunctionGo,
                .applyUnifiedPatchGo,
                // Subseed 5 (reinforcement)
                .curlyFixGo,
                .swapArgsInRegionGo,
                .insertFunctionBottomGo,
                .renameExportImportsGo,
                .indexOnlyAppsGo,
                .applyUnifiedPatchGo
            ]
        case .swift:
            // Swift: 5 subseeds × 6 tasks = 30 tasks
            // Comprehensive coverage across all task types
            [
                // Subseed 1 (warmup + fundamentals)
                .curlyFixSwift,
                .insertGuardSwift,
                .patchBlockSwift,
                .renameExportImportsSwift,
                .swapArgsInRegionSwift,
                .applyUnifiedPatchSwift,
                // Subseed 2 (advanced multi-file)
                .moveFunctionSwift,
                .removeXSwift,
                .insertFunctionBottomSwift,
                .renameExportImportsSwift,
                .indexOnlyAppsSwift,
                .applyUnifiedPatchSwift,
                // Subseed 3 (mixed complexity)
                .swapArgsInRegionSwift,
                .patchBlockSwift,
                .moveFunctionSwift,
                .indexOnlyAppsSwift,
                .insertFunctionBottomSwift,
                .applyUnifiedPatchSwift,
                // Subseed 4 (comprehensive coverage)
                .removeXSwift,
                .insertGuardSwift,
                .renameExportImportsSwift,
                .patchBlockSwift,
                .moveFunctionSwift,
                .applyUnifiedPatchSwift,
                // Subseed 5 (reinforcement)
                .curlyFixSwift,
                .swapArgsInRegionSwift,
                .insertFunctionBottomSwift,
                .renameExportImportsSwift,
                .indexOnlyAppsSwift,
                .applyUnifiedPatchSwift
            ]
        }

        // Calculate the starting index for this subseed
        let startIndex = subseedIndex * count

        // If the requested slice fits within canonical, return it
        if startIndex + count <= canonical.count {
            return Array(canonical[startIndex ..< (startIndex + count)])
        }

        // Otherwise, wrap around and repeat the canonical plan as needed
        var plan: [BenchmarkCaseType] = []
        for i in 0 ..< count {
            let index = (startIndex + i) % canonical.count
            plan.append(canonical[index])
        }
        return plan
    }

    private func typeBelongsToLanguage(_ type: BenchmarkCaseType, _ language: BenchmarkLanguage) -> Bool {
        switch type {
        case .curlyFixGo:
            language == .go
        default:
            true
        }
    }

    private func targetLineCount(_ config: BenchConfig) -> Int {
        if let override = config.sizeLines {
            return max(override, 40)
        }
        switch config.size {
        case .small: return 120
        case .medium: return 320
        case .large: return 640
        }
    }

    // MARK: - Task routing

    private func generateTask(
        of type: BenchmarkCaseType,
        difficulty: BenchmarkDifficulty,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        language: BenchmarkLanguage,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec? {
        switch type {
        case .removeXTs, .removeXGo, .removeXSwift:
            generateRemoveXTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                noise: noise,
                difficulty: difficulty,
                layout: layout
            )
        case .curlyFixTs, .curlyFixGo, .curlyFixSwift:
            generateCurlyFixTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                noise: noise,
                difficulty: difficulty,
                layout: layout
            )
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
            generateInsertGuardTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                noise: noise,
                difficulty: difficulty,
                layout: layout
            )
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
            generatePatchBlockTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                noise: noise,
                difficulty: difficulty,
                layout: layout
            )
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            generateSwapArgsTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                noise: noise,
                difficulty: difficulty,
                layout: layout
            )
        case .indexOnlyAppsTs, .indexOnlyAppsGo, .indexOnlyAppsSwift:
            generateIndexOnlyTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                difficulty: difficulty,
                layout: layout
            )
        case .renameExportImportsTs, .renameExportImportsGo, .renameExportImportsSwift:
            generateRenameExportsTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                difficulty: difficulty,
                layout: layout
            )
        case .moveFunctionTs, .moveFunctionGo, .moveFunctionSwift:
            generateMoveFunctionTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                difficulty: difficulty,
                layout: layout
            )
        case .insertFunctionBottomTs, .insertFunctionBottomGo, .insertFunctionBottomSwift:
            generateInsertFunctionBottomTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                difficulty: difficulty,
                layout: layout
            )
        case .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
            generateUnifiedPatchTaskFor(
                language: language,
                rng: &rng,
                fileSystem: &fileSystem,
                config: config,
                difficulty: difficulty,
                layout: layout
            )
        }
    }

    // MARK: - Language dispatch helpers

    private func generateRemoveXTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateRemoveXTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .go:
            generateRemoveXGoTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .swift:
            generateRemoveXSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        }
    }

    private func generateCurlyFixTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateCurlyFixTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .go:
            generateCurlyFixGoTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .swift:
            generateCurlyFixSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        }
    }

    private func generateInsertGuardTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateInsertGuardTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .go:
            generateInsertGuardGoTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .swift:
            generateInsertGuardSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        }
    }

    private func generatePatchBlockTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generatePatchBlockTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .go:
            generatePatchBlockGoTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .swift:
            generatePatchBlockSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        }
    }

    private func generateSwapArgsTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateSwapArgsTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .go:
            generateSwapArgsGoTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        case .swift:
            generateSwapArgsSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, noise: noise, difficulty: difficulty, layout: layout)
        }
    }

    private func generateIndexOnlyTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateIndexOnlyTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .go:
            generateIndexOnlyGoTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .swift:
            generateIndexOnlySwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        }
    }

    private func generateRenameExportsTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateRenameExportsTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .go:
            generateRenameExportsGoTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .swift:
            generateRenameExportsSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        }
    }

    private func generateMoveFunctionTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateMoveFunctionTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .go:
            generateMoveFunctionGoTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .swift:
            generateMoveFunctionSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        }
    }

    private func generateInsertFunctionBottomTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateInsertFunctionBottomTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .go:
            generateInsertFunctionBottomGoTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .swift:
            generateInsertFunctionBottomSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        }
    }

    private func generateUnifiedPatchTaskFor(
        language: BenchmarkLanguage,
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        switch language {
        case .ts:
            generateUnifiedPatchTsTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .go:
            generateUnifiedPatchGoTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        case .swift:
            generateUnifiedPatchSwiftTask(rng: &rng, fileSystem: &fileSystem, config: config, difficulty: difficulty, layout: layout)
        }
    }

    // MARK: - remove_x_ts

    private func generateRemoveXTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let path = tsWorkPath
        let decoyCount = decoyCount(for: difficulty, config: config)
        var existing = fileSystem.content(for: path) ?? ""
        var lines: [String] = []
        lines.append("export function alpha(values: number[]): number {")
        lines.append("    let total = 0;")
        lines.append("    for (const value of values) {")
        lines.append("        total += CALL_X(value);")
        if difficultyIsAtLeastHard(difficulty) {
            lines.append("        total += call_x(value); // near miss lower case")
            lines.append("        total += CALL_XY(value); // near miss suffix")
            lines.append("        if (value % 2 === 0) {")
            lines.append("            const computed = CALL_X(CALL_X(value * 2));")
            lines.append("            total += computed;")
            lines.append("            // CALL_X should be removed even in comments? Keep comment text")
            lines.append("        }")
        }
        lines.append("    }")
        lines.append("    return total;")
        lines.append("}")
        if !existing.isEmpty && !existing.hasSuffix("\n") {
            existing.append("\n")
        }
        existing.append(lines.joined(separator: "\n"))
        if !existing.contains("/* auto-generated believable TS module */") {
            let approxLines = scaledLines(noise.lineCount, difficulty: .hard)
            let helper = BelievableCodeFactory.tsUtilityModule(rng: &rng, module: "AlphaSupport", approxLines: approxLines)
            existing.append("\n")
            existing.append(helper)
        }
        fileSystem.setFile(path, content: existing)
        let fullDecoys = decoyCount > 0 ? makeSimilarTsDecoys(rng: &rng, around: path) : []
        for decoy in fullDecoys {
            fileSystem.setFile(decoy.path, content: decoy.content)
        }
        let instructions = [
            "Remove all CALL_X() invocations from the specified file using search-replace edits.",
            "CALL_X appears with an opening parenthesis: CALL_X(value).",
            "Do NOT modify near-miss tokens: call_x (lowercase) or CALL_XY (different suffix).",
            "Do NOT remove CALL_X from comments - only remove actual function calls.",
            "Do NOT rewrite the entire file - use targeted edits only."
        ]
        let acceptance = [
            "All CALL_X() invocations are removed from \(path).",
            "Other identifiers including call_x and CALL_XY remain unchanged.",
            "Comments containing CALL_X text remain unchanged."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "target": .string("CALL_X("),
            "file": .string(path),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyCount)
        ]
        if !fullDecoys.isEmpty {
            params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
        }

        if config.includeAutoPlannedDecoys {
            // Draft the task spec (pre-return) so the planner can locate the core region using current params
            let draftTask = BenchmarkTaskSpec(
                id: "remove_x_ts",
                type: .removeXTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: maxEditsRemoveX(for: difficulty),
                instructions: instructions,
                task: "Remove all CALL_X() invocations from \(path).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        // Store guidance verbosity to adjust prompt tone in the packager
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "remove_x_ts",
            type: .removeXTs,
            language: .ts,
            difficulty: difficulty,
            selectFiles: [path],
            maxEdits: maxEditsRemoveX(for: difficulty),
            instructions: instructions,
            task: "Remove all CALL_X() invocations from \(path).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - remove_x_go

    private func generateRemoveXGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let path = goWorkPath
        let decoyCount = decoyCount(for: difficulty, config: config)
        _ = noise
        var lines: [String] = []
        lines.append("package work")
        lines.append("")
        lines.append("func Alpha(values []int) int {")
        lines.append("    total := 0")
        lines.append("    for _, value := range values {")
        lines.append("        total += CALL_X(value)")
        if difficultyIsAtLeastHard(difficulty) {
            lines.append("        total += call_x(value) // near miss lower case")
            lines.append("        total += CALL_XY(value) // near miss suffix")
            lines.append("        if value%2 == 0 {")
            lines.append("            computed := CALL_X(CALL_X(value * 2))")
            lines.append("            total += computed")
            lines.append("            // CALL_X should be removed even in comments? Keep comment text")
            lines.append("        }")
        }
        lines.append("    }")
        lines.append("    return total")
        lines.append("}")
        var existing = fileSystem.content(for: path) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") {
            existing.append("\n")
        }
        existing.append(lines.joined(separator: "\n"))
        fileSystem.setFile(path, content: existing)
        var decoyPaths: [String] = []
        if decoyCount >= 1 {
            let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "WorkShadow")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        if decoyCount >= 2 {
            let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "WorkClone")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        let instructions = [
            "Remove all CALL_X() invocations from the specified file using search-replace edits.",
            "CALL_X appears with an opening parenthesis: CALL_X(value).",
            "Do NOT modify near-miss tokens: call_x (lowercase) or CALL_XY (different suffix).",
            "Do NOT remove CALL_X from comments - only remove actual function calls.",
            "Do NOT rewrite the entire file - use targeted edits only."
        ]
        let acceptance = [
            "All CALL_X() invocations are removed from \(path).",
            "Other identifiers including call_x and CALL_XY remain unchanged.",
            "Comments containing CALL_X text remain unchanged."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "target": .string("CALL_X("),
            "file": .string(path),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyCount)
        ]
        if !decoyPaths.isEmpty {
            params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "remove_x_go",
                type: .removeXGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: maxEditsRemoveX(for: difficulty),
                instructions: instructions,
                task: "Remove all CALL_X() invocations from \(path).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "remove_x_go",
            type: .removeXGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: [path],
            maxEdits: maxEditsRemoveX(for: difficulty),
            instructions: instructions,
            task: "Remove all CALL_X() invocations from \(path).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - remove_x_swift

    private func generateRemoveXSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let path = swiftWorkPath
        let decoyCount = decoyCount(for: difficulty, config: config)
        _ = noise
        var lines: [String] = []
        lines.append("public func alpha(_ values: [Int]) -> Int {")
        lines.append("\tvar total = 0")
        lines.append("\tfor value in values {")
        lines.append("\t\ttotal += CALL_X(value)")
        if difficultyIsAtLeastHard(difficulty) {
            lines.append("\t\ttotal += call_x(value) // near miss lower case")
            lines.append("\t\ttotal += CALL_XY(value) // near miss suffix")
            lines.append("\t\tif value % 2 == 0 {")
            lines.append("\t\t\tlet computed = CALL_X(CALL_X(value * 2))")
            lines.append("\t\t\ttotal += computed")
            lines.append("\t\t\t// CALL_X should be removed even in comments? Keep comment text")
            lines.append("\t\t}")
        }
        lines.append("\t}")
        lines.append("\treturn total")
        lines.append("}")
        var existing = fileSystem.content(for: path) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") {
            existing.append("\n")
        }
        existing.append(lines.joined(separator: "\n"))
        fileSystem.setFile(path, content: existing)
        var decoyPaths: [String] = []
        if decoyCount >= 1 {
            let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "WorkShadow")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        if decoyCount >= 2 {
            let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "WorkClone")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        let instructions = [
            "Remove all CALL_X() invocations from the specified file using search-replace edits.",
            "CALL_X appears with an opening parenthesis: CALL_X(value).",
            "Do NOT modify near-miss tokens: call_x (lowercase) or CALL_XY (different suffix).",
            "Do NOT remove CALL_X from comments - only remove actual function calls.",
            "Do NOT rewrite the entire file - use targeted edits only."
        ]
        let acceptance = [
            "All CALL_X() invocations are removed from \(path).",
            "Other identifiers including call_x and CALL_XY remain unchanged.",
            "Comments containing CALL_X text remain unchanged."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "target": .string("CALL_X("),
            "file": .string(path),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyCount)
        ]
        if !decoyPaths.isEmpty {
            params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "remove_x_swift",
                type: .removeXSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: maxEditsRemoveX(for: difficulty),
                instructions: instructions,
                task: "Remove all CALL_X() invocations from \(path).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "remove_x_swift",
            type: .removeXSwift,
            language: .swift,
            difficulty: difficulty,
            selectFiles: [path],
            maxEdits: maxEditsRemoveX(for: difficulty),
            instructions: instructions,
            task: "Remove all CALL_X() invocations from \(path).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - curly_fix_go

    private func generateCurlyFixGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let suffix = randomIdentifier(rng: &rng)
        let files: [String]
        let regions: Int // number of defect regions per file
        let minEdits: Int // minimum edits per file
        switch difficulty {
        case .medium:
            files = ["src/go/main_\(suffix).go"]
            regions = 2
            minEdits = 2
        case .hard:
            files = ["src/go/main_\(suffix)_a.go", "src/go/main_\(suffix)_b.go"]
            regions = 3
            minEdits = 2
        case .veryHard:
            files = ["src/go/main_\(suffix)_a.go", "src/go/main_\(suffix)_b.go", "src/go/main_\(suffix)_c.go"]
            regions = 3
            minEdits = 3
        case .simple:
            files = ["src/go/main_\(suffix).go"]
            regions = 2
            minEdits = 2
        }
        let decoyCount = decoyCount(for: difficulty, config: config)

        // Generate files with multi-region brace defects
        for path in files {
            var lines: [String] = []
            lines.append("package main")
            lines.append("")
            lines.append("import \"fmt\"")
            lines.append("")
            lines.append("func main() {")
            lines.append("    sum := 0")
            lines.append("")

            // Region A: for loop with nested if (missing 2 braces)
            lines.append("    for i := 0; i < 5; i++ {")
            lines.append("        sum += i")
            lines.append("        if i%2 == 0 {")
            lines.append("            sum += i")
            // Missing closing brace for if
            // Missing closing brace for for

            lines.append("")
            lines.append("    // Decoy brace noise: }")
            lines.append("    braceStr := \"}\"")
            lines.append("")

            if regions >= 2 {
                // Region B: another loop (missing 1 brace)
                lines.append("    for j := 0; j < 3; j++ {")
                lines.append("        sum += j")
                // Missing closing brace for this for
            }

            lines.append("")

            if regions >= 3 {
                // Region C: switch statement (missing 1 brace)
                lines.append("    switch sum % 2 {")
                lines.append("    case 0:")
                lines.append("        sum++")
                // Missing closing brace for switch
                lines.append("")
            }

            lines.append("    _ = braceStr  // more brace noise: \"}\"")
            lines.append("    fmt.Println(sum)")
            lines.append("}") // closing main

            fileSystem.setFile(path, content: lines.joined(separator: "\n"))
        }
        let approxLines = max(20, scaledLines(noise.lineCount / 2, difficulty: difficulty))
        let goHelper = BelievableCodeFactory.goUtilityModule(rng: &rng, pkg: "extras", approxLines: approxLines)
        fileSystem.setFile("src/go/extras/util.go", content: goHelper)

        // Add curly-specific decoys with brace noise
        var fullDecoys: [String] = []
        let curlyDecoyCount = min(decoyCount, difficulty == .medium ? 1 : (difficulty == .hard ? 2 : 3))
        for i in 0 ..< curlyDecoyCount {
            let decoy = BelievableCodeFactory.goCurlyDecoy(rng: &rng, name: "Maze\(i)")
            fileSystem.setFile(decoy.path, content: decoy.content)
            fullDecoys.append(decoy.path)
        }

        // Add regular decoys for additional context
        let regularDecoyCount = decoyCount - curlyDecoyCount
        if regularDecoyCount >= 1 {
            let decoyOne = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "WorkShadow")
            fileSystem.setFile(decoyOne.path, content: decoyOne.content)
            fullDecoys.append(decoyOne.path)
        }
        if regularDecoyCount >= 2 {
            let decoyTwo = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "WorkClone")
            fileSystem.setFile(decoyTwo.path, content: decoyTwo.content)
            fullDecoys.append(decoyTwo.path)
        }
        let instructions = [
            "Add the minimum number of closing braces (}) needed to balance the code.",
            "Ensure the fmt.Println statement executes AFTER the loop completes (not inside it).",
            "Do NOT modify any existing code - only add missing closing braces.",
            "Do NOT reformat or change indentation of existing lines."
        ]
        let acceptance = [
            "All braces are balanced (every { has a matching }).",
            "`fmt.Println(sum)` is outside the `for` loop and executes exactly once.",
            "Loop logic and all other statements remain byte-for-byte identical to baseline.",
            "Exactly \(files.count) file(s) were modified."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "files": .array(files.map { .string($0) }),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyCount),
            "fullDecoys": .array(fullDecoys.map { .string($0) }),
            "minEditsPerFile": .integer(minEdits)
        ]

        // Increase edit budget to allow multiple edits per file
        let editBudget = max(files.count * (difficulty == .medium ? 2 : (difficulty == .hard ? 3 : 4)), files.count)

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "curly_fix_go",
                type: .curlyFixGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: editBudget,
                instructions: instructions,
                task: "Fix missing closing brace(s) so braces are balanced and println follows the loop, across multiple files when listed.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "curly_fix_go",
            type: .curlyFixGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: editBudget,
            instructions: instructions,
            task: "Fix missing closing brace(s) so braces are balanced and println follows the loop, across multiple files when listed.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - curly_fix_ts

    private func generateCurlyFixTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let suffix = randomIdentifier(rng: &rng)
        let files: [String]
        let regions: Int // number of defect regions per file
        let minEdits: Int // minimum edits per file
        switch difficulty {
        case .medium:
            files = ["src/ts/main_\(suffix).ts"]
            regions = 2
            minEdits = 2
        case .hard:
            files = ["src/ts/main_\(suffix)_a.ts", "src/ts/main_\(suffix)_b.ts"]
            regions = 3
            minEdits = 2
        case .veryHard:
            files = ["src/ts/main_\(suffix)_a.ts", "src/ts/main_\(suffix)_b.ts", "src/ts/main_\(suffix)_c.ts"]
            regions = 3
            minEdits = 3
        case .simple:
            files = ["src/ts/main_\(suffix).ts"]
            regions = 2
            minEdits = 2
        }
        let decoyCount = decoyCount(for: difficulty, config: config)

        // Generate files with multi-region brace defects
        for path in files {
            var lines: [String] = []
            lines.append("// TypeScript main file")
            lines.append("")
            lines.append("import { log } from './util';")
            lines.append("")
            lines.append("function main() {")
            lines.append("    let sum = 0;")
            lines.append("")

            // Region A: for loop with nested if (missing 2 braces)
            lines.append("    for (let i = 0; i < 5; i++) {")
            lines.append("        sum += i;")
            lines.append("        if (i % 2 === 0) {")
            lines.append("            sum += i;")
            // Missing closing brace for if
            // Missing closing brace for for

            lines.append("")
            lines.append("    // Decoy brace noise: }")
            lines.append("    const braceStr = \"}\";")
            lines.append("")

            if regions >= 2 {
                // Region B: another loop (missing 1 brace)
                lines.append("    for (let j = 0; j < 3; j++) {")
                lines.append("        sum += j;")
                // Missing closing brace for this for
            }

            lines.append("")

            if regions >= 3 {
                // Region C: switch statement (missing 1 brace)
                lines.append("    switch (sum % 2) {")
                lines.append("        case 0:")
                lines.append("            sum++;")
                lines.append("            break;")
                // Missing closing brace for switch
                lines.append("")
            }

            lines.append("    void(braceStr);  // more brace noise: \"}\"")
            lines.append("    console.log(sum);")
            lines.append("}") // closing main

            fileSystem.setFile(path, content: lines.joined(separator: "\n"))
        }
        let approxLines = max(20, scaledLines(noise.lineCount / 2, difficulty: difficulty))
        let tsHelper = BelievableCodeFactory.tsUtilityModule(rng: &rng, approxLines: approxLines)
        fileSystem.setFile("src/ts/util.ts", content: tsHelper)

        // Add curly-specific decoys with brace noise
        var fullDecoys: [String] = []
        let curlyDecoyCount = min(decoyCount, difficulty == .medium ? 1 : (difficulty == .hard ? 2 : 3))
        for i in 0 ..< curlyDecoyCount {
            let decoy = BelievableCodeFactory.tsCurlyDecoy(rng: &rng, name: "Maze\(i)")
            fileSystem.setFile(decoy.path, content: decoy.content)
            fullDecoys.append(decoy.path)
        }

        // Add regular decoys for additional context
        let regularDecoyCount = decoyCount - curlyDecoyCount
        if regularDecoyCount >= 1 {
            let decoyOne = BelievableCodeFactory.tsDecoyFile(rng: &rng, name: "WorkShadow")
            fileSystem.setFile(decoyOne.path, content: decoyOne.content)
            fullDecoys.append(decoyOne.path)
        }
        if regularDecoyCount >= 2 {
            let decoyTwo = BelievableCodeFactory.tsDecoyFile(rng: &rng, name: "WorkClone")
            fileSystem.setFile(decoyTwo.path, content: decoyTwo.content)
            fullDecoys.append(decoyTwo.path)
        }

        let instructions = [
            "Add the minimum number of closing braces (}) needed to balance the code.",
            "Ensure the console.log statement executes AFTER the loop completes (not inside it).",
            "Do NOT modify any existing code - only add missing closing braces.",
            "Do NOT reformat or change indentation of existing lines."
        ]
        let acceptance = [
            "All braces are balanced (every { has a matching }).",
            "`console.log(sum)` is outside the `for` loop and executes exactly once.",
            "Loop logic and all other statements remain byte-for-byte identical to baseline.",
            "Exactly \(files.count) file(s) were modified."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "files": .array(files.map { .string($0) }),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyCount),
            "fullDecoys": .array(fullDecoys.map { .string($0) }),
            "minEditsPerFile": .integer(minEdits)
        ]

        // Increase edit budget to allow multiple edits per file
        let editBudget = max(files.count * (difficulty == .medium ? 2 : (difficulty == .hard ? 3 : 4)), files.count)

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "curly_fix_ts",
                type: .curlyFixTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: editBudget,
                instructions: instructions,
                task: "Fix missing closing brace(s) so braces are balanced and console.log follows the loop, across multiple files when listed.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "curly_fix_ts",
            type: .curlyFixTs,
            language: .ts,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: editBudget,
            instructions: instructions,
            task: "Fix missing closing brace(s) so braces are balanced and console.log follows the loop, across multiple files when listed.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - curly_fix_swift

    private func generateCurlyFixSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let suffix = randomIdentifier(rng: &rng)
        let files: [String]
        let regions: Int // number of defect regions per file
        let minEdits: Int // minimum edits per file
        switch difficulty {
        case .medium:
            files = ["src/swift/Main_\(suffix).swift"]
            regions = 2
            minEdits = 2
        case .hard:
            files = ["src/swift/Main_\(suffix)_a.swift", "src/swift/Main_\(suffix)_b.swift"]
            regions = 3
            minEdits = 2
        case .veryHard:
            files = ["src/swift/Main_\(suffix)_a.swift", "src/swift/Main_\(suffix)_b.swift", "src/swift/Main_\(suffix)_c.swift"]
            regions = 3
            minEdits = 3
        case .simple:
            files = ["src/swift/Main_\(suffix).swift"]
            regions = 2
            minEdits = 2
        }
        let decoyCount = decoyCount(for: difficulty, config: config)

        // Generate files with multi-region brace defects
        for path in files {
            var lines: [String] = []
            lines.append("import Foundation")
            lines.append("")
            lines.append("func main() {")
            lines.append("\tvar sum = 0")
            lines.append("")

            // Region A: for loop with nested if (missing 2 braces)
            lines.append("\tfor i in 0..<5 {")
            lines.append("\t\tsum += i")
            lines.append("\t\tif i % 2 == 0 {")
            lines.append("\t\t\tsum += i")
            // Missing closing brace for if
            // Missing closing brace for for

            lines.append("")
            lines.append("\t// Decoy brace noise: }")
            lines.append("\tlet braceStr = \"}\"")
            lines.append("")

            if regions >= 2 {
                // Region B: another loop (missing 1 brace)
                lines.append("\tfor j in 0..<3 {")
                lines.append("\t\tsum += j")
                // Missing closing brace for this for
            }

            lines.append("")

            if regions >= 3 {
                // Region C: switch statement (missing 1 brace)
                lines.append("\tswitch sum % 2 {")
                lines.append("\tcase 0:")
                lines.append("\t\tsum += 1")
                lines.append("\tdefault:")
                lines.append("\t\tbreak")
                // Missing closing brace for switch
                lines.append("")
            }

            lines.append("\t_ = braceStr  // more brace noise: \"}\"")
            lines.append("\tprint(sum)")
            lines.append("}") // closing main

            fileSystem.setFile(path, content: lines.joined(separator: "\n"))
        }
        let approxLines = max(20, scaledLines(noise.lineCount / 2, difficulty: difficulty))
        let swiftHelper = BelievableCodeFactory.swiftUtilityModule(rng: &rng, approxLines: approxLines)
        fileSystem.setFile("src/swift/Util.swift", content: swiftHelper)

        // Add curly-specific decoys with brace noise
        var fullDecoys: [String] = []
        let curlyDecoyCount = min(decoyCount, difficulty == .medium ? 1 : (difficulty == .hard ? 2 : 3))
        for i in 0 ..< curlyDecoyCount {
            let decoy = BelievableCodeFactory.swiftCurlyDecoy(rng: &rng, name: "Maze\(i)")
            fileSystem.setFile(decoy.path, content: decoy.content)
            fullDecoys.append(decoy.path)
        }

        // Add regular decoys for additional context
        let regularDecoyCount = decoyCount - curlyDecoyCount
        if regularDecoyCount >= 1 {
            let decoyOne = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "WorkShadow")
            fileSystem.setFile(decoyOne.path, content: decoyOne.content)
            fullDecoys.append(decoyOne.path)
        }
        if regularDecoyCount >= 2 {
            let decoyTwo = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "WorkClone")
            fileSystem.setFile(decoyTwo.path, content: decoyTwo.content)
            fullDecoys.append(decoyTwo.path)
        }

        let instructions = [
            "Add the minimum number of closing braces (}) needed to balance the code.",
            "Ensure the print statement executes AFTER the loop completes (not inside it).",
            "Do NOT modify any existing code - only add missing closing braces.",
            "Do NOT reformat or change indentation of existing lines."
        ]
        let acceptance = [
            "All braces are balanced (every { has a matching }).",
            "`print(sum)` is outside the `for` loop and executes exactly once.",
            "Loop logic and all other statements remain byte-for-byte identical to baseline.",
            "Exactly \(files.count) file(s) were modified."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "files": .array(files.map { .string($0) }),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyCount),
            "fullDecoys": .array(fullDecoys.map { .string($0) }),
            "minEditsPerFile": .integer(minEdits)
        ]

        // Increase edit budget to allow multiple edits per file
        let editBudget = max(files.count * (difficulty == .medium ? 2 : (difficulty == .hard ? 3 : 4)), files.count)

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "curly_fix_swift",
                type: .curlyFixSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: editBudget,
                instructions: instructions,
                task: "Fix missing closing brace(s) so braces are balanced and print follows the loop, across multiple files when listed.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "curly_fix_swift",
            type: .curlyFixSwift,
            language: .swift,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: editBudget,
            instructions: instructions,
            task: "Fix missing closing brace(s) so braces are balanced and print follows the loop, across multiple files when listed.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - rename_export_and_imports_go

    private func generateRenameExportsGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = rng
        _ = config
        _ = difficulty

        let exporterPath = "src/go/lib/exporter.go"
        let oldName = "OldX"
        let newName = "NewX"

        // Determine importer count by difficulty
        let importerCount = switch difficulty {
        case .simple:
            2
        case .medium:
            4
        case .hard:
            6
        case .veryHard:
            8
        }

        // Apps pool scales with difficulty (A..H)
        let apps: [String] = switch difficulty {
        case .simple, .medium:
            ["appA", "appB", "appC"]
        case .hard:
            ["appA", "appB", "appC", "appD", "appE", "appF"]
        case .veryHard:
            ["appA", "appB", "appC", "appD", "appE", "appF", "appG", "appH"]
        }

        // Build importer paths and contents
        var importers: [String] = []
        for idx in 1 ... importerCount {
            let app = apps[(idx - 1) % apps.count]
            let path = "apps/\(app)/useX_\(idx).go"
            importers.append(path)

            let content: String
            if difficulty == .hard || difficulty == .veryHard {
                // Rotate import patterns across files
                let pattern = idx % 3
                switch pattern {
                case 0:
                    // Alias import: import X "lib/exporter" then X.OldX()
                    content = """
                    package main

                    import X "lib/exporter"

                    func consume() string {
                        // \(oldName) is not used here
                        _ = "\(oldName)"
                        return X.\(oldName)()
                    }
                    """
                case 1:
                    // Package-named import: import exporter "lib/exporter" then exporter.OldX()
                    content = """
                    package main

                    import exporter "lib/exporter"

                    func consume() string {
                        // \(oldName) is not used here
                        _ = "\(oldName)"
                        return exporter.\(oldName)()
                    }
                    """
                default:
                    // Direct import: import "lib/exporter" then exporter.OldX()
                    content = """
                    package main

                    import "lib/exporter"

                    func consume() string {
                        // \(oldName) is not used here
                        _ = "\(oldName)"
                        return exporter.\(oldName)()
                    }
                    """
                }
            } else {
                // Simple/Medium: straightforward package-named import
                content = """
                package main

                import exporter "lib/exporter"

                func consume() string {
                    return exporter.\(oldName)()
                }
                """
            }

            fileSystem.setFile(path, content: content)
        }

        // Exporter with near-miss tokens that must remain unchanged
        let exporterContent = """
        package lib

        // Near-miss tokens — must remain unchanged
        const \(oldName)Helper = "helper"
        type \(oldName)Type struct{}
        const \(oldName)XY = 42

        func \(oldName)() string { return "value" }
        var Usage = \(oldName)()
        """
        fileSystem.setFile(exporterPath, content: exporterContent)

        // Instructions differ for hard/veryHard
        let instructions: [String] = {
            if difficulty == .hard || difficulty == .veryHard {
                return [
                    "Rename the exported symbol \(oldName) to \(newName) in \(exporterPath).",
                    "Update every occurrence of \(oldName) to \(newName) within the exporter file.",
                    "Update all importer files that reference this export to use \(newName) instead of \(oldName).",
                    "Import patterns include alias imports, package-named imports, and direct imports—update referenced symbol names accordingly.",
                    "Do NOT modify near-miss tokens: \(oldName)Helper, \(oldName)XY, \(oldName)Type.",
                    "Do NOT modify comments or string literals containing \"\(oldName)\"."
                ]
            } else {
                let listed = importers.joined(separator: ", ")
                return [
                    "Rename the exported symbol \(oldName) to \(newName) in \(exporterPath).",
                    "Update every occurrence of \(oldName) to \(newName) within the exporter file.",
                    "Update ONLY the listed importer files to use \(newName) instead of \(oldName): \(listed).",
                    "Each importer uses the symbol as: exporter.\(oldName)() or similar.",
                    "Do NOT search for or modify any importer files not explicitly listed."
                ]
            }
        }()

        let acceptance = [
            "\(exporterPath) exports \(newName) with zero remaining references to \(oldName).",
            "Each listed importer file references \(newName) and has zero references to \(oldName).",
            "Function/symbol behavior is unchanged - only the name changed."
        ]

        var params: [String: BenchmarkJSONValue] = [
            "rename": .object(["from": .string(oldName), "to": .string(newName)]),
            "importPaths": .array(importers.map { .string($0) }),
            "nearMissTokens": .array(["\(oldName)Helper", "\(oldName)XY", "\(oldName)Type"].map { .string($0) }),
            "difficulty": .string(difficulty.rawValue)
        ]

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "rename_export_and_imports_go",
                type: .renameExportImportsGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: [exporterPath] + importers,
                maxEdits: 10,
                instructions: instructions,
                task: difficulty == .hard || difficulty == .veryHard ?
                    "Rename \(oldName) to \(newName) in exporter.go and update all importers that reference this symbol." :
                    "Rename \(oldName) to \(newName) in exporter.go and the listed importers.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "rename_export_and_imports_go",
            type: .renameExportImportsGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: [exporterPath] + importers,
            maxEdits: 10,
            instructions: instructions,
            task: difficulty == .hard || difficulty == .veryHard ?
                "Rename \(oldName) to \(newName) in exporter.go and update all importers that reference this symbol." :
                "Rename \(oldName) to \(newName) in exporter.go and the listed importers.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - rename_export_and_imports_swift

    private func generateRenameExportsSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = rng
        _ = config
        _ = difficulty
        let exporterPath = "Sources/Lib/Exporter.swift"
        let importers = [
            "Apps/appA/UseX_1.swift",
            "Apps/appB/UseX_2.swift",
            "Apps/appB/UseX_3.swift"
        ]
        let oldName = "OldX"
        let newName = "NewX"
        let exporterContent = "public func \(oldName)() -> String {\n\treturn \"value\"\n}\n\npublic let usage = \(oldName)()\n"
        fileSystem.setFile(exporterPath, content: exporterContent)
        for path in importers {
            let content = "import Lib\n\npublic func consume() -> String {\n\treturn \(oldName)()\n}\n"
            fileSystem.setFile(path, content: content)
        }
        let instructions = [
            "Rename the exported symbol \(oldName) to \(newName) in \(exporterPath).",
            "Update every occurrence of \(oldName) to \(newName) within the exporter file.",
            "Update ONLY the listed importer files to use \(newName) instead of \(oldName).",
            "Each importer uses the symbol directly as: \(oldName)().",
            "Do NOT search for or modify any importer files not explicitly listed."
        ]
        let acceptance = [
            "\(exporterPath) exports \(newName) with zero remaining references to \(oldName).",
            "Each listed importer file references \(newName) and has zero references to \(oldName).",
            "The total number of edits matches: 1 exporter + \(importers.count) importers.",
            "Function/symbol behavior is unchanged - only the name changed."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "rename": .object(["from": .string(oldName), "to": .string(newName)]),
            "importPaths": .array(importers.map { .string($0) }),
            "difficulty": .string(difficulty.rawValue)
        ]

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "rename_export_and_imports_swift",
                type: .renameExportImportsSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: [exporterPath] + importers,
                maxEdits: 8,
                instructions: instructions,
                task: "Rename \(oldName) to \(newName) in Exporter.swift and the listed importers.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "rename_export_and_imports_swift",
            type: .renameExportImportsSwift,
            language: .swift,
            difficulty: difficulty,
            selectFiles: [exporterPath] + importers,
            maxEdits: 8,
            instructions: instructions,
            task: "Rename \(oldName) to \(newName) in Exporter.swift and the listed importers.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - move_function_ts

    private func generateMoveFunctionTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = config
        _ = difficulty
        if difficulty == .hard {
            let token = randomIdentifier(rng: &rng)
            let path = "src/ts/reorder/Order_\(token).ts"
            // Similar function names to create ambiguity
            let fnNames = ["alpha", "alphaHelper", "alphaUtil", "bravo", "bravoHelper", "charlie", "delta"]
            var lines: [String] = []
            for (index, name) in fnNames.enumerated() {
                // Leading doc comment to test preservation
                lines.append("/** \(name) computes value */")
                lines.append("export function \(name)(n: number): number {")
                lines.append("    return n * \(index + 1);")
                lines.append("}")
                lines.append("")
            }
            lines.append("// FOOTER: keep below here unchanged")
            fileSystem.setFile(path, content: lines.joined(separator: "\n"))

            // HARD: Multi-move parameters (do not provide explicit single from/after in top-level instructions)
            let instructions = [
                "Move the specified functions to maintain logical grouping; preserve any leading documentation/comments; do not duplicate.",
                "Preserve exact spacing/blank lines between other functions.",
                "The moved functions' content and leading doc comments must remain byte-for-byte identical.",
                "Make no other edits to the file."
            ]
            let acceptance = [
                "All specified functions appear exactly once in the file.",
                "Each moved function appears immediately after its designated target function ends.",
                "All other functions appear in the same relative order as baseline (excluding the moved functions).",
                "Leading documentation comments for moved functions remain attached and unchanged.",
                "The FOOTER comment and all code below it remain unchanged."
            ]
            let moves: [BenchmarkJSONValue] = [
                .object(["from": .string("alpha"), "after": .string("charlie")]),
                .object(["from": .string("bravo"), "after": .string("delta")])
            ]
            var params: [String: BenchmarkJSONValue] = [
                "moves": .array(moves),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoyCount(for: difficulty, config: config))
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "move_function_ts",
                    type: .moveFunctionTs,
                    language: .ts,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 2,
                    instructions: instructions,
                    task: "Reorder the specified functions according to the moves list while preserving leading documentation.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "move_function_ts",
                type: .moveFunctionTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 2,
                instructions: instructions,
                task: "Reorder the specified functions according to the moves list while preserving leading documentation.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Original behavior for non-HARD: single move of one function after another
            let token = randomIdentifier(rng: &rng)
            let path = "src/ts/reorder/Order_\(token).ts"
            let fnNames = ["alpha", "bravo", "charlie", "delta", "echo"]
            var lines: [String] = []
            for (index, name) in fnNames.enumerated() {
                lines.append("export function \(name)(n: number): number {")
                lines.append("    return n * \(index + 1);")
                lines.append("}")
                lines.append("")
            }
            lines.append("// FOOTER: keep below here unchanged")
            fileSystem.setFile(path, content: lines.joined(separator: "\n"))
            let from = fnNames[rng.nextInt(upperBound: fnNames.count)]
            let afterIdx = (fnNames.firstIndex(of: from)! + 2) % fnNames.count
            let after = fnNames[afterIdx]
            let instructions = [
                "Move the entire function \(from) to appear immediately after function \(after) ends.",
                "Remove the function from its original location (do NOT duplicate it).",
                "Preserve exact spacing/blank lines between other functions.",
                "The moved function's content must remain byte-for-byte identical.",
                "Make no other edits to the file."
            ]
            let acceptance = [
                "Function `\(from)` appears exactly once in the file.",
                "Function `\(from)` starts on the line immediately after `\(after)` ends.",
                "All other functions appear in the same order as baseline (excluding the moved function).",
                "The FOOTER comment and all code below it remain unchanged."
            ]
            var params: [String: BenchmarkJSONValue] = [
                "fromName": .string(from),
                "afterName": .string(after),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoyCount(for: difficulty, config: config))
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "move_function_ts",
                    type: .moveFunctionTs,
                    language: .ts,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 2,
                    instructions: instructions,
                    task: "Move function `\(from)` to after `\(after)` in \(path).",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "move_function_ts",
                type: .moveFunctionTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 2,
                instructions: instructions,
                task: "Move function `\(from)` to after `\(after)` in \(path).",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - move_function_go

    private func generateMoveFunctionGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = config
        _ = difficulty
        let token = randomIdentifier(rng: &rng)
        let path = "src/go/reorder/Order_\(token).go"
        let fnNames = ["alpha", "bravo", "charlie", "delta", "echo"]
        var lines: [String] = []
        lines.append("package reorder")
        lines.append("")
        for (index, name) in fnNames.enumerated() {
            lines.append("func \(name)(n int) int {")
            lines.append("    return n * \(index + 1)")
            lines.append("}")
            lines.append("")
        }
        lines.append("// FOOTER: keep below here unchanged")
        fileSystem.setFile(path, content: lines.joined(separator: "\n"))
        let fromIdx = rng.nextInt(upperBound: fnNames.count)
        let afterIdx = (fromIdx + 2) % fnNames.count
        let from = fnNames[fromIdx]
        let after = fnNames[afterIdx]
        let instructions = [
            "Move the entire function \(from) to appear immediately after function \(after) ends.",
            "Remove the function from its original location (do NOT duplicate it).",
            "Preserve exact spacing/blank lines between other functions.",
            "The moved function's content must remain byte-for-byte identical.",
            "Make no other edits to the file."
        ]
        let acceptance = [
            "Function `\(from)` appears exactly once in the file.",
            "Function `\(from)` starts on the line immediately after `\(after)` ends.",
            "All other functions appear in the same order as baseline (excluding the moved function).",
            "The FOOTER comment and all code below it remain unchanged."
        ]
        var params: [String: BenchmarkJSONValue] = [
            "fromName": .string(from),
            "afterName": .string(after),
            "difficulty": .string(difficulty.rawValue)
        ]

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "move_function_go",
                type: .moveFunctionGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 2,
                instructions: instructions,
                task: "Move function \(from) to after \(after) in \(path).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "move_function_go",
            type: .moveFunctionGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: [path],
            maxEdits: 2,
            instructions: instructions,
            task: "Move function \(from) to after \(after) in \(path).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - move_function_swift

    private func generateMoveFunctionSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = config
        if difficulty == .veryHard {
            let token = randomIdentifier(rng: &rng)
            let path = "src/swift/reorder/Order_\(token).swift"
            // Longer list with near-collisions to raise ambiguity and preserve tabs
            let fnNames = [
                "alpha",
                "alphaHelper",
                "alphaUtil",
                "alphaPrime",
                "bravo",
                "bravoHelper",
                "charlie",
                "charlieX",
                "delta"
            ]
            var lines: [String] = []
            for (index, name) in fnNames.enumerated() {
                // Leading documentation comment
                lines.append("/// \(name) computes value")
                lines.append("public func \(name)(_ n: Int) -> Int {")
                lines.append("\treturn n * \(index + 1)")
                lines.append("}")
                lines.append("")
            }
            lines.append("// FOOTER: keep below here unchanged")
            fileSystem.setFile(path, content: lines.joined(separator: "\n"))

            // Three moves increase difficulty; order forces long-distance reordering
            let moves: [BenchmarkJSONValue] = [
                .object(["from": .string("alpha"), "after": .string("charlie")]),
                .object(["from": .string("bravoHelper"), "after": .string("delta")]),
                .object(["from": .string("alphaUtil"), "after": .string("alphaPrime")])
            ]

            let instructions = [
                "Reorder the specified functions per the moves list.",
                "Preserve leading documentation comments and exact function bodies.",
                "Do not duplicate; remove the original occurrence.",
                "No other edits are permitted."
            ]
            let acceptance = [
                "All listed functions appear exactly once.",
                "Each moved function starts immediately after its target function ends.",
                "All leading documentation remains attached and unchanged.",
                "No collateral changes elsewhere in the file.",
                "FOOTER remains unchanged."
            ]

            var params: [String: BenchmarkJSONValue] = [
                "moves": .array(moves),
                "difficulty": .string(difficulty.rawValue)
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "move_function_swift_vh",
                    type: .moveFunctionSwift,
                    language: .swift,
                    difficulty: .veryHard,
                    format: "xml",
                    selectFiles: [path],
                    newChat: false,
                    maxEdits: 3,
                    instructions: instructions,
                    task: "Perform the listed moves exactly, preserving docs and content.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "move_function_swift_vh",
                type: .moveFunctionSwift,
                language: .swift,
                difficulty: .veryHard,
                format: "xml",
                selectFiles: [path],
                newChat: false,
                maxEdits: 3,
                instructions: instructions,
                task: "Perform the listed moves exactly, preserving docs and content.",
                acceptance: acceptance,
                params: params
            )
        } else if difficulty == .hard {
            let token = randomIdentifier(rng: &rng)
            let path = "src/swift/reorder/Order_\(token).swift"
            // Similar function names to create ambiguity
            let fnNames = ["alpha", "alphaHelper", "alphaUtil", "bravo", "bravoHelper", "charlie", "delta"]
            var lines: [String] = []
            for (index, name) in fnNames.enumerated() {
                // Leading documentation comment
                lines.append("/// \(name) computes value")
                lines.append("public func \(name)(_ n: Int) -> Int {")
                lines.append("\treturn n * \(index + 1)")
                lines.append("}")
                lines.append("")
            }
            lines.append("// FOOTER: keep below here unchanged")
            fileSystem.setFile(path, content: lines.joined(separator: "\n"))

            // HARD: Multi-move parameters (avoid single explicit from/after in top instructions)
            let instructions = [
                "Move the specified functions to maintain logical grouping; preserve any leading documentation/comments; do not duplicate.",
                "Preserve exact spacing/blank lines between other functions.",
                "The moved functions' content and leading doc comments must remain byte-for-byte identical.",
                "Make no other edits to the file."
            ]
            let acceptance = [
                "All specified functions appear exactly once in the file.",
                "Each moved function appears immediately after its designated target function ends.",
                "All other functions appear in the same relative order as baseline (excluding the moved functions).",
                "Leading documentation comments for moved functions remain attached and unchanged.",
                "The FOOTER comment and all code below it remain unchanged."
            ]
            let moves: [BenchmarkJSONValue] = [
                .object(["from": .string("alpha"), "after": .string("charlie")]),
                .object(["from": .string("bravo"), "after": .string("delta")])
            ]
            var params: [String: BenchmarkJSONValue] = [
                "moves": .array(moves),
                "difficulty": .string(difficulty.rawValue)
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "move_function_swift",
                    type: .moveFunctionSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 2,
                    instructions: instructions,
                    task: "Reorder the specified functions according to the moves list while preserving leading documentation.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "move_function_swift",
                type: .moveFunctionSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 2,
                instructions: instructions,
                task: "Reorder the specified functions according to the moves list while preserving leading documentation.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Original behavior for non-HARD: single move of one function after another
            let token = randomIdentifier(rng: &rng)
            let path = "src/swift/reorder/Order_\(token).swift"
            let fnNames = ["alpha", "bravo", "charlie", "delta", "echo"]
            var lines: [String] = []
            for (index, name) in fnNames.enumerated() {
                lines.append("public func \(name)(_ n: Int) -> Int {")
                lines.append("\treturn n * \(index + 1)")
                lines.append("}")
                lines.append("")
            }
            lines.append("// FOOTER: keep below here unchanged")
            fileSystem.setFile(path, content: lines.joined(separator: "\n"))
            let fromIdx = rng.nextInt(upperBound: fnNames.count)
            let afterIdx = (fromIdx + 2) % fnNames.count
            let from = fnNames[fromIdx]
            let after = fnNames[afterIdx]
            let instructions = [
                "Move the entire function \(from) to appear immediately after function \(after) ends.",
                "Remove the function from its original location (do NOT duplicate it).",
                "Preserve exact spacing/blank lines between other functions.",
                "The moved function's content must remain byte-for-byte identical.",
                "Make no other edits to the file."
            ]
            let acceptance = [
                "Function `\(from)` appears exactly once in the file.",
                "Function `\(from)` starts on the line immediately after `\(after)` ends.",
                "All other functions appear in the same order as baseline (excluding the moved function).",
                "The FOOTER comment and all code below it remain unchanged."
            ]
            var params: [String: BenchmarkJSONValue] = [
                "fromName": .string(from),
                "afterName": .string(after),
                "difficulty": .string(difficulty.rawValue)
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "move_function_swift",
                    type: .moveFunctionSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 2,
                    instructions: instructions,
                    task: "Move function \(from) to after \(after) in \(path).",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "move_function_swift",
                type: .moveFunctionSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 2,
                instructions: instructions,
                task: "Move function \(from) to after \(after) in \(path).",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - insert_function_bottom_ts

    private func generateInsertFunctionBottomTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium:
            [tsWorkPath]
        case .hard:
            [tsWorkPath, "src/ts/work/WorkA.ts"]
        case .veryHard:
            [tsWorkPath, "src/ts/work/WorkA.ts", "src/ts/work/WorkB.ts"]
        case .simple:
            [tsWorkPath]
        }
        let footer = "// END-OF-FILE (append new functions immediately above this line)"
        for path in files {
            var bootstrap = fileSystem.content(for: path) ?? ""
            if !bootstrap.contains(footer) {
                if !bootstrap.isEmpty, !bootstrap.hasSuffix("\n") {
                    bootstrap.append("\n")
                }
                bootstrap.append(
                    "export function ping(x: string): string {\n    return `ping:${x}`;\n}\n\nexport function pong(y: number): number {\n    return y + 1;\n}\n\n\(footer)\n"
                )
                fileSystem.setFile(path, content: bootstrap)
            }
        }
        let snippet = """
        export const curryAdd = (a: number) => (b: number) => a + b;

        export function compose<A,B,C>(f: (b: B) => C, g: (a: A) => B) {
        	return (a: A) => f(g(a));
        }
        """
        let instructions = [
            "In each listed file, insert the provided multi-line snippet at the bottom.",
            "The snippet must be inserted immediately above the // END-OF-FILE marker line.",
            "Maintain one blank line between the last existing function and the new snippet.",
            "Maintain one blank line between the snippet and the END-OF-FILE marker.",
            "Do NOT modify any existing code above the insertion point.",
            "Insert the exact snippet once per file - do NOT modify or reformat it.",
            "CRITICAL: Your <search> blocks must contain 3-8 lines and match the file byte-for-byte. You WILL FAIL if you include entire files, large sections, or hundreds of lines in your search blocks. Keep search blocks minimal and precise."
        ]
        let acceptance = [
            "The snippet appears exactly once in each listed file.",
            "The snippet is placed above the END-OF-FILE marker in each file.",
            "There is exactly one blank line between the snippet and the END-OF-FILE marker.",
            "All existing functions and code remain byte-for-byte unchanged.",
            "Exactly \(files.count) file(s) were modified."
        ]
        let decoyBudget = decoyCount(for: difficulty, config: config)
        let fullDecoys = decoyBudget > 0 ? makeSimilarTsDecoys(rng: &rng, around: tsWorkPath) : []
        for decoy in fullDecoys {
            fileSystem.setFile(decoy.path, content: decoy.content)
        }
        let inserts = files.map { path -> BenchmarkJSONValue in
            .object([
                "path": .string(path),
                "snippet": .string(snippet),
                "footer": .string("// END-OF-FILE")
            ])
        }
        var params: [String: BenchmarkJSONValue] = [
            "inserts": .array(inserts),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyBudget)
        ]
        if !fullDecoys.isEmpty {
            params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "insert_function_bottom_ts",
                type: .insertFunctionBottomTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, files.count),
                instructions: instructions,
                task: "Append a curried utility function block at the bottom of each listed file.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "insert_function_bottom_ts",
            type: .insertFunctionBottomTs,
            language: .ts,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: max(1, files.count),
            instructions: instructions,
            task: "Append a curried utility function block at the bottom of each listed file.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - insert_function_bottom_go

    private func generateInsertFunctionBottomGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [goWorkPath]
        case .hard:
            [goWorkPath, "src/go/work/WorkA.go"]
        case .veryHard:
            [goWorkPath, "src/go/work/WorkA.go", "src/go/work/WorkB.go"]
        }
        let footer = "// END-OF-FILE (append new functions immediately above this line)"
        for path in files {
            var existing = fileSystem.content(for: path) ?? ""
            if !existing.contains(footer) {
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append("package work\n\nfunc ping(x string) string { return \"ping:\\(x)\" }\n\nfunc pong(y int) int { return y + 1 }\n\n\(footer)\n")
                fileSystem.setFile(path, content: existing)
            }
        }
        let snippet = """
        func curryAdd(a int) func(int) int { return func(b int) int { return a + b } }

        func compose[A any, B any, C any](f func(B) C, g func(A) B) func(A) C {
        	return func(a A) C { return f(g(a)) }
        }
        """
        let instructions = [
            "In each listed file, insert the provided multi-line snippet at the bottom.",
            "The snippet must be inserted immediately above the // END-OF-FILE marker line.",
            "Maintain one blank line between the last existing function and the new snippet.",
            "Maintain one blank line between the snippet and the END-OF-FILE marker.",
            "Do NOT modify any existing code above the insertion point.",
            "Insert the exact snippet once per file - do NOT modify or reformat it.",
            "CRITICAL: Your <search> blocks must contain 3-8 lines and match the file byte-for-byte. You WILL FAIL if you include entire files, large sections, or hundreds of lines in your search blocks. Keep search blocks minimal and precise."
        ]
        let acceptance = [
            "The snippet appears exactly once in each listed file.",
            "The snippet is placed above the END-OF-FILE marker in each file.",
            "There is exactly one blank line between the snippet and the END-OF-FILE marker.",
            "All existing functions and code remain byte-for-byte unchanged.",
            "Exactly \(files.count) file(s) were modified."
        ]
        let decoys = decoyCount(for: difficulty, config: config)
        var decoyPaths: [String] = []
        if decoys >= 1 {
            let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "BottomShadow")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        if decoys >= 2 {
            let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "BottomClone")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        let inserts = files.map { path -> BenchmarkJSONValue in
            .object([
                "path": .string(path),
                "snippet": .string(snippet),
                "footer": .string("// END-OF-FILE")
            ])
        }
        var params: [String: BenchmarkJSONValue] = [
            "inserts": .array(inserts),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoys)
        ]
        if !decoyPaths.isEmpty {
            params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "insert_function_bottom_go",
                type: .insertFunctionBottomGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, files.count),
                instructions: instructions,
                task: "Append the snippet at the bottom of each listed file.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "insert_function_bottom_go",
            type: .insertFunctionBottomGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: max(1, files.count),
            instructions: instructions,
            task: "Append the snippet at the bottom of each listed file.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - insert_function_bottom_swift

    private func generateInsertFunctionBottomSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [swiftWorkPath]
        case .hard:
            [swiftWorkPath, "src/swift/work/WorkA.swift"]
        case .veryHard:
            [swiftWorkPath, "src/swift/work/WorkA.swift", "src/swift/work/WorkB.swift"]
        }
        let footer = "// END-OF-FILE (append new functions immediately above this line)"
        for path in files {
            var existing = fileSystem.content(for: path) ?? ""
            if !existing.contains(footer) {
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append("public func ping(_ x: String) -> String { \"ping:\\(x)\" }\n\npublic func pong(_ y: Int) -> Int { y + 1 }\n\n\(footer)\n")
                fileSystem.setFile(path, content: existing)
            }
        }
        let snippet = """
        public func curryAdd(_ a: Int) -> (Int) -> Int { { b in a + b } }

        public func compose<A,B,C>(_ f: @escaping (B) -> C, _ g: @escaping (A) -> B) -> (A) -> C {
        	{ a in f(g(a)) }
        }
        """
        let instructions = [
            "Append the provided multi-line snippet at the bottom of each listed file, immediately above the footer marker.",
            "Do not change existing lines.",
            "CRITICAL: Your <search> blocks must contain 3-8 lines and match the file byte-for-byte. You WILL FAIL if you include entire files, large sections, or hundreds of lines in your search blocks. Keep search blocks minimal and precise."
        ]
        let acceptance = [
            "Snippet appears exactly once in each listed file.",
            "Snippet is placed above the END-OF-FILE marker in each listed file.",
            "No other lines changed."
        ]
        let decoys = decoyCount(for: difficulty, config: config)
        var decoyPaths: [String] = []
        if decoys >= 1 {
            let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "BottomShadow")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        if decoys >= 2 {
            let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "BottomClone")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        let inserts = files.map { path -> BenchmarkJSONValue in
            .object([
                "path": .string(path),
                "snippet": .string(snippet),
                "footer": .string("// END-OF-FILE")
            ])
        }
        var params: [String: BenchmarkJSONValue] = [
            "inserts": .array(inserts),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoys)
        ]
        if !decoyPaths.isEmpty {
            params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "insert_function_bottom_swift",
                type: .insertFunctionBottomSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, files.count),
                instructions: instructions,
                task: "Append the snippet at the bottom of each listed file.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "insert_function_bottom_swift",
            type: .insertFunctionBottomSwift,
            language: .swift,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: max(1, files.count),
            instructions: instructions,
            task: "Append the snippet at the bottom of each listed file.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - apply_unified_patch_*

    //
    // NOTE: Simple difficulty is retained for unit tests but excluded from production benchmarks.
    // Production difficulty progression: Medium → Hard → VeryHard (gauntlet)

    // MARK: - apply_unified_patch_ts

    private func appendTsSection2(_ lines: inout [String]) {
        lines.append("")
        lines.append("export function d(n: number) {")
        lines.append("    return n + 1")
        lines.append("}")
        lines.append("")
        lines.append("export function e(s: string) {")
        lines.append("    return s.toLowerCase()")
        lines.append("}")
        lines.append("")
        lines.append("export function f(xs: number[]): number {")
        lines.append("    return xs.length")
        lines.append("}")
        lines.append("")
        lines.append("export const value2 = 7")
    }

    private func appendTsSection3(_ lines: inout [String]) {
        lines.append("")
        lines.append("export function g(n: number) {")
        lines.append("    return n * 2")
        lines.append("}")
        lines.append("")
        lines.append("export function h(s: string) {")
        lines.append("    return s")
        lines.append("}")
        lines.append("")
        lines.append("export const value3 = 100")
    }

    private func appendTsSection4(_ lines: inout [String]) {
        lines.append("")
        lines.append("export function i(n: number) {")
        lines.append("    return n - 1")
        lines.append("}")
        lines.append("")
        lines.append("export function j(s: string) {")
        lines.append("    return s.trim()")
        lines.append("}")
        lines.append("")
        lines.append("export const value4 = 256")
    }

    // MARK: - Clone Infrastructure Helpers

    private func makeDeepClonePaths(token: String, ext: String, count: Int, language: BenchmarkLanguage) -> [String] {
        let roots: [String] = switch language {
        case .ts:
            ["src/ts/patchables", "apps/appA/src/patchables", "apps/appB/src/patchables", "packages/pkg1/src/patchables", "packages/pkg2/src/patchables"]
        case .go:
            ["src/go/patchables", "apps/appA/patchables", "apps/appB/patchables", "packages/pkg1/patchables", "packages/pkg2/patchables"]
        case .swift:
            ["src/swift/patchables", "Apps/appA/patchables", "Apps/appB/patchables", "Packages/Pkg1/patchables", "Packages/Pkg2/patchables"]
        @unknown default:
            ["src/patchables"]
        }
        var out: [String] = []
        for i in 0 ..< count {
            let root = roots[i % roots.count]
            out.append("\(root)/Clone_\(token)_\(i).\(ext)")
        }
        return out
    }

    private func stableShuffle<T>(_ arr: [T], seed: UInt32) -> [T] {
        var rng = Mulberry32(seed: seed)
        var a = arr
        for i in stride(from: a.count - 1, through: 1, by: -1) {
            let j = rng.nextInt(upperBound: i + 1)
            a.swapAt(i, j)
        }
        return a
    }

    private func makePatchableClone(language: BenchmarkLanguage, origin: [String], variant: Int, includeSection4: Bool) -> [String] {
        let clone = origin

        // 1) Large preamble padding (60-120 lines)
        let padCount = 60 + (variant % 61)
        var pre: [String] = []
        for k in 0 ..< padCount {
            switch language {
            case .ts:
                pre.append("// pad \(k)")
                if k % 5 == 0 {
                    pre.append("export const pad\(k) = \(k)")
                }
            case .go:
                pre.append("// pad \(k)")
                if k % 5 == 0 {
                    pre.append("const pad\(k) = \(k)")
                }
            case .swift:
                pre.append("// pad \(k)")
                if k % 5 == 0 {
                    pre.append("public let pad\(k) = \(k)")
                }
            default:
                pre.append("// pad \(k)")
            }
        }

        // 2) Extract sections from origin
        let sections = extractSections(language: language, from: clone, includeSection4: includeSection4)

        // 3) Reorder sections based on variant
        let reordered = reorderSections(sections, variant: variant)

        // 4) Tweak constants to break minus matches
        let tweaked = tweakConstants(in: reordered, language: language, variant: variant)

        // 5) Assemble: preamble + tweaked
        return pre + tweaked
    }

    private func extractSections(language: BenchmarkLanguage, from lines: [String], includeSection4: Bool) -> [[String]] {
        var sections: [[String]] = []
        var currentSection: [String] = []

        // Simple heuristic: split on empty lines or function boundaries
        // Section 1: everything before first major function group (a, b, c, value)
        // Section 2: d, e, f, value2
        // Section 3: g, h, value3
        // Section 4: i, j, value4

        let markers: [String] = switch language {
        case .ts:
            includeSection4
                ? ["export function a(", "export function d(", "export function g(", "export function i("]
                : ["export function a(", "export function d(", "export function g("]
        case .go:
            includeSection4
                ? ["func a(", "func d(", "func g(", "func i("]
                : ["func a(", "func d(", "func g("]
        case .swift:
            includeSection4
                ? ["public func a(", "public func d(", "public func g(", "public func i("]
                : ["public func a(", "public func d(", "public func g("]
        @unknown default:
            []
        }

        var markerIdx = 0
        for line in lines {
            if markerIdx < markers.count, line.contains(markers[markerIdx]) {
                if !currentSection.isEmpty {
                    sections.append(currentSection)
                    currentSection = []
                }
                markerIdx += 1
            }
            currentSection.append(line)
        }

        if !currentSection.isEmpty {
            sections.append(currentSection)
        }

        return sections
    }

    private func reorderSections(_ sections: [[String]], variant: Int) -> [String] {
        guard sections.count > 1 else {
            return sections.flatMap(\.self)
        }

        // Permute sections based on variant
        // Simple strategy: rotate sections
        let shift = variant % sections.count
        var reordered: [[String]] = []
        for i in 0 ..< sections.count {
            let idx = (i + shift) % sections.count
            reordered.append(sections[idx])
        }

        return reordered.flatMap(\.self)
    }

    private func tweakConstants(in lines: [String], language: BenchmarkLanguage, variant: Int) -> [String] {
        let tweak = variant % 10 + 1
        return lines.map { line in
            switch language {
            case .ts:
                if line.contains("export const value = ") {
                    return line.replacingOccurrences(of: "= 42", with: "= \(42 + tweak)")
                }
                if line.contains("export const value2 = ") {
                    return line.replacingOccurrences(of: "= 7", with: "= \(7 + tweak)")
                }
                if line.contains("export const value3 = ") {
                    return line.replacingOccurrences(of: "= 100", with: "= \(100 + tweak)")
                }
                if line.contains("export const value4 = ") {
                    return line.replacingOccurrences(of: "= 256", with: "= \(256 + tweak)")
                }
            case .go:
                if line.contains("const value = ") {
                    return line.replacingOccurrences(of: "= 42", with: "= \(42 + tweak)")
                }
                if line.contains("const value2 = ") {
                    return line.replacingOccurrences(of: "= 7", with: "= \(7 + tweak)")
                }
                if line.contains("const value3 = ") {
                    return line.replacingOccurrences(of: "= 100", with: "= \(100 + tweak)")
                }
                if line.contains("const value4 = ") {
                    return line.replacingOccurrences(of: "= 256", with: "= \(256 + tweak)")
                }
            case .swift:
                if line.contains("public let value = ") {
                    return line.replacingOccurrences(of: "= 42", with: "= \(42 + tweak)")
                }
                if line.contains("public let value2 = ") {
                    return line.replacingOccurrences(of: "= 7", with: "= \(7 + tweak)")
                }
                if line.contains("public let value3 = ") {
                    return line.replacingOccurrences(of: "= 100", with: "= \(100 + tweak)")
                }
                if line.contains("public let value4 = ") {
                    return line.replacingOccurrences(of: "= 256", with: "= \(256 + tweak)")
                }
            @unknown default:
                break
            }
            return line
        }
    }

    private func generateUnifiedPatchTsTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let token = randomIdentifier(rng: &rng)
        let path = "src/ts/patchables/Patch_\(token).ts"
        let maxDecoys = decoyCount(for: difficulty, config: config)

        func fallbackSpec() -> BenchmarkTaskSpec {
            BenchmarkTaskSpec(
                id: "apply_unified_patch_ts",
                type: .applyUnifiedPatchTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 6,
                instructions: ["Apply the unified diff to \(path)."],
                task: "Apply the unified diff to \(path).",
                acceptance: ["Final file equals applying the provided unified diff."],
                params: [
                    "patch": .string(""),
                    "difficulty": .string(difficulty.rawValue),
                    "maxDecoys": .integer(maxDecoys)
                ]
            )
        }

        // Build baseline (keep existing logic)
        var base: [String] = []
        base.append("export function a(n: number) {")
        base.append("    return n + 1")
        base.append("}")
        base.append("")
        base.append("export function b(s: string) {")
        base.append("    return s.toUpperCase()")
        base.append("}")
        base.append("")
        if difficulty != .simple {
            base.append("export function c(xs: number[]): number {")
            base.append("    return xs.reduce((a, b) => a + b, 0)")
            base.append("}")
            base.append("")
        }
        base.append("export const value = 42")

        // VeryHard gauntlet: append additional sections to baseline
        if difficulty == .veryHard {
            appendTsSection2(&base)
            appendTsSection3(&base)
            appendTsSection4(&base)
        }

        fileSystem.setFile(path, content: base.joined(separator: "\n"))

        /// Unified diff helpers
        func hunkHeader(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }

        // Locate function a (for modify hunk)
        guard
            let aOpenIdx = base.firstIndex(where: { $0.hasPrefix("export function a(") }),
            let aRetIdx = base.firstIndex(where: { $0.contains("return n + 1") }),
            aRetIdx + 1 < base.count
        else {
            return fallbackSpec()
        }
        let aCloseIdx = aRetIdx + 1
        guard base[aCloseIdx] == "}" else {
            return fallbackSpec()
        }

        // Compute increment and modified return line for function a
        let inc = 2 + rng.nextInt(upperBound: 3)
        let oldTarget = base[aRetIdx]
        let newTarget = oldTarget.replacingOccurrences(of: "n + 1", with: "n + \(inc)")

        // Start patch header
        let useUnknownHeaders = (difficulty == .veryHard)
        var patchLines: [String] = []
        patchLines.append(useUnknownHeaders ? "--- a/UNKNOWN" : "--- a/\(path)")
        patchLines.append(useUnknownHeaders ? "+++ b/UNKNOWN" : "+++ b/\(path)")

        // Gather hunks
        var hunks: [[String]] = []

        // BOF header addition for medium/hard/veryHard
        let bofAdded = (difficulty != .simple) ? 2 : 0
        if bofAdded > 0 {
            var headerHunk: [String] = []
            headerHunk.append(hunkHeader(1, 0, 1, 2))
            headerHunk.append("+// NOTE: patched by benchmark")
            headerHunk.append("+")
            hunks.append(headerHunk)
        }

        // VeryHard gauntlet multi-section logic
        if difficulty == .veryHard {
            var removedSpans: [ClosedRange<Int>] = []

            // Create decoy clone files for target discovery (12-20 clones across nested dirs)
            let gauntlet = (config.decoyPolicy.style == .gauntlet)
            let cloneCount = gauntlet ? 20 : 12
            let clonePaths = makeDeepClonePaths(token: token, ext: "ts", count: cloneCount, language: .ts)
            for (i, clonePath) in clonePaths.enumerated() {
                let cloneLines = makePatchableClone(language: .ts, origin: base, variant: i, includeSection4: true)
                fileSystem.setFile(clonePath, content: cloneLines.joined(separator: "\n"))
            }
            // Shuffle candidatePaths to hide target position
            let allCandidates = [path] + clonePaths
            let shuffleSeed = UInt32(truncatingIfNeeded: token.hashValue)
            let candidatePaths = stableShuffle(allCandidates, seed: shuffleSeed)

            // Section 1: modify a
            do {
                var modifyHunk: [String] = []
                let modifyOldStart = aOpenIdx + 1
                let removedBefore = removedLineCount(before: aOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                modifyHunk.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                modifyHunk.append(" \(base[aOpenIdx])")
                modifyHunk.append("-\(oldTarget)")
                modifyHunk.append("+\(newTarget)")
                modifyHunk.append(" \(base[aCloseIdx])")
                hunks.append(modifyHunk)
            }

            // Section 1: remove b (with context)
            guard let bRange = computeTsFunctionRange(base, fnName: "b") else {
                return fallbackSpec()
            }
            do {
                let bStart = bRange.lowerBound
                let bEnd = bRange.upperBound
                let ctxBeforeIdx = max(0, bStart - 1)
                let ctxAfterIdx = min(base.count - 1, bEnd + 1)
                let hasAfterContext = ctxAfterIdx > bEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in bStart ... bEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(bRange)

            // Section 1: noise hunk on value
            do {
                let noiseText = buildTsNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange],
                    context: 3
                )
                if !noiseText.isEmpty {
                    hunks.append(noiseText.components(separatedBy: "\n"))
                }
            }

            // Section 2: modify d
            guard
                let dOpenIdx = base.firstIndex(where: { $0.hasPrefix("export function d(") })
            else {
                return fallbackSpec()
            }
            guard
                let dRetIdx = base[dOpenIdx...].firstIndex(where: { $0.contains("return n + 1") && $0.hasPrefix("    ") }),
                dRetIdx > dOpenIdx,
                dRetIdx + 1 < base.count,
                base[dRetIdx + 1] == "}"
            else {
                return fallbackSpec()
            }
            do {
                let oldReturnD = base[dRetIdx]
                let inc2 = 2 + rng.nextInt(upperBound: 3)
                let newReturnD = oldReturnD.replacingOccurrences(of: "n + 1", with: "n + \(inc2)")

                var h: [String] = []
                let modifyOldStart = dOpenIdx + 1
                let removedBefore = removedLineCount(before: dOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[dOpenIdx])")
                h.append("-\(oldReturnD)")
                h.append("+\(newReturnD)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 2: remove e
            guard let eRange = computeTsFunctionRange(base, fnName: "e") else {
                return fallbackSpec()
            }
            do {
                let eStart = eRange.lowerBound
                let eEnd = eRange.upperBound
                let ctxBeforeIdx = max(0, eStart - 1)
                let ctxAfterIdx = min(base.count - 1, eEnd + 1)
                let hasAfterContext = ctxAfterIdx > eEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in eStart ... eEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(eRange)

            // Section 2: noise hunk on value2
            do {
                let noiseText = buildTsNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange],
                    valueMarker: "export const value2 = 7",
                    context: 3
                )
                if !noiseText.isEmpty {
                    hunks.append(noiseText.components(separatedBy: "\n"))
                }
            }

            // Section 3: modify g
            guard
                let gOpenIdx = base.firstIndex(where: { $0.hasPrefix("export function g(") }),
                let gRetIdx = base.firstIndex(where: { $0.contains("return n * 2") })
            else {
                return fallbackSpec()
            }
            guard gRetIdx + 1 < base.count, base[gRetIdx + 1] == "}" else {
                return fallbackSpec()
            }
            do {
                let oldReturnG = base[gRetIdx]
                let newReturnG = oldReturnG.replacingOccurrences(of: "n * 2", with: "n * 3")

                var h: [String] = []
                let modifyOldStart = gOpenIdx + 1
                let removedBefore = removedLineCount(before: gOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[gOpenIdx])")
                h.append("-\(oldReturnG)")
                h.append("+\(newReturnG)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 3: remove h
            guard let hRange = computeTsFunctionRange(base, fnName: "h") else {
                return fallbackSpec()
            }
            do {
                let hStart = hRange.lowerBound
                let hEnd = hRange.upperBound
                let ctxBeforeIdx = max(0, hStart - 1)
                let ctxAfterIdx = min(base.count - 1, hEnd + 1)
                let hasAfterContext = ctxAfterIdx > hEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in hStart ... hEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(hRange)

            // Section 3: noise hunk on value3 (additional noise)
            do {
                let noise3 = buildTsNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange],
                    valueMarker: "export const value3 = 100",
                    context: 2
                )
                if !noise3.isEmpty {
                    hunks.append(noise3.components(separatedBy: "\n"))
                }
            }

            // Section 4: modify i
            guard
                let iOpenIdx = base.firstIndex(where: { $0.hasPrefix("export function i(") }),
                let iRetIdx = base.firstIndex(where: { $0.contains("return n - 1") })
            else {
                return fallbackSpec()
            }
            guard iRetIdx + 1 < base.count, base[iRetIdx + 1] == "}" else {
                return fallbackSpec()
            }
            do {
                let oldReturnI = base[iRetIdx]
                let newReturnI = oldReturnI.replacingOccurrences(of: "n - 1", with: "n - 2")

                var h: [String] = []
                let modifyOldStart = iOpenIdx + 1
                let removedBefore = removedLineCount(before: iOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[iOpenIdx])")
                h.append("-\(oldReturnI)")
                h.append("+\(newReturnI)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 4: remove j
            guard let jRange = computeTsFunctionRange(base, fnName: "j") else {
                return fallbackSpec()
            }
            do {
                let jStart = jRange.lowerBound
                let jEnd = jRange.upperBound
                let ctxBeforeIdx = max(0, jStart - 1)
                let ctxAfterIdx = min(base.count - 1, jEnd + 1)
                let hasAfterContext = ctxAfterIdx > jEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in jStart ... jEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(jRange)

            // Section 4: noise hunk on value4
            do {
                let noise4 = buildTsNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange, jRange],
                    valueMarker: "export const value4 = 256",
                    context: 1
                )
                if !noise4.isEmpty {
                    hunks.append(noise4.components(separatedBy: "\n"))
                }
            }

            // Additional noise hunk on value2 with different context
            do {
                let noise2Extra = buildTsNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange, jRange],
                    valueMarker: "export const value2 = 7",
                    context: 4
                )
                if !noise2Extra.isEmpty {
                    hunks.append(noise2Extra.components(separatedBy: "\n"))
                }
            }

            // Emit hunks
            for hunk in hunks {
                patchLines.append(contentsOf: hunk)
            }

            let instructions = [
                "Apply the unified diff exactly to \(path).",
                "Do not modify any other lines beyond the patch."
            ]
            let acceptance = [
                "The final file content matches the provided unified diff.",
                "No additional changes beyond the hunks."
            ]
            let maxEdits = switch difficulty {
            case .simple:
                4
            case .medium:
                7
            case .hard:
                12
            case .veryHard:
                28
            }

            var params: [String: BenchmarkJSONValue] = [
                "patch": .string(patchLines.joined(separator: "\n")),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(maxDecoys),
                "targetDiscovery": .boolean(true),
                "targetPath": .string(path),
                "candidatePaths": .array(candidatePaths.map { .string($0) })
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "apply_unified_patch_ts",
                    type: .applyUnifiedPatchTs,
                    language: .ts,
                    difficulty: difficulty,
                    selectFiles: candidatePaths,
                    maxEdits: maxEdits,
                    instructions: instructions,
                    task: "Apply the unified diff to one of the candidate files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "apply_unified_patch_ts",
                type: .applyUnifiedPatchTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: candidatePaths,
                maxEdits: maxEdits,
                instructions: instructions,
                task: "Apply the unified diff to one of the candidate files.",
                acceptance: acceptance,
                params: params
            )
        }

        // Non‑VeryHard path (existing behavior)

        // Modify function a
        var modifyHunk: [String] = []
        let modifyOldStart = aOpenIdx + 1 // original file line number (1-based)
        let modifyNewStart = modifyOldStart + bofAdded
        modifyHunk.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
        modifyHunk.append(" \(base[aOpenIdx])")
        modifyHunk.append("-\(oldTarget)")
        modifyHunk.append("+\(newTarget)")
        modifyHunk.append(" \(base[aCloseIdx])")
        hunks.append(modifyHunk)

        // Remove function b for medium/hard/veryHard using computeTsFunctionRange
        var extraNoiseLines: [String] = []
        if difficulty != .simple {
            guard let bRange = computeTsFunctionRange(base, fnName: "b") else {
                return fallbackSpec()
            }
            let bStart = bRange.lowerBound
            let bEnd = bRange.upperBound

            let ctxBeforeIdx = max(0, bStart - 1)
            let ctxAfterIdx = min(base.count - 1, bEnd + 1)

            // Header math
            let oldLineStart = ctxBeforeIdx + 1
            let newLineStart = oldLineStart + bofAdded
            let hasAfterContext = ctxAfterIdx > bEnd
            let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
            let newCount = hasAfterContext ? 2 : 1

            var removalHunk: [String] = []
            removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
            removalHunk.append(" \(base[ctxBeforeIdx])")
            for idx in bStart ... bEnd {
                removalHunk.append("-\(base[idx])")
            }
            if hasAfterContext {
                removalHunk.append(" \(base[ctxAfterIdx])")
            }
            hunks.append(removalHunk)

            // Noise hunk for hard/veryHard via helper (3-line context default)
            if difficulty == .hard || difficulty == .veryHard {
                let noiseText = buildTsNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange],
                    context: 3
                )
                if !noiseText.isEmpty {
                    extraNoiseLines = noiseText.components(separatedBy: "\n")
                }

                // For hard: add one more noise hunk with different context
                if difficulty == .hard {
                    let noise2 = buildTsNoiseHunk(
                        baseline: base,
                        bofAdded: bofAdded,
                        removedSpans: [bRange],
                        valueMarker: "export const value = 42",
                        context: 1
                    )
                    if !noise2.isEmpty, !extraNoiseLines.isEmpty {
                        extraNoiseLines.append(contentsOf: noise2.components(separatedBy: "\n"))
                    }
                }
            }
        }

        // Emit hunks
        for hunk in hunks {
            patchLines.append(contentsOf: hunk)
        }

        // Append noise hunk (if any)
        if !extraNoiseLines.isEmpty {
            patchLines.append(contentsOf: extraNoiseLines)
        }

        let instructions = [
            "Apply the unified diff exactly to \(path).",
            "Do not modify any other lines beyond the patch."
        ]
        let acceptance = [
            "The final file content matches the provided unified diff.",
            "No additional changes beyond the hunks."
        ]
        let maxEdits = switch difficulty {
        case .simple:
            4
        case .medium:
            7
        case .hard:
            12
        case .veryHard:
            28
        }

        var params: [String: BenchmarkJSONValue] = [
            "patch": .string(patchLines.joined(separator: "\n")),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(maxDecoys)
        ]

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "apply_unified_patch_ts",
                type: .applyUnifiedPatchTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: maxEdits,
                instructions: instructions,
                task: "Apply the unified diff to \(path).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "apply_unified_patch_ts",
            type: .applyUnifiedPatchTs,
            language: .ts,
            difficulty: difficulty,
            selectFiles: [path],
            maxEdits: maxEdits,
            instructions: instructions,
            task: "Apply the unified diff to \(path).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - apply_unified_patch_go

    private func appendGoSection2(_ lines: inout [String]) {
        lines.append("")
        lines.append("func d(n int) int {")
        lines.append("    return n + 1")
        lines.append("}")
        lines.append("")
        lines.append("func e(s string) string {")
        lines.append("    return s")
        lines.append("}")
        lines.append("")
        lines.append("func f(xs []int) int {")
        lines.append("    return len(xs)")
        lines.append("}")
        lines.append("")
        lines.append("const value2 = 7")
    }

    private func appendGoSection3(_ lines: inout [String]) {
        lines.append("")
        lines.append("func g(n int) int {")
        lines.append("    return n * 2")
        lines.append("}")
        lines.append("")
        lines.append("func h(s string) string {")
        lines.append("    return s")
        lines.append("}")
        lines.append("")
        lines.append("const value3 = 100")
    }

    private func appendGoSection4(_ lines: inout [String]) {
        lines.append("")
        lines.append("func i(n int) int {")
        lines.append("    return n - 1")
        lines.append("}")
        lines.append("")
        lines.append("func j(s string) string {")
        lines.append("    return strings.TrimSpace(s)")
        lines.append("}")
        lines.append("")
        lines.append("const value4 = 256")
    }

    private func generateUnifiedPatchGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = config
        let token = randomIdentifier(rng: &rng)
        let path = "src/go/patchables/Patch_\(token).go"

        func hunkHeader(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }

        // Build baseline (preserve existing logic)
        var base: [String] = []
        base.append("package patchables")
        base.append("")
        base.append("func a(n int) int {")
        base.append("    return n + 1")
        base.append("}")
        base.append("")
        base.append("func b(s string) string {")
        base.append("    return s + s")
        base.append("}")
        base.append("")
        if difficulty != .simple {
            base.append("func c(xs []int) int {")
            base.append("    return sum(xs)")
            base.append("}")
            base.append("")
        }
        base.append("const value = 42")

        // VeryHard gauntlet: append additional sections to baseline
        if difficulty == .veryHard {
            appendGoSection2(&base)
            appendGoSection3(&base)
            appendGoSection4(&base)
        }

        fileSystem.setFile(path, content: base.joined(separator: "\n"))

        // Start patch output
        let useUnknownHeaders = (difficulty == .veryHard)
        var patchLines: [String] = []
        patchLines.append(useUnknownHeaders ? "--- a/UNKNOWN" : "--- a/\(path)")
        patchLines.append(useUnknownHeaders ? "+++ b/UNKNOWN" : "+++ b/\(path)")

        // Hunks container
        var hunks: [[String]] = []

        // BOF header addition for medium/hard/veryHard
        let bofAdded = (difficulty != .simple) ? 2 : 0
        if bofAdded > 0 {
            var headerHunk: [String] = []
            headerHunk.append(hunkHeader(1, 0, 1, 2))
            headerHunk.append("+// NOTE: patched by benchmark")
            headerHunk.append("+")
            hunks.append(headerHunk)
        }

        // Locate function a (for modify hunk)
        guard
            let aOpenIdx = base.firstIndex(where: { $0.hasPrefix("func a(") }),
            let aRetIdx = base.firstIndex(where: { $0.contains("return n + 1") }),
            aRetIdx + 1 < base.count,
            base[aRetIdx + 1] == "}"
        else {
            let instructions = ["Apply the unified diff exactly to \(path)."]
            let acceptance = ["Final file equals applying the provided unified diff."]
            return BenchmarkTaskSpec(
                id: "apply_unified_patch_go",
                type: .applyUnifiedPatchGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 7,
                instructions: instructions,
                task: "Apply the unified diff to \(path).",
                acceptance: acceptance,
                params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
            )
        }

        // Compute increment and modified return line for function a
        let inc = 2 + rng.nextInt(upperBound: 3)
        let oldTargetA = base[aRetIdx]
        let newTargetA = oldTargetA.replacingOccurrences(of: "n + 1", with: "n + \(inc)")

        // VeryHard gauntlet multi-section logic
        if difficulty == .veryHard {
            var removedSpans: [ClosedRange<Int>] = []

            // Create decoy clone files for target discovery (12-20 clones across nested dirs)
            let gauntlet = (config.decoyPolicy.style == .gauntlet)
            let cloneCount = gauntlet ? 20 : 12
            let clonePaths = makeDeepClonePaths(token: token, ext: "go", count: cloneCount, language: .go)
            for (i, clonePath) in clonePaths.enumerated() {
                let cloneLines = makePatchableClone(language: .go, origin: base, variant: i, includeSection4: true)
                fileSystem.setFile(clonePath, content: cloneLines.joined(separator: "\n"))
            }
            // Shuffle candidatePaths to hide target position
            let allCandidates = [path] + clonePaths
            let shuffleSeed = UInt32(truncatingIfNeeded: token.hashValue)
            let candidatePaths = stableShuffle(allCandidates, seed: shuffleSeed)

            // Section 1: modify a (three-line hunk)
            do {
                var modifyAHunk: [String] = []
                let modifyAOldStart = aOpenIdx + 1
                let removedBefore = removedLineCount(before: aOpenIdx, in: removedSpans)
                let modifyANewStart = newStart(oldStart1Based: modifyAOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                modifyAHunk.append(hunkHeader(modifyAOldStart, 3, modifyANewStart, 3))
                modifyAHunk.append(" \(base[aOpenIdx])")
                modifyAHunk.append("-\(oldTargetA)")
                modifyAHunk.append("+\(newTargetA)")
                modifyAHunk.append(" \(base[aRetIdx + 1])")
                hunks.append(modifyAHunk)
            }

            // Section 1: remove b (with context lines)
            guard let bRange = computeGoFunctionRange(base, fnName: "b") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let bStart = bRange.lowerBound
                let bEnd = bRange.upperBound
                let ctxBeforeIdx = max(0, bStart - 1)
                let ctxAfterIdx = min(base.count - 1, bEnd + 1)
                let hasAfterContext = ctxAfterIdx > bEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in bStart ... bEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(bRange)

            // Section 1: noise hunk on value
            do {
                let noiseText = buildGoNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange],
                    context: 3
                )
                if !noiseText.isEmpty {
                    hunks.append(noiseText.components(separatedBy: "\n"))
                }
            }

            // Section 2: modify d
            guard
                let dOpenIdx = base.firstIndex(where: { $0.hasPrefix("func d(") })
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            guard
                let dRetIdx = base[dOpenIdx...].firstIndex(where: { $0.contains("return n + 1") && $0.hasPrefix("    ") }),
                dRetIdx > dOpenIdx,
                dRetIdx + 1 < base.count,
                base[dRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let oldReturnD = base[dRetIdx]
                let inc2 = 2 + rng.nextInt(upperBound: 3)
                let newReturnD = oldReturnD.replacingOccurrences(of: "n + 1", with: "n + \(inc2)")

                var h: [String] = []
                let modifyOldStart = dOpenIdx + 1
                let removedBefore = removedLineCount(before: dOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[dOpenIdx])")
                h.append("-\(oldReturnD)")
                h.append("+\(newReturnD)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 2: remove e
            guard let eRange = computeGoFunctionRange(base, fnName: "e") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let eStart = eRange.lowerBound
                let eEnd = eRange.upperBound
                let ctxBeforeIdx = max(0, eStart - 1)
                let ctxAfterIdx = min(base.count - 1, eEnd + 1)
                let hasAfterContext = ctxAfterIdx > eEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in eStart ... eEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(eRange)

            // Section 2: noise hunk on value2
            do {
                let noiseText = buildGoNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange],
                    valueMarker: "const value2 = 7",
                    context: 3
                )
                if !noiseText.isEmpty {
                    hunks.append(noiseText.components(separatedBy: "\n"))
                }
            }

            // Section 3: modify g
            guard
                let gOpenIdx = base.firstIndex(where: { $0.hasPrefix("func g(") }),
                let gRetIdx = base.firstIndex(where: { $0.contains("return n * 2") }),
                gRetIdx + 1 < base.count,
                base[gRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let oldReturnG = base[gRetIdx]
                let newReturnG = oldReturnG.replacingOccurrences(of: "n * 2", with: "n * 3")

                var h: [String] = []
                let modifyOldStart = gOpenIdx + 1
                let removedBefore = removedLineCount(before: gOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[gOpenIdx])")
                h.append("-\(oldReturnG)")
                h.append("+\(newReturnG)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 3: remove h
            guard let hRange = computeGoFunctionRange(base, fnName: "h") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let hStart = hRange.lowerBound
                let hEnd = hRange.upperBound
                let ctxBeforeIdx = max(0, hStart - 1)
                let ctxAfterIdx = min(base.count - 1, hEnd + 1)
                let hasAfterContext = ctxAfterIdx > hEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in hStart ... hEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(hRange)

            // Section 3: noise hunk on value3 (additional noise)
            do {
                let noise3 = buildGoNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange],
                    valueMarker: "const value3 = 100",
                    context: 2
                )
                if !noise3.isEmpty {
                    hunks.append(noise3.components(separatedBy: "\n"))
                }
            }

            // Section 4: modify i
            guard
                let iOpenIdx = base.firstIndex(where: { $0.hasPrefix("func i(") }),
                let iRetIdx = base.firstIndex(where: { $0.contains("return n - 1") }),
                iRetIdx + 1 < base.count,
                base[iRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let oldReturnI = base[iRetIdx]
                let newReturnI = oldReturnI.replacingOccurrences(of: "n - 1", with: "n - 2")

                var h: [String] = []
                let modifyOldStart = iOpenIdx + 1
                let removedBefore = removedLineCount(before: iOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[iOpenIdx])")
                h.append("-\(oldReturnI)")
                h.append("+\(newReturnI)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 4: remove j
            guard let jRange = computeGoFunctionRange(base, fnName: "j") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let jStart = jRange.lowerBound
                let jEnd = jRange.upperBound
                let ctxBeforeIdx = max(0, jStart - 1)
                let ctxAfterIdx = min(base.count - 1, jEnd + 1)
                let hasAfterContext = ctxAfterIdx > jEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in jStart ... jEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(jRange)

            // Section 4: noise hunk on value4
            do {
                let noise4 = buildGoNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange, jRange],
                    valueMarker: "const value4 = 256",
                    context: 1
                )
                if !noise4.isEmpty {
                    hunks.append(noise4.components(separatedBy: "\n"))
                }
            }

            // Additional noise hunk on value2 with different context
            do {
                let noise2Extra = buildGoNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange, jRange],
                    valueMarker: "const value2 = 7",
                    context: 4
                )
                if !noise2Extra.isEmpty {
                    hunks.append(noise2Extra.components(separatedBy: "\n"))
                }
            }

            // Emit hunks to patch
            for hunk in hunks {
                patchLines.append(contentsOf: hunk)
            }

            let instructions = ["Apply the unified diff exactly to \(path)."]
            let acceptance = ["Final file equals applying the provided unified diff."]
            let maxEdits = switch difficulty {
            case .simple:
                4
            case .medium:
                7
            case .hard:
                12
            case .veryHard:
                28
            }

            var params: [String: BenchmarkJSONValue] = [
                "patch": .string(patchLines.joined(separator: "\n")),
                "difficulty": .string(difficulty.rawValue),
                "targetDiscovery": .boolean(true),
                "targetPath": .string(path),
                "candidatePaths": .array(candidatePaths.map { .string($0) })
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: candidatePaths,
                    maxEdits: maxEdits,
                    instructions: instructions,
                    task: "Apply the unified diff to one of the candidate files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "apply_unified_patch_go",
                type: .applyUnifiedPatchGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: candidatePaths,
                maxEdits: maxEdits,
                instructions: instructions,
                task: "Apply the unified diff to one of the candidate files.",
                acceptance: acceptance,
                params: params
            )
        }

        // Non‑VeryHard path (existing behavior)

        // Modify function a hunk (3-line window: signature, return line, closing brace)
        var modifyAHunk: [String] = []
        let modifyAOldStart = aOpenIdx + 1
        let modifyANewStart = modifyAOldStart + bofAdded
        modifyAHunk.append(hunkHeader(modifyAOldStart, 3, modifyANewStart, 3))
        modifyAHunk.append(" \(base[aOpenIdx])")
        modifyAHunk.append("-\(oldTargetA)")
        modifyAHunk.append("+\(newTargetA)")
        modifyAHunk.append(" \(base[aRetIdx + 1])")
        hunks.append(modifyAHunk)

        // extra noise lines buffer
        var extraNoiseLines: [String] = []

        if difficulty != .simple {
            // Remove function b using computed range
            guard let bRange = computeGoFunctionRange(base, fnName: "b") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }

            let bStart = bRange.lowerBound
            let bEnd = bRange.upperBound

            // Context one line before and (if present) one line after the removed span
            let ctxBeforeIdx = max(0, bStart - 1)
            let ctxAfterIdx = min(base.count - 1, bEnd + 1)
            let hasAfterContext = ctxAfterIdx > bEnd

            let oldLineStart = ctxBeforeIdx + 1
            let newLineStart = oldLineStart + bofAdded
            let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
            let newCount = hasAfterContext ? 2 : 1

            var removalHunk: [String] = []
            removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
            removalHunk.append(" \(base[ctxBeforeIdx])")
            for idx in bStart ... bEnd {
                removalHunk.append("-\(base[idx])")
            }
            if hasAfterContext {
                removalHunk.append(" \(base[ctxAfterIdx])")
            }
            hunks.append(removalHunk)

            // Noise hunk for hard/veryHard via helper (3-line context default)
            if difficulty == .hard || difficulty == .veryHard {
                let noiseText = buildGoNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange],
                    context: 3
                )
                if !noiseText.isEmpty {
                    extraNoiseLines = noiseText.components(separatedBy: "\n")
                }

                // For hard: add one more noise hunk with different context
                if difficulty == .hard {
                    let noise2 = buildGoNoiseHunk(
                        baseline: base,
                        bofAdded: bofAdded,
                        removedSpans: [bRange],
                        valueMarker: "const value = 42",
                        context: 1
                    )
                    if !noise2.isEmpty, !extraNoiseLines.isEmpty {
                        extraNoiseLines.append(contentsOf: noise2.components(separatedBy: "\n"))
                    }
                }
            }
        } else {
            // Simple difficulty: modify function b (no BOF header, no removal)
            guard
                let bOpenIdx = base.firstIndex(where: { $0.hasPrefix("func b(") }),
                let bRetIdx = base.firstIndex(where: { $0.contains("return s + s") }),
                bRetIdx + 1 < base.count,
                base[bRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_go",
                    type: .applyUnifiedPatchGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 4,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }

            var modifyBHunk: [String] = []
            let modifyBOldStart = bOpenIdx + 1
            let modifyBNewStart = modifyBOldStart // no BOF addition for simple
            modifyBHunk.append(hunkHeader(modifyBOldStart, 3, modifyBNewStart, 3))
            modifyBHunk.append(" \(base[bOpenIdx])")
            modifyBHunk.append("-\(base[bRetIdx])")
            modifyBHunk.append("+    return s")
            modifyBHunk.append(" \(base[bRetIdx + 1])")
            hunks.append(modifyBHunk)
        }

        // Emit hunks to patch
        for hunk in hunks {
            patchLines.append(contentsOf: hunk)
        }

        // Append noise hunk (if any)
        if !extraNoiseLines.isEmpty {
            patchLines.append(contentsOf: extraNoiseLines)
        }

        let instructions = ["Apply the unified diff exactly to \(path)."]
        let acceptance = ["Final file equals applying the provided unified diff."]
        let maxEdits = switch difficulty {
        case .simple:
            4
        case .medium:
            7
        case .hard:
            12
        case .veryHard:
            28
        }

        var params: [String: BenchmarkJSONValue] = [
            "patch": .string(patchLines.joined(separator: "\n")),
            "difficulty": .string(difficulty.rawValue)
        ]

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "apply_unified_patch_go",
                type: .applyUnifiedPatchGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: maxEdits,
                instructions: instructions,
                task: "Apply the unified diff to \(path).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "apply_unified_patch_go",
            type: .applyUnifiedPatchGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: [path],
            maxEdits: maxEdits,
            instructions: instructions,
            task: "Apply the unified diff to \(path).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - apply_unified_patch_swift

    private func appendSwiftSection2(_ lines: inout [String]) {
        lines.append("")
        lines.append("public func d(_ n: Int) -> Int {")
        lines.append("\treturn n + 1")
        lines.append("}")
        lines.append("")
        lines.append("public func e(_ s: String) -> String {")
        lines.append("\treturn s")
        lines.append("}")
        lines.append("")
        lines.append("public func f(_ xs: [Int]) -> Int {")
        lines.append("\treturn xs.count")
        lines.append("}")
        lines.append("")
        lines.append("public let value2 = 7")
    }

    private func appendSwiftSection3(_ lines: inout [String]) {
        lines.append("")
        lines.append("public func g(_ n: Int) -> Int {")
        lines.append("\treturn n * 2")
        lines.append("}")
        lines.append("")
        lines.append("public func h(_ s: String) -> String {")
        lines.append("\treturn s")
        lines.append("}")
        lines.append("")
        lines.append("public let value3 = 100")
    }

    private func appendSwiftSection4(_ lines: inout [String]) {
        lines.append("")
        lines.append("public func i(_ n: Int) -> Int {")
        lines.append("\treturn n - 1")
        lines.append("}")
        lines.append("")
        lines.append("public func j(_ s: String) -> String {")
        lines.append("\treturn s.trimmingCharacters(in: .whitespaces)")
        lines.append("}")
        lines.append("")
        lines.append("public let value4 = 256")
    }

    private func generateUnifiedPatchSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = config
        let token = randomIdentifier(rng: &rng)
        let path = "src/swift/patchables/Patch_\(token).swift"

        func hunkHeader(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }

        // Build baseline (preserve existing logic; Swift uses tabs)
        var base: [String] = []
        base.append("public func a(_ n: Int) -> Int {")
        base.append("\treturn n + 1")
        base.append("}")
        base.append("")
        base.append("public func b(_ s: String) -> String {")
        base.append("\treturn s.uppercased()")
        base.append("}")
        base.append("")
        if difficulty != .simple {
            base.append("public func c(_ xs: [Int]) -> Int {")
            base.append("\treturn xs.reduce(0, +)")
            base.append("}")
            base.append("")
        }
        base.append("public let value = 42")

        // VeryHard gauntlet: append additional sections to baseline
        if difficulty == .veryHard {
            appendSwiftSection2(&base)
            appendSwiftSection3(&base)
            appendSwiftSection4(&base)
        }

        fileSystem.setFile(path, content: base.joined(separator: "\n"))

        // Patch header
        let useUnknownHeaders = (difficulty == .veryHard)
        var patchLines: [String] = []
        patchLines.append(useUnknownHeaders ? "--- a/UNKNOWN" : "--- a/\(path)")
        patchLines.append(useUnknownHeaders ? "+++ b/UNKNOWN" : "+++ b/\(path)")

        // Hunks container
        var hunks: [[String]] = []

        // BOF header addition for medium/hard/veryHard
        let bofAdded = (difficulty != .simple) ? 2 : 0
        if bofAdded > 0 {
            var headerHunk: [String] = []
            headerHunk.append(hunkHeader(1, 0, 1, 2))
            headerHunk.append("+// NOTE: patched by benchmark")
            headerHunk.append("+")
            hunks.append(headerHunk)
        }

        // Modify function a
        guard
            let aOpenIdx = base.firstIndex(where: { $0.hasPrefix("public func a(") }),
            let aRetIdx = base.firstIndex(where: { $0 == "\treturn n + 1" }),
            aRetIdx + 1 < base.count,
            base[aRetIdx + 1] == "}"
        else {
            let instructions = ["Apply the unified diff exactly to \(path)."]
            let acceptance = ["Final file equals applying the provided unified diff."]
            return BenchmarkTaskSpec(
                id: "apply_unified_patch_swift",
                type: .applyUnifiedPatchSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: 6,
                instructions: instructions,
                task: "Apply the unified diff to \(path).",
                acceptance: acceptance,
                params: ["patch": .string("")]
            )
        }

        let inc = 2 + rng.nextInt(upperBound: 3)
        let oldTargetA = base[aRetIdx]
        let newTargetA = oldTargetA.replacingOccurrences(of: "n + 1", with: "n + \(inc)")

        // VeryHard gauntlet multi-section logic
        if difficulty == .veryHard {
            var removedSpans: [ClosedRange<Int>] = []

            // Create decoy clone files for target discovery (12-20 clones across nested dirs)
            let gauntlet = (config.decoyPolicy.style == .gauntlet)
            let cloneCount = gauntlet ? 20 : 12
            let clonePaths = makeDeepClonePaths(token: token, ext: "swift", count: cloneCount, language: .swift)
            for (i, clonePath) in clonePaths.enumerated() {
                let cloneLines = makePatchableClone(language: .swift, origin: base, variant: i, includeSection4: true)
                fileSystem.setFile(clonePath, content: cloneLines.joined(separator: "\n"))
            }
            // Shuffle candidatePaths to hide target position
            let allCandidates = [path] + clonePaths
            let shuffleSeed = UInt32(truncatingIfNeeded: token.hashValue)
            let candidatePaths = stableShuffle(allCandidates, seed: shuffleSeed)

            // Section 1: modify a (three-line hunk)
            do {
                var modifyAHunk: [String] = []
                let modifyAOldStart = aOpenIdx + 1
                let removedBefore = removedLineCount(before: aOpenIdx, in: removedSpans)
                let modifyANewStart = newStart(oldStart1Based: modifyAOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                modifyAHunk.append(hunkHeader(modifyAOldStart, 3, modifyANewStart, 3))
                modifyAHunk.append(" \(base[aOpenIdx])")
                modifyAHunk.append("-\(oldTargetA)")
                modifyAHunk.append("+\(newTargetA)")
                modifyAHunk.append(" \(base[aRetIdx + 1])")
                hunks.append(modifyAHunk)
            }

            // Section 1: remove b (with context lines)
            guard let bRange = computeSwiftFunctionRange(base, fnName: "b") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let bStart = bRange.lowerBound
                let bEnd = bRange.upperBound
                let ctxBeforeIdx = max(0, bStart - 1)
                let ctxAfterIdx = min(base.count - 1, bEnd + 1)
                let hasAfterContext = ctxAfterIdx > bEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in bStart ... bEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(bRange)

            // Section 1: noise hunk on value
            do {
                let noiseText = buildSwiftNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange],
                    context: 3
                )
                if !noiseText.isEmpty {
                    hunks.append(noiseText.components(separatedBy: "\n"))
                }
            }

            // Section 2: modify d
            guard
                let dOpenIdx = base.firstIndex(where: { $0.hasPrefix("public func d(") })
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            guard
                let dRetIdx = base[dOpenIdx...].firstIndex(where: { $0 == "\treturn n + 1" }),
                dRetIdx > dOpenIdx,
                dRetIdx + 1 < base.count,
                base[dRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let oldReturnD = base[dRetIdx]
                let inc2 = 2 + rng.nextInt(upperBound: 3)
                let newReturnD = oldReturnD.replacingOccurrences(of: "n + 1", with: "n + \(inc2)")

                var h: [String] = []
                let modifyOldStart = dOpenIdx + 1
                let removedBefore = removedLineCount(before: dOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[dOpenIdx])")
                h.append("-\(oldReturnD)")
                h.append("+\(newReturnD)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 2: remove e
            guard let eRange = computeSwiftFunctionRange(base, fnName: "e") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let eStart = eRange.lowerBound
                let eEnd = eRange.upperBound
                let ctxBeforeIdx = max(0, eStart - 1)
                let ctxAfterIdx = min(base.count - 1, eEnd + 1)
                let hasAfterContext = ctxAfterIdx > eEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in eStart ... eEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(eRange)

            // Section 2: noise hunk on value2
            do {
                let noiseText = buildSwiftNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange],
                    valueMarker: "public let value2 = 7",
                    context: 3
                )
                if !noiseText.isEmpty {
                    hunks.append(noiseText.components(separatedBy: "\n"))
                }
            }

            // Section 3: modify g
            guard
                let gOpenIdx = base.firstIndex(where: { $0.hasPrefix("public func g(") }),
                let gRetIdx = base.firstIndex(where: { $0 == "\treturn n * 2" }),
                gRetIdx + 1 < base.count,
                base[gRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let oldReturnG = base[gRetIdx]
                let newReturnG = oldReturnG.replacingOccurrences(of: "n * 2", with: "n * 3")

                var h: [String] = []
                let modifyOldStart = gOpenIdx + 1
                let removedBefore = removedLineCount(before: gOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[gOpenIdx])")
                h.append("-\(oldReturnG)")
                h.append("+\(newReturnG)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 3: remove h
            guard let hRange = computeSwiftFunctionRange(base, fnName: "h") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let hStart = hRange.lowerBound
                let hEnd = hRange.upperBound
                let ctxBeforeIdx = max(0, hStart - 1)
                let ctxAfterIdx = min(base.count - 1, hEnd + 1)
                let hasAfterContext = ctxAfterIdx > hEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in hStart ... hEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(hRange)

            // Section 3: noise hunk on value3 (additional noise)
            do {
                let noise3 = buildSwiftNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange],
                    valueMarker: "public let value3 = 100",
                    context: 2
                )
                if !noise3.isEmpty {
                    hunks.append(noise3.components(separatedBy: "\n"))
                }
            }

            // Section 4: modify i
            guard
                let iOpenIdx = base.firstIndex(where: { $0.hasPrefix("public func i(") }),
                let iRetIdx = base.firstIndex(where: { $0 == "\treturn n - 1" }),
                iRetIdx + 1 < base.count,
                base[iRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let oldReturnI = base[iRetIdx]
                let newReturnI = oldReturnI.replacingOccurrences(of: "n - 1", with: "n - 2")

                var h: [String] = []
                let modifyOldStart = iOpenIdx + 1
                let removedBefore = removedLineCount(before: iOpenIdx, in: removedSpans)
                let modifyNewStart = newStart(oldStart1Based: modifyOldStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                h.append(hunkHeader(modifyOldStart, 3, modifyNewStart, 3))
                h.append(" \(base[iOpenIdx])")
                h.append("-\(oldReturnI)")
                h.append("+\(newReturnI)")
                h.append(" }")
                hunks.append(h)
            }

            // Section 4: remove j
            guard let jRange = computeSwiftFunctionRange(base, fnName: "j") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }
            do {
                let jStart = jRange.lowerBound
                let jEnd = jRange.upperBound
                let ctxBeforeIdx = max(0, jStart - 1)
                let ctxAfterIdx = min(base.count - 1, jEnd + 1)
                let hasAfterContext = ctxAfterIdx > jEnd

                let oldLineStart = ctxBeforeIdx + 1
                let removedBefore = removedLineCount(before: ctxBeforeIdx, in: removedSpans)
                let newLineStart = newStart(oldStart1Based: oldLineStart, bofAdded: bofAdded, removedSpansBeforeTarget: removedBefore)
                let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
                let newCount = hasAfterContext ? 2 : 1

                var removalHunk: [String] = []
                removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
                removalHunk.append(" \(base[ctxBeforeIdx])")
                for idx in jStart ... jEnd {
                    removalHunk.append("-\(base[idx])")
                }
                if hasAfterContext {
                    removalHunk.append(" \(base[ctxAfterIdx])")
                }
                hunks.append(removalHunk)
            }
            removedSpans.append(jRange)

            // Section 4: noise hunk on value4
            do {
                let noise4 = buildSwiftNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange, jRange],
                    valueMarker: "public let value4 = 256",
                    context: 1
                )
                if !noise4.isEmpty {
                    hunks.append(noise4.components(separatedBy: "\n"))
                }
            }

            // Additional noise hunk on value2 with different context
            do {
                let noise2Extra = buildSwiftNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange, eRange, hRange, jRange],
                    valueMarker: "public let value2 = 7",
                    context: 4
                )
                if !noise2Extra.isEmpty {
                    hunks.append(noise2Extra.components(separatedBy: "\n"))
                }
            }

            // Emit hunks to patch
            for hunk in hunks {
                patchLines.append(contentsOf: hunk)
            }

            let instructions = ["Apply the unified diff exactly to \(path)."]
            let acceptance = ["Final file equals applying the provided unified diff."]
            let maxEdits = switch difficulty {
            case .simple:
                4
            case .medium:
                7
            case .hard:
                12
            case .veryHard:
                28
            }

            let patchString = patchLines.joined(separator: "\n")
            // Self-check: ensure the patch we generated is actually valid
            let baseText = base.joined(separator: "\n")
            if SimpleUnifiedPatchApplier.apply(patch: patchString, to: baseText) == nil {
                assertionFailure("Generator produced invalid unified patch for \(path) at difficulty \(difficulty)")
                #if DEBUG
                    fatalError("Invalid unified patch generated; fix generator")
                #endif
            }

            var params: [String: BenchmarkJSONValue] = [
                "patch": .string(patchString),
                "difficulty": .string(difficulty.rawValue),
                "targetDiscovery": .boolean(true),
                "targetPath": .string(path),
                "candidatePaths": .array(candidatePaths.map { .string($0) })
            ]

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: candidatePaths,
                    maxEdits: maxEdits,
                    instructions: instructions,
                    task: "Apply the unified diff to one of the candidate files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "apply_unified_patch_swift",
                type: .applyUnifiedPatchSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: candidatePaths,
                maxEdits: maxEdits,
                instructions: instructions,
                task: "Apply the unified diff to one of the candidate files.",
                acceptance: acceptance,
                params: params
            )
        }

        // Non‑VeryHard path (existing behavior)

        // 3-line modify hunk: signature, return line, closing brace
        var modifyAHunk: [String] = []
        let modifyAOldStart = aOpenIdx + 1
        let modifyANewStart = modifyAOldStart + bofAdded
        modifyAHunk.append(hunkHeader(modifyAOldStart, 3, modifyANewStart, 3))
        modifyAHunk.append(" \(base[aOpenIdx])")
        modifyAHunk.append("-\(oldTargetA)")
        modifyAHunk.append("+\(newTargetA)")
        modifyAHunk.append(" \(base[aRetIdx + 1])")
        hunks.append(modifyAHunk)

        // Buffer for optional noise hunk lines
        var extraNoiseLines: [String] = []

        if difficulty != .simple {
            // Remove function b using computed range
            guard let bRange = computeSwiftFunctionRange(base, fnName: "b") else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 7,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }

            let bStart = bRange.lowerBound
            let bEnd = bRange.upperBound

            // Context one line before and possibly one after the removed span
            let ctxBeforeIdx = max(0, bStart - 1)
            let ctxAfterIdx = min(base.count - 1, bEnd + 1)
            let hasAfterContext = ctxAfterIdx > bEnd

            let oldLineStart = ctxBeforeIdx + 1
            let newLineStart = oldLineStart + bofAdded
            let oldCount = (ctxAfterIdx - ctxBeforeIdx + 1)
            let newCount = hasAfterContext ? 2 : 1

            var removalHunk: [String] = []
            removalHunk.append(hunkHeader(oldLineStart, oldCount, newLineStart, newCount))
            removalHunk.append(" \(base[ctxBeforeIdx])")
            for idx in bStart ... bEnd {
                removalHunk.append("-\(base[idx])")
            }
            if hasAfterContext {
                removalHunk.append(" \(base[ctxAfterIdx])")
            }
            hunks.append(removalHunk)

            // Noise hunk for hard/veryHard via helper (3-line context default)
            if difficulty == .hard || difficulty == .veryHard {
                let noiseText = buildSwiftNoiseHunk(
                    baseline: base,
                    bofAdded: bofAdded,
                    removedSpans: [bRange],
                    context: 3
                )
                if !noiseText.isEmpty {
                    extraNoiseLines = noiseText.components(separatedBy: "\n")
                }

                // For hard: add one more noise hunk with different context
                if difficulty == .hard {
                    let noise2 = buildSwiftNoiseHunk(
                        baseline: base,
                        bofAdded: bofAdded,
                        removedSpans: [bRange],
                        valueMarker: "public let value = 42",
                        context: 1
                    )
                    if !noise2.isEmpty, !extraNoiseLines.isEmpty {
                        extraNoiseLines.append(contentsOf: noise2.components(separatedBy: "\n"))
                    }
                }
            }
        } else {
            // Simple difficulty: modify function b (no BOF header, no removal)
            guard
                let bOpenIdx = base.firstIndex(where: { $0.hasPrefix("public func b(") }),
                let bRetIdx = base.firstIndex(where: { $0 == "\treturn s.uppercased()" }),
                bRetIdx + 1 < base.count,
                base[bRetIdx + 1] == "}"
            else {
                let instructions = ["Apply the unified diff exactly to \(path)."]
                let acceptance = ["Final file equals applying the provided unified diff."]
                return BenchmarkTaskSpec(
                    id: "apply_unified_patch_swift",
                    type: .applyUnifiedPatchSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: [path],
                    maxEdits: 4,
                    instructions: instructions,
                    task: "Apply the unified diff to \(path).",
                    acceptance: acceptance,
                    params: ["patch": .string(""), "difficulty": .string(difficulty.rawValue)]
                )
            }

            var modifyBHunk: [String] = []
            let modifyBOldStart = bOpenIdx + 1
            let modifyBNewStart = modifyBOldStart // no BOF addition for simple
            modifyBHunk.append(hunkHeader(modifyBOldStart, 3, modifyBNewStart, 3))
            modifyBHunk.append(" \(base[bOpenIdx])")
            modifyBHunk.append("-\(base[bRetIdx])")
            modifyBHunk.append("+\treturn s.lowercased()")
            modifyBHunk.append(" \(base[bRetIdx + 1])")
            hunks.append(modifyBHunk)
        }

        // Emit hunks to patch
        for hunk in hunks {
            patchLines.append(contentsOf: hunk)
        }

        // Append noise hunk (if any)
        if !extraNoiseLines.isEmpty {
            patchLines.append(contentsOf: extraNoiseLines)
        }

        let instructions = ["Apply the unified diff exactly to \(path)."]
        let acceptance = ["Final file equals applying the provided unified diff."]
        let maxEdits = switch difficulty {
        case .simple:
            4
        case .medium:
            7
        case .hard:
            12
        case .veryHard:
            28
        }

        let patchString = patchLines.joined(separator: "\n")
        // Self-check: ensure the patch we generated is actually valid
        let baseText = base.joined(separator: "\n")
        if SimpleUnifiedPatchApplier.apply(patch: patchString, to: baseText) == nil {
            assertionFailure("Generator produced invalid unified patch for \(path) at difficulty \(difficulty)")
            #if DEBUG
                fatalError("Invalid unified patch generated; fix generator")
            #endif
        }

        var params: [String: BenchmarkJSONValue] = [
            "patch": .string(patchString),
            "difficulty": .string(difficulty.rawValue)
        ]

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "apply_unified_patch_swift",
                type: .applyUnifiedPatchSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: [path],
                maxEdits: maxEdits,
                instructions: instructions,
                task: "Apply the unified diff to \(path).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "apply_unified_patch_swift",
            type: .applyUnifiedPatchSwift,
            language: .swift,
            difficulty: difficulty,
            selectFiles: [path],
            maxEdits: maxEdits,
            instructions: instructions,
            task: "Apply the unified diff to \(path).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - insert_guard_ts

    private func generateInsertGuardTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium:
            [tsWorkPath]
        case .hard:
            [tsWorkPath, "src/ts/work/WorkA.ts"]
        case .veryHard:
            [tsWorkPath, "src/ts/work/WorkA.ts", "src/ts/work/WorkB.ts"]
        case .simple:
            [tsWorkPath]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        let snippet = "if (n < 0) {\n    return 0;\n}"
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        var guardSpecs: [(path: String, uid: String)] = []

        for path in files {
            let uid = randomIdentifier(rng: &rng)
            var existing = fileSystem.content(for: path) ?? ""

            // Determine complexity based on difficulty
            let nearMiss: Int
            let shadowClusters: Int
            switch difficulty {
            case .simple, .medium:
                nearMiss = 2
                shadowClusters = 0
            case .hard:
                nearMiss = 4
                shadowClusters = 1
            case .veryHard:
                nearMiss = 6
                shadowClusters = 2
            }

            if isMarkerless {
                // Markerless mode: use complex generator without anchors
                let hardened = BelievableCodeFactory.tsClampFamilyComplex(
                    rng: &rng,
                    mainName: "clamp",
                    anchorUID: nil,
                    decoyAnchorUIDs: [],
                    nearMissFunctions: nearMiss,
                    inFunctionShadowClusters: shadowClusters
                )
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(hardened)
            } else {
                // Medium mode: use complex generator with anchors
                let decoyUIDs = (0 ..< 3).map { _ in randomIdentifier(rng: &rng) }
                let hardened = BelievableCodeFactory.tsClampFamilyComplex(
                    rng: &rng,
                    mainName: "clamp",
                    anchorUID: uid,
                    decoyAnchorUIDs: decoyUIDs,
                    nearMissFunctions: nearMiss,
                    inFunctionShadowClusters: shadowClusters > 0 ? 1 : 0
                )
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(hardened)
            }

            // Add helper code to increase file size and ambiguity
            let helperLines = isMarkerless ? max(80, scaledLines(noise.lineCount, difficulty: difficulty)) : max(30, scaledLines(noise.lineCount / 3, difficulty: .hard))
            let helper = BelievableCodeFactory.tsUtilityModule(rng: &rng, module: "ModuleASupport", approxLines: helperLines)
            existing.append("\n")
            existing.append(helper)
            fileSystem.setFile(path, content: existing)
            guardSpecs.append((path, uid))
        }
        let fullDecoys = decoys > 0 ? makeSimilarTsDecoys(rng: &rng, around: tsWorkPath) : []
        for decoy in fullDecoys {
            fileSystem.setFile(decoy.path, content: decoy.content)
        }

        let instructions: [String]
        let acceptance: [String]

        if isMarkerless {
            instructions = [
                "Insert the provided guard block inside the clamp() function, immediately after the line that declares 'const normalized'.",
                "The guard block must be indented with 4 spaces to match surrounding code.",
                "Only modify the clamp() function (not clampPositive, clampBounded, or other similar functions).",
                "Your search block must include the function signature, the normalized line, and at least one more line (4–6 lines total).",
                "Do NOT modify any other code outside the clamp() function."
            ]
            acceptance = [
                "Guard snippet appears inside clamp() function immediately after the normalized declaration.",
                "Inserted code uses 4-space indentation without tabs.",
                "Only the clamp() function was modified.",
                "Other functions (clampPositive, clampBounded) remain unchanged.",
                "Exactly \(files.count) file(s) were modified."
            ]
        } else {
            instructions = [
                "Insert the provided guard block between the ANCHOR:start and ANCHOR:end comments with the matching UID.",
                "The guard block must be indented with 4 spaces (not tabs) to match the anchor comment level.",
                "Insert the guard on the line immediately after ANCHOR:start:UID.",
                "Do NOT modify the anchor comments themselves.",
                "Do NOT modify any other code outside the anchor region.",
                "There are decoy anchor pairs with different UIDs - only insert into the matching UID."
            ]
            acceptance = [
                "Guard snippet appears exactly between matching anchors in each file.",
                "The guard is inserted immediately after the ANCHOR:start line.",
                "Inserted code uses 4-space indentation without tabs.",
                "Anchor comments remain unchanged.",
                "No other lines changed in any listed file.",
                "Exactly \(files.count) file(s) were modified."
            ]
        }

        var params: [String: BenchmarkJSONValue] = [
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoys),
            "markerless": .boolean(isMarkerless)
        ]

        if isMarkerless {
            params["functionName"] = .string("clamp")
            params["insertAfterPattern"] = .string("normalized")
            params["snippet"] = .string(snippet)
        } else {
            params["guards"] = .array(guardSpecs.map {
                .object([
                    "path": .string($0.path),
                    "uid": .string($0.uid),
                    "snippet": .string(snippet)
                ])
            })
        }
        if !fullDecoys.isEmpty {
            params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "insert_guard_ts",
                type: .insertGuardTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, files.count),
                instructions: instructions,
                task: "Insert the guard block exactly between the anchor comments across multiple files.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "insert_guard_ts",
            type: .insertGuardTs,
            language: .ts,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: max(1, files.count),
            instructions: instructions,
            task: "Insert the guard block exactly between the anchor comments across multiple files.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - insert_guard_go

    private func generateInsertGuardGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [goWorkPath]
        case .hard:
            [goWorkPath, "src/go/work/WorkA.go"]
        case .veryHard:
            [goWorkPath, "src/go/work/WorkA.go", "src/go/work/WorkB.go"]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        _ = noise
        let snippet = "if n < 0 {\n    return 0\n}"
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        var guardSpecs: [(path: String, uid: String)] = []

        for path in files {
            let uid = randomIdentifier(rng: &rng)
            var existing = fileSystem.content(for: path) ?? ""

            // Ensure package header is present
            if existing.isEmpty || !existing.contains("package work") {
                existing = "package work\n\n"
            }

            // Determine complexity based on difficulty
            let nearMiss: Int
            let shadowClusters: Int
            switch difficulty {
            case .simple, .medium:
                nearMiss = 2
                shadowClusters = 0
            case .hard:
                nearMiss = 4
                shadowClusters = 1
            case .veryHard:
                nearMiss = 6
                shadowClusters = 2
            }

            if isMarkerless {
                // Markerless mode: use complex generator without anchors
                let hardened = BelievableCodeFactory.goClampFamilyComplex(
                    rng: &rng,
                    mainName: "Clamp",
                    anchorUID: nil,
                    decoyAnchorUIDs: [],
                    nearMissFunctions: nearMiss,
                    inFunctionShadowClusters: shadowClusters
                )
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(hardened)
            } else {
                // Medium mode: use complex generator with anchors
                let decoyUIDs = (0 ..< 3).map { _ in randomIdentifier(rng: &rng) }
                let hardened = BelievableCodeFactory.goClampFamilyComplex(
                    rng: &rng,
                    mainName: "Clamp",
                    anchorUID: uid,
                    decoyAnchorUIDs: decoyUIDs,
                    nearMissFunctions: nearMiss,
                    inFunctionShadowClusters: shadowClusters > 0 ? 1 : 0
                )
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(hardened)
            }
            fileSystem.setFile(path, content: existing)
            guardSpecs.append((path, uid))
        }
        var decoyPaths: [String] = []
        if decoys >= 1 {
            let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "GuardShadow")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        if decoys >= 2 {
            let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "GuardClone")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }

        let instructions: [String]
        let acceptance: [String]

        if isMarkerless {
            instructions = [
                "Insert the provided guard block inside the Clamp() function, immediately after the line that declares 'normalized := n'.",
                "The guard block must be indented with 4 spaces to match surrounding code.",
                "Only modify the Clamp() function (not ClampPositive, ClampBounded, or other similar functions).",
                "Your search block must include the function signature, the normalized line, and at least one more line (4-6 lines total).",
                "Do NOT modify any other code outside the Clamp() function."
            ]
            acceptance = [
                "Guard snippet appears inside Clamp() function immediately after the normalized declaration.",
                "Inserted code uses 4-space indentation without tabs.",
                "Only the Clamp() function was modified.",
                "Other functions (ClampPositive, ClampBounded) remain unchanged.",
                "Exactly \(files.count) file(s) were modified."
            ]
        } else {
            instructions = [
                "Insert the provided guard block between the ANCHOR:start and ANCHOR:end comments with the matching UID.",
                "The guard block must be indented with 4 spaces (not tabs) to match the anchor comment level.",
                "Insert the guard on the line immediately after ANCHOR:start:UID.",
                "Do NOT modify the anchor comments themselves.",
                "Do NOT modify any other code outside the anchor region.",
                "There are decoy anchor pairs with different UIDs - only insert into the matching UID."
            ]
            acceptance = [
                "Guard snippet appears exactly between matching anchors in each file.",
                "The guard is inserted immediately after the ANCHOR:start line.",
                "Inserted code uses 4-space indentation without tabs.",
                "Anchor comments remain unchanged.",
                "No other lines changed in any listed file.",
                "Exactly \(files.count) file(s) were modified."
            ]
        }

        var params: [String: BenchmarkJSONValue] = [
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoys),
            "markerless": .boolean(isMarkerless)
        ]

        if isMarkerless {
            params["functionName"] = .string("Clamp")
            params["insertAfterPattern"] = .string("normalized")
            params["snippet"] = .string(snippet)
        } else {
            params["guards"] = .array(guardSpecs.map {
                .object([
                    "path": .string($0.path),
                    "uid": .string($0.uid),
                    "snippet": .string(snippet)
                ])
            })
        }
        if !decoyPaths.isEmpty {
            params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "insert_guard_go",
                type: .insertGuardGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, files.count),
                instructions: instructions,
                task: "Insert the guard block exactly between the anchor comments across multiple files.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "insert_guard_go",
            type: .insertGuardGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: max(1, files.count),
            instructions: instructions,
            task: "Insert the guard block exactly between the anchor comments across multiple files.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - insert_guard_swift

    private func generateInsertGuardSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [swiftWorkPath]
        case .hard:
            [swiftWorkPath, "src/swift/work/WorkA.swift"]
        case .veryHard:
            [swiftWorkPath, "src/swift/work/WorkA.swift", "src/swift/work/WorkB.swift"]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        _ = noise
        let snippet = "if n < 0 {\n\treturn 0\n}"
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        var guardSpecs: [(path: String, uid: String)] = []

        for path in files {
            let uid = randomIdentifier(rng: &rng)
            var existing = fileSystem.content(for: path) ?? ""

            // Determine complexity based on difficulty
            let nearMiss: Int
            let shadowClusters: Int
            switch difficulty {
            case .simple, .medium:
                nearMiss = 2
                shadowClusters = 0
            case .hard:
                nearMiss = 4
                shadowClusters = 1
            case .veryHard:
                nearMiss = 6
                shadowClusters = 2
            }

            if isMarkerless {
                // Markerless mode: use complex generator without anchors
                let hardened = BelievableCodeFactory.swiftClampFamilyComplex(
                    rng: &rng,
                    mainName: "clamp",
                    anchorUID: nil,
                    decoyAnchorUIDs: [],
                    nearMissFunctions: nearMiss,
                    inFunctionShadowClusters: shadowClusters
                )
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(hardened)
            } else {
                // Medium mode: use complex generator with anchors
                let decoyUIDs = (0 ..< 3).map { _ in randomIdentifier(rng: &rng) }
                let hardened = BelievableCodeFactory.swiftClampFamilyComplex(
                    rng: &rng,
                    mainName: "clamp",
                    anchorUID: uid,
                    decoyAnchorUIDs: decoyUIDs,
                    nearMissFunctions: nearMiss,
                    inFunctionShadowClusters: shadowClusters > 0 ? 1 : 0
                )
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(hardened)
            }
            fileSystem.setFile(path, content: existing)
            guardSpecs.append((path, uid))
        }
        var decoyPaths: [String] = []
        if decoys >= 1 {
            let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "GuardShadow")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }
        if decoys >= 2 {
            let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "GuardClone")
            fileSystem.setFile(decoy.path, content: decoy.content)
            decoyPaths.append(decoy.path)
        }

        let instructions: [String]
        let acceptance: [String]

        if isMarkerless {
            instructions = [
                "Insert the provided guard block inside the clamp() function, immediately after the line that declares 'let normalized'.",
                "The guard block must be indented with tabs to match surrounding code.",
                "Only modify the clamp() function (not clampPositive, clampBounded, or other similar functions).",
                "Your search block must include the function signature, the normalized line, and at least one more line (4-6 lines total).",
                "Do NOT modify any other code outside the clamp() function."
            ]
            acceptance = [
                "Guard snippet appears inside clamp() function immediately after the normalized declaration.",
                "Inserted code uses tab indentation without spaces.",
                "Only the clamp() function was modified.",
                "Other functions (clampPositive, clampBounded) remain unchanged.",
                "Exactly \(files.count) file(s) were modified."
            ]
        } else {
            instructions = [
                "Insert the provided guard block between the ANCHOR:start and ANCHOR:end comments with the matching UID.",
                "The guard block must be indented with tabs (not spaces) to match the anchor comment level.",
                "Insert the guard on the line immediately after ANCHOR:start:UID.",
                "Do NOT modify the anchor comments themselves.",
                "Do NOT modify any other code outside the anchor region.",
                "There are decoy anchor pairs with different UIDs - only insert into the matching UID."
            ]
            acceptance = [
                "Guard snippet appears exactly between matching anchors in each file.",
                "The guard is inserted immediately after the ANCHOR:start line.",
                "Inserted code uses tab indentation without spaces.",
                "Anchor comments remain unchanged.",
                "No other lines changed in any listed file.",
                "Exactly \(files.count) file(s) were modified."
            ]
        }

        var params: [String: BenchmarkJSONValue] = [
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoys),
            "markerless": .boolean(isMarkerless)
        ]

        if isMarkerless {
            params["functionName"] = .string("clamp")
            params["insertAfterPattern"] = .string("normalized")
            params["snippet"] = .string(snippet)
        } else {
            params["guards"] = .array(guardSpecs.map {
                .object([
                    "path": .string($0.path),
                    "uid": .string($0.uid),
                    "snippet": .string(snippet)
                ])
            })
        }
        if !decoyPaths.isEmpty {
            params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "insert_guard_swift",
                type: .insertGuardSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, files.count),
                instructions: instructions,
                task: "Insert the guard block exactly between the anchor comments across multiple files.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "insert_guard_swift",
            type: .insertGuardSwift,
            language: .swift,
            difficulty: difficulty,
            selectFiles: files,
            maxEdits: max(1, files.count),
            instructions: instructions,
            task: "Insert the guard block exactly between the anchor comments across multiple files.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - patch_block_ts

    private func generatePatchBlockTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium:
            [tsWorkPath]
        case .hard:
            [tsWorkPath, "src/ts/work/WorkA.ts"]
        case .veryHard:
            [tsWorkPath, "src/ts/work/WorkA.ts", "src/ts/work/WorkB.ts"]
        case .simple:
            [tsWorkPath]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        let snippet = """
        export function block2(n: number): number {
            const squared = n * n;
            return squared;
        }
        """
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        let functionName = "block2"

        if isMarkerless {
            // Markerless mode: create ambiguous neighbor functions
            for path in files {
                var existing = fileSystem.content(for: path) ?? ""
                let targetBlock = """
                export function block2(n: number): number {
                    return n * 2;
                }
                """
                let neighborBlock1 = """
                export function block2Alt(n: number): number {
                    return n * 2;
                }
                """
                let neighborBlock2 = """
                export function block2Helper(n: number): number {
                    // helper function
                    return n * 2;
                }
                """
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(targetBlock)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(neighborBlock1)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(neighborBlock2)
                fileSystem.setFile(path, content: existing)
            }

            let fullDecoys = decoys > 0 ? makeSimilarTsDecoys(rng: &rng, around: tsWorkPath) : []
            for decoy in fullDecoys {
                fileSystem.setFile(decoy.path, content: decoy.content)
            }

            let instructions = [
                "Locate the function named '\(functionName)' in each file.",
                "Replace its entire body with the provided snippet.",
                "Your <search> block must include: the function signature line, at least one line from the body, and the closing brace (3-8 lines total).",
                "Use 4 spaces for indentation (NOT tabs).",
                "Do NOT modify other functions or code outside '\(functionName)'.",
                "Use precise search-replace; do NOT use placeholders."
            ]
            let acceptance = [
                "The function '\(functionName)' body exactly matches the provided snippet in each file.",
                "Other functions (block2Alt, block2Helper, etc.) remain unchanged.",
                "No code outside '\(functionName)' was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]

            var params: [String: BenchmarkJSONValue] = [
                "functionName": .string(functionName),
                "snippet": .string(snippet),
                "markerless": .boolean(true),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !fullDecoys.isEmpty {
                params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "patch_block_ts",
                    type: .patchBlockTs,
                    language: .ts,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(2, files.count * 2),
                    instructions: instructions,
                    task: "Replace the body of function '\(functionName)' in each file with the provided snippet.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "patch_block_ts",
                type: .patchBlockTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(2, files.count * 2),
                instructions: instructions,
                task: "Replace the body of function '\(functionName)' in each file with the provided snippet.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Marker-based mode (Medium and below)
            var blockSpecs: [(path: String, uid: String)] = []
            for path in files {
                let uid = randomIdentifier(rng: &rng)
                var existing = fileSystem.content(for: path) ?? ""
                let block = """
                /* BLOCK START:\(uid) */
                export function block2(n: number): number {
                    return n * 2;
                }
                /* BLOCK END:\(uid) */
                """
                let twinUID = randomIdentifier(rng: &rng)
                let twinBlock = """
                /* BLOCK START:\(twinUID) */
                export function block2(n: number): number {
                    // secondary block
                    return n * 2;
                }
                /* BLOCK END:\(twinUID) */
                """
                let shadowUID = randomIdentifier(rng: &rng)
                let shadowBlock = """
                /* BLOCK START:\(shadowUID) */
                export function block2(n: number): number {

                    return n * 2;
                }
                /* BLOCK END:\(shadowUID) */
                """
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(block)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(twinBlock)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(shadowBlock)
                fileSystem.setFile(path, content: existing)
                blockSpecs.append((path, uid))
            }
            let fullDecoys = decoys > 0 ? makeSimilarTsDecoys(rng: &rng, around: tsWorkPath) : []
            for decoy in fullDecoys {
                fileSystem.setFile(decoy.path, content: decoy.content)
            }
            let instructions = [
                "Replace the code between /* BLOCK START:UID */ and /* BLOCK END:UID */ markers.",
                "Keep the BLOCK START and BLOCK END comment markers unchanged.",
                "Replace ONLY the function definition and body between these markers.",
                "Do NOT modify blocks with different UIDs - there are decoy blocks present.",
                "Use precise search-replace; do NOT use placeholders."
            ]
            let acceptance = [
                "The function between the specified UID markers exactly matches the provided snippet.",
                "BLOCK START and BLOCK END markers remain unchanged.",
                "All other blocks (with different UIDs) remain identical to baseline.",
                "No code outside any block markers was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]
            var params: [String: BenchmarkJSONValue] = [
                "blocks": .array(blockSpecs.map {
                    .object([
                        "path": .string($0.path),
                        "uid": .string($0.uid),
                        "snippet": .string(snippet)
                    ])
                }),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !fullDecoys.isEmpty {
                params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "patch_block_ts",
                    type: .patchBlockTs,
                    language: .ts,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(2, files.count * 2),
                    instructions: instructions,
                    task: "Replace the body of the tagged block in each file.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "patch_block_ts",
                type: .patchBlockTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(2, files.count * 2),
                instructions: instructions,
                task: "Replace the body of the tagged block in each file.",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - patch_block_go

    private func generatePatchBlockGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [goWorkPath]
        case .hard:
            [goWorkPath, "src/go/work/WorkA.go"]
        case .veryHard:
            [goWorkPath, "src/go/work/WorkA.go", "src/go/work/WorkB.go"]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        _ = noise
        let snippet = """
        func block2(n int) int {
            squared := n * n
            return squared
        }
        """
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        let functionName = "block2"

        if isMarkerless {
            // Markerless mode: create ambiguous neighbor functions
            for path in files {
                var existing = fileSystem.content(for: path) ?? ""
                if existing.isEmpty {
                    existing.append("package work\n\n")
                } else if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                let targetBlock = """
                func block2(n int) int {
                    return n * 2
                }
                """
                let neighborBlock1 = """
                func block2Alt(n int) int {
                    return n * 2
                }
                """
                let neighborBlock2 = """
                func block2Helper(n int) int {
                    // helper function
                    return n * 2
                }
                """
                existing.append(targetBlock)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(neighborBlock1)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(neighborBlock2)
                fileSystem.setFile(path, content: existing)
            }

            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "BlockShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "BlockClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }

            let instructions = [
                "Locate the function named '\(functionName)' in each file.",
                "Replace its entire body with the provided snippet.",
                "Your <search> block must include: the function signature line, at least one line from the body, and the closing brace (3-8 lines total).",
                "Use 4 spaces for indentation (NOT tabs).",
                "Do NOT modify other functions or code outside '\(functionName)'.",
                "Use precise search-replace; do NOT use placeholders."
            ]
            let acceptance = [
                "The function '\(functionName)' body exactly matches the provided snippet in each file.",
                "Other functions (block2Alt, block2Helper, etc.) remain unchanged.",
                "No code outside '\(functionName)' was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]

            var params: [String: BenchmarkJSONValue] = [
                "functionName": .string(functionName),
                "snippet": .string(snippet),
                "markerless": .boolean(true),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "patch_block_go",
                    type: .patchBlockGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(2, files.count * 2),
                    instructions: instructions,
                    task: "Replace the body of function '\(functionName)' in each file with the provided snippet.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "patch_block_go",
                type: .patchBlockGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(2, files.count * 2),
                instructions: instructions,
                task: "Replace the body of function '\(functionName)' in each file with the provided snippet.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Marker-based mode (Medium and below)
            var blockSpecs: [(path: String, uid: String)] = []
            for path in files {
                let uid = randomIdentifier(rng: &rng)
                var existing = fileSystem.content(for: path) ?? ""
                if existing.isEmpty {
                    existing.append("package work\n\n")
                } else if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                let block = """
                /* BLOCK START:\(uid) */
                func block2(n int) int {
                    return n * 2
                }
                /* BLOCK END:\(uid) */
                """
                let twinUID = randomIdentifier(rng: &rng)
                let twinBlock = """
                /* BLOCK START:\(twinUID) */
                func block2(n int) int {
                    // secondary block
                    return n * 2
                }
                /* BLOCK END:\(twinUID) */
                """
                let shadowUID = randomIdentifier(rng: &rng)
                let shadowBlock = """
                /* BLOCK START:\(shadowUID) */
                func block2(n int) int {

                    return n * 2
                }
                /* BLOCK END:\(shadowUID) */
                """
                existing.append(block)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(twinBlock)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(shadowBlock)
                fileSystem.setFile(path, content: existing)
                blockSpecs.append((path, uid))
            }
            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "BlockShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "BlockClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            let instructions = [
                "Replace the code between /* BLOCK START:UID */ and /* BLOCK END:UID */ markers.",
                "Keep the BLOCK START and BLOCK END comment markers unchanged.",
                "Replace ONLY the function definition and body between these markers.",
                "Do NOT modify blocks with different UIDs - there are decoy blocks present.",
                "Use precise search-replace; do NOT use placeholders."
            ]
            let acceptance = [
                "The function between the specified UID markers exactly matches the provided snippet.",
                "BLOCK START and BLOCK END markers remain unchanged.",
                "All other blocks (with different UIDs) remain identical to baseline.",
                "No code outside any block markers was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]
            var params: [String: BenchmarkJSONValue] = [
                "blocks": .array(blockSpecs.map {
                    .object([
                        "path": .string($0.path),
                        "uid": .string($0.uid),
                        "snippet": .string(snippet)
                    ])
                }),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "patch_block_go",
                    type: .patchBlockGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(2, files.count * 2),
                    instructions: instructions,
                    task: "Replace the body of the tagged block in each file.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "patch_block_go",
                type: .patchBlockGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(2, files.count * 2),
                instructions: instructions,
                task: "Replace the body of the tagged block in each file.",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - patch_block_swift

    private func generatePatchBlockSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [swiftWorkPath]
        case .hard:
            [swiftWorkPath, "src/swift/work/WorkA.swift"]
        case .veryHard:
            [swiftWorkPath, "src/swift/work/WorkA.swift", "src/swift/work/WorkB.swift"]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        _ = noise
        let snippet = """
        public func block2(_ n: Int) -> Int {
        	let squared = n * n
        	return squared
        }
        """
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        let functionName = "block2"

        if isMarkerless {
            // Markerless mode: create ambiguous neighbor functions
            for path in files {
                var existing = fileSystem.content(for: path) ?? ""
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                let targetBlock = """
                public func block2(_ n: Int) -> Int {
                	return n * 2
                }
                """
                let neighborBlock1 = """
                public func block2Alt(_ n: Int) -> Int {
                	return n * 2
                }
                """
                let neighborBlock2 = """
                public func block2Helper(_ n: Int) -> Int {
                	// helper function
                	return n * 2
                }
                """
                existing.append(targetBlock)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(neighborBlock1)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(neighborBlock2)
                fileSystem.setFile(path, content: existing)
            }

            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "BlockShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "BlockClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }

            let instructions = [
                "Locate the function named '\(functionName)' in each file.",
                "Replace its entire body with the provided snippet.",
                "Your <search> block must include: the function signature line, at least one line from the body, and the closing brace (3-8 lines total).",
                "Use tabs for indentation (NOT spaces).",
                "Do NOT modify other functions or code outside '\(functionName)'.",
                "Use precise search-replace; do NOT use placeholders."
            ]
            let acceptance = [
                "The function '\(functionName)' body exactly matches the provided snippet in each file.",
                "Other functions (block2Alt, block2Helper, etc.) remain unchanged.",
                "No code outside '\(functionName)' was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]

            var params: [String: BenchmarkJSONValue] = [
                "functionName": .string(functionName),
                "snippet": .string(snippet),
                "markerless": .boolean(true),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "patch_block_swift",
                    type: .patchBlockSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(2, files.count * 2),
                    instructions: instructions,
                    task: "Replace the body of function '\(functionName)' in each file with the provided snippet.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "patch_block_swift",
                type: .patchBlockSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(2, files.count * 2),
                instructions: instructions,
                task: "Replace the body of function '\(functionName)' in each file with the provided snippet.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Marker-based mode (Medium and below)
            var blockSpecs: [(path: String, uid: String)] = []
            for path in files {
                let uid = randomIdentifier(rng: &rng)
                var existing = fileSystem.content(for: path) ?? ""
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                let block = """
                /* BLOCK START:\(uid) */
                public func block2(_ n: Int) -> Int {
                	return n * 2
                }
                /* BLOCK END:\(uid) */
                """
                let twinUID = randomIdentifier(rng: &rng)
                let twinBlock = """
                /* BLOCK START:\(twinUID) */
                public func block2(_ n: Int) -> Int {
                	// secondary block
                	return n * 2
                }
                /* BLOCK END:\(twinUID) */
                """
                let shadowUID = randomIdentifier(rng: &rng)
                let shadowBlock = """
                /* BLOCK START:\(shadowUID) */
                public func block2(_ n: Int) -> Int {

                	return n * 2
                }
                /* BLOCK END:\(shadowUID) */
                """
                existing.append(block)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(twinBlock)
                if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(shadowBlock)
                fileSystem.setFile(path, content: existing)
                blockSpecs.append((path, uid))
            }
            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "BlockShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "BlockClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            let instructions = [
                "Replace the code between /* BLOCK START:UID */ and /* BLOCK END:UID */ markers.",
                "Keep the BLOCK START and BLOCK END comment markers unchanged.",
                "Replace ONLY the function definition and body between these markers.",
                "Do NOT modify blocks with different UIDs - there are decoy blocks present.",
                "Use precise search-replace; do NOT use placeholders."
            ]
            let acceptance = [
                "The function between the specified UID markers exactly matches the provided snippet.",
                "BLOCK START and BLOCK END markers remain unchanged.",
                "All other blocks (with different UIDs) remain identical to baseline.",
                "No code outside any block markers was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]
            var params: [String: BenchmarkJSONValue] = [
                "blocks": .array(blockSpecs.map {
                    .object([
                        "path": .string($0.path),
                        "uid": .string($0.uid),
                        "snippet": .string(snippet)
                    ])
                }),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "patch_block_swift",
                    type: .patchBlockSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(2, files.count * 2),
                    instructions: instructions,
                    task: "Replace the body of the tagged block in each file.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "patch_block_swift",
                type: .patchBlockSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(2, files.count * 2),
                instructions: instructions,
                task: "Replace the body of the tagged block in each file.",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - swap_args_in_region_ts

    private func generateSwapArgsTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium:
            [tsWorkPath]
        case .hard:
            [tsWorkPath, "src/ts/work/WorkA.ts"]
        case .veryHard:
            [tsWorkPath, "src/ts/work/WorkA.ts", "src/ts/work/WorkB.ts", "src/ts/work/WorkC.ts"]
        case .simple:
            [tsWorkPath]
        }
        let helpers = BelievableCodeFactory.tsUtilityModule(rng: &rng, module: "RegionHelpers", approxLines: max(40, scaledLines(40, difficulty: .hard)))
        fileSystem.setFile("src/ts/regions/helpers.ts", content: helpers)
        let decoys = decoyCount(for: difficulty, config: config)
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        let functionName = "render"

        if isMarkerless {
            // Markerless mode: create ambiguous neighbor functions
            let expected = switch difficulty {
            case .hard:
                4
            case .veryHard:
                8
            default:
                4
            }

            for path in files {
                var existing = fileSystem.content(for: path) ?? ""
                if !existing.contains("import { use }") {
                    existing.append("import { use } from './hooks';\n\n")
                }

                let targetBlock = """
                export function render(list: string[]): string {
                    let output = '';
                """
                var targetLines = [String]()
                for idx in 0 ..< expected {
                    targetLines.append("    output += use('a\(idx)', 'b\(idx)');")
                }
                targetLines.append("    return output;")
                targetLines.append("}")

                let neighborBlock1 = """
                export function renderAlt(list: string[]): string {
                    let output = '';
                    output += use('x0', 'y0');
                    output += use('x1', 'y1');
                    return output;
                }
                """
                let neighborBlock2 = """
                export function renderHelper(list: string[]): string {
                    // helper function
                    let output = '';
                    output += use('p0', 'q0');
                    return output;
                }
                """
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(targetBlock)
                existing.append("\n")
                existing.append(targetLines.joined(separator: "\n"))
                existing.append("\n")
                existing.append(neighborBlock1)
                existing.append("\n")
                existing.append(neighborBlock2)
                fileSystem.setFile(path, content: existing)
            }

            let fullDecoys = decoys > 0 ? makeSimilarTsDecoys(rng: &rng, around: tsWorkPath) : []
            for decoy in fullDecoys {
                fileSystem.setFile(decoy.path, content: decoy.content)
            }

            let instructions = [
                "Locate the function named '\(functionName)' in each file.",
                "Swap all use(a, b) calls to use(b, a) within this function.",
                "Your <search> block must include: at least one unchanged line before the first use() call, all use() calls, and at least one unchanged line after (3-8 lines total).",
                "Use 4 spaces for indentation (NOT tabs).",
                "Do NOT modify other functions or code outside '\(functionName)'.",
                "Use precise search-replace; do NOT use placeholders."
            ]

            let acceptance = [
                "All use() calls in function '\(functionName)' have swapped arguments: use(b, a).",
                "Other functions (renderAlt, renderHelper, etc.) remain unchanged.",
                "No code outside '\(functionName)' was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]

            var params: [String: BenchmarkJSONValue] = [
                "functionName": .string(functionName),
                "expectedSwaps": .integer(expected),
                "markerless": .boolean(true),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !fullDecoys.isEmpty {
                params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "swap_args_in_region_ts",
                    type: .swapArgsInRegionTs,
                    language: .ts,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(1, expected * files.count),
                    instructions: instructions,
                    task: "Swap use(a, b) -> use(b, a) in function '\(functionName)' across multiple files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "swap_args_in_region_ts",
                type: .swapArgsInRegionTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, expected * files.count),
                instructions: instructions,
                task: "Swap use(a, b) -> use(b, a) in function '\(functionName)' across multiple files.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Marker-based mode (Medium and below)
            var regionSpecs: [(path: String, uid: String, expected: Int)] = []
            for (index, path) in files.enumerated() {
                let uid = randomIdentifier(rng: &rng)
                let decoyUID = randomIdentifier(rng: &rng)
                let shadowUID = randomIdentifier(rng: &rng)
                let expected: Int = {
                    switch difficulty {
                    case .medium, .simple:
                        return 4
                    case .hard:
                        return 8
                    case .veryHard:
                        let base = index == 0 ? 8 : 4
                        return base + (index == files.count - 1 ? 4 : 0)
                    }
                }()
                var existing = fileSystem.content(for: path) ?? ""
                var block: [String] = []
                if index == 0, !existing.contains("import { use }") {
                    block.append("import { use } from './hooks';")
                    block.append("")
                }
                block.append("export function render(list: string[]): string {")
                block.append("    let output = '';")
                block.append("    /* START_SWAP:\(uid) */")
                for idx in 0 ..< expected {
                    block.append("    output += use('a\(idx)', 'b\(idx)');")
                }
                block.append("    /* END_SWAP:\(uid) */")
                block.append("    // alternate region")
                block.append("    /* START_SWAP:\(decoyUID) */")
                for idx in 0 ..< 2 {
                    block.append("    output += use('a\(idx)', 'b\(idx)');")
                }
                block.append("    /* END_SWAP:\(decoyUID) */")
                block.append("    /* START_SWAP:\(shadowUID) */")
                block.append("    // additional region")
                for idx in 0 ..< 2 {
                    block.append("    output += use('a\(idx)', 'b\(idx)');")
                }
                block.append("    /* END_SWAP:\(shadowUID) */")
                block.append("    output += use('outsideA', 'outsideB');")
                block.append("    output += use('outsideC', 'outsideD');")
                block.append("    output += use('outsideE', 'outsideF');")
                block.append("    output += use('outsideG', 'outsideH');")
                block.append("    return output;")
                block.append("}")
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                existing.append(block.joined(separator: "\n"))
                fileSystem.setFile(path, content: existing)
                regionSpecs.append((path, uid, expected))
            }
            let fullDecoys = decoys > 0 ? makeSimilarTsDecoys(rng: &rng, around: tsWorkPath) : []
            for decoy in fullDecoys {
                fileSystem.setFile(decoy.path, content: decoy.content)
            }
            let instructions = [
                "Within each START_SWAP/END_SWAP region with the specified UID, swap all use(a, b) calls to use(b, a).",
                "Example: use('a0', 'b0') becomes use('b0', 'a0').",
                "Do NOT modify use() calls outside any swap region.",
                "Do NOT modify swap regions with different UIDs - there are decoy regions present.",
                "Do NOT rewrite the entire function - only modify the argument order in targeted calls."
            ]
            let acceptance = [
                "Every use() call inside the specified UID region has swapped arguments: use(b, a).",
                "No use() calls outside any swap region were modified.",
                "All use() calls outside swap regions still use the original (a, b) order.",
                "The number of use() calls inside the region remains unchanged.",
                "Exactly \(files.count) file(s) were modified."
            ]
            let totalSwaps = regionSpecs.reduce(0) { $0 + $1.expected }
            var params: [String: BenchmarkJSONValue] = [
                "regions": .array(regionSpecs.map {
                    .object([
                        "path": .string($0.path),
                        "uid": .string($0.uid),
                        "expectedSwaps": .integer($0.expected)
                    ])
                }),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !fullDecoys.isEmpty {
                params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "swap_args_in_region_ts",
                    type: .swapArgsInRegionTs,
                    language: .ts,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(1, totalSwaps),
                    instructions: instructions,
                    task: "Swap use(a, b) -> use(b, a) within the marked regions across multiple files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "swap_args_in_region_ts",
                type: .swapArgsInRegionTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, totalSwaps),
                instructions: instructions,
                task: "Swap use(a, b) -> use(b, a) within the marked regions across multiple files.",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - swap_args_in_region_go

    private func generateSwapArgsGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [goWorkPath]
        case .hard:
            [goWorkPath, "src/go/work/WorkA.go"]
        case .veryHard:
            [goWorkPath, "src/go/work/WorkA.go", "src/go/work/WorkB.go", "src/go/work/WorkC.go"]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        _ = noise
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        let functionName = "Render"

        if isMarkerless {
            // Markerless mode: create ambiguous neighbor functions
            let expected = switch difficulty {
            case .hard:
                4
            case .veryHard:
                8
            default:
                4
            }

            for path in files {
                var existing = fileSystem.content(for: path) ?? ""
                let needsPrelude = existing.isEmpty
                if needsPrelude {
                    existing.append("package work\n\n")
                    existing.append("func use(a, b string) string { return a + b }\n\n")
                } else if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }

                let targetBlock = """
                func Render(list []string) string {
                    out := ""
                """
                var targetLines = [String]()
                for idx in 0 ..< expected {
                    targetLines.append("    out += use(\"a\(idx)\", \"b\(idx)\")")
                }
                targetLines.append("    return out")
                targetLines.append("}")

                let neighborBlock1 = """
                func RenderAlt(list []string) string {
                    out := ""
                    out += use("x0", "y0")
                    out += use("x1", "y1")
                    return out
                }
                """
                let neighborBlock2 = """
                func RenderHelper(list []string) string {
                    // helper function
                    out := ""
                    out += use("p0", "q0")
                    return out
                }
                """
                existing.append(targetBlock)
                existing.append("\n")
                existing.append(targetLines.joined(separator: "\n"))
                existing.append("\n")
                existing.append(neighborBlock1)
                existing.append("\n")
                existing.append(neighborBlock2)
                fileSystem.setFile(path, content: existing)
            }

            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "SwapShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "SwapClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }

            let instructions = [
                "Locate the function named '\(functionName)' in each file.",
                "Swap all use(a, b) calls to use(b, a) within this function.",
                "Your <search> block must include: at least one unchanged line before the first use() call, all use() calls, and at least one unchanged line after (3-8 lines total).",
                "Use 4 spaces for indentation (NOT tabs).",
                "Do NOT modify other functions or code outside '\(functionName)'.",
                "Use precise search-replace; do NOT use placeholders."
            ]

            let acceptance = [
                "All use() calls in function '\(functionName)' have swapped arguments: use(b, a).",
                "Other functions (RenderAlt, RenderHelper, etc.) remain unchanged.",
                "No code outside '\(functionName)' was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]

            var params: [String: BenchmarkJSONValue] = [
                "functionName": .string(functionName),
                "expectedSwaps": .integer(expected),
                "markerless": .boolean(true),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "swap_args_go",
                    type: .swapArgsInRegionGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(1, expected * files.count),
                    instructions: instructions,
                    task: "Swap use(a, b) -> use(b, a) in function '\(functionName)' across multiple files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "swap_args_go",
                type: .swapArgsInRegionGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, expected * files.count),
                instructions: instructions,
                task: "Swap use(a, b) -> use(b, a) in function '\(functionName)' across multiple files.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Marker-based mode (Medium and below)
            var regionSpecs: [(path: String, uid: String, expected: Int)] = []
            for (index, path) in files.enumerated() {
                let uid = randomIdentifier(rng: &rng)
                let decoyUID = randomIdentifier(rng: &rng)
                let shadowUID = randomIdentifier(rng: &rng)
                let expected: Int = {
                    switch difficulty {
                    case .medium, .simple:
                        return 4
                    case .hard:
                        return 8
                    case .veryHard:
                        let base = index == 0 ? 8 : 4
                        return base + (index == files.count - 1 ? 4 : 0)
                    }
                }()
                var existing = fileSystem.content(for: path) ?? ""
                var lines: [String] = []
                let needsPrelude = existing.isEmpty
                if needsPrelude {
                    lines.append("package work")
                    lines.append("")
                    lines.append("func use(a, b string) string { return a + b }")
                    lines.append("")
                } else if !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                lines.append("func Render(list []string) string {")
                lines.append("    out := \"\"")
                lines.append("    /* START_SWAP:\(uid) */")
                for idx in 0 ..< expected {
                    lines.append("    out += use(\"a\(idx)\", \"b\(idx)\")")
                }
                lines.append("    /* END_SWAP:\(uid) */")
                lines.append("    // alternate region")
                lines.append("    /* START_SWAP:\(decoyUID) */")
                for idx in 0 ..< 2 {
                    lines.append("    out += use(\"a\(idx)\", \"b\(idx)\")")
                }
                lines.append("    /* END_SWAP:\(decoyUID) */")
                lines.append("    /* START_SWAP:\(shadowUID) */")
                lines.append("    // additional region")
                for idx in 0 ..< 2 {
                    lines.append("    out += use(\"a\(idx)\", \"b\(idx)\")")
                }
                lines.append("    /* END_SWAP:\(shadowUID) */")
                lines.append("    out += use(\"outsideA\", \"outsideB\")")
                lines.append("    out += use(\"outsideC\", \"outsideD\")")
                lines.append("    out += use(\"outsideE\", \"outsideF\")")
                lines.append("    out += use(\"outsideG\", \"outsideH\")")
                lines.append("    return out")
                lines.append("}")
                if needsPrelude {
                    existing = lines.joined(separator: "\n")
                } else {
                    existing.append(lines.joined(separator: "\n"))
                }
                fileSystem.setFile(path, content: existing)
                regionSpecs.append((path, uid, expected))
            }
            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "SwapShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "SwapClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            let instructions = [
                "Within each START_SWAP/END_SWAP region with the specified UID, swap all use(a, b) calls to use(b, a).",
                "Example: use(\"a0\", \"b0\") becomes use(\"b0\", \"a0\").",
                "Do NOT modify use() calls outside any swap region.",
                "Do NOT modify swap regions with different UIDs - there are decoy regions present.",
                "Do NOT rewrite the entire function - only modify the argument order in targeted calls."
            ]
            let acceptance = [
                "Every use() call inside the specified UID region has swapped arguments: use(b, a).",
                "No use() calls outside any swap region were modified.",
                "All use() calls outside swap regions still use the original (a, b) order.",
                "The number of use() calls inside the region remains unchanged.",
                "Exactly \(files.count) file(s) were modified."
            ]
            let totalSwaps = regionSpecs.reduce(0) { $0 + $1.expected }
            var params: [String: BenchmarkJSONValue] = [
                "regions": .array(regionSpecs.map {
                    .object([
                        "path": .string($0.path),
                        "uid": .string($0.uid),
                        "expectedSwaps": .integer($0.expected)
                    ])
                }),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "swap_args_go",
                    type: .swapArgsInRegionGo,
                    language: .go,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(1, totalSwaps),
                    instructions: instructions,
                    task: "Swap use(a, b) -> use(b, a) within the marked regions across multiple files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "swap_args_go",
                type: .swapArgsInRegionGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, totalSwaps),
                instructions: instructions,
                task: "Swap use(a, b) -> use(b, a) within the marked regions across multiple files.",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - swap_args_in_region_swift

    private func generateSwapArgsSwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        noise: BenchmarkNoiseConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let files: [String] = switch difficulty {
        case .medium, .simple:
            [swiftWorkPath]
        case .hard:
            [swiftWorkPath, "src/swift/work/WorkA.swift"]
        case .veryHard:
            [swiftWorkPath, "src/swift/work/WorkA.swift", "src/swift/work/WorkB.swift", "src/swift/work/WorkC.swift"]
        }
        let decoys = decoyCount(for: difficulty, config: config)
        _ = noise
        let isMarkerless = shouldUseMarkerlessMode(for: difficulty)
        let functionName = "render"

        if isMarkerless {
            // Markerless mode: create ambiguous neighbor functions
            let expected = switch difficulty {
            case .hard:
                4
            case .veryHard:
                8
            default:
                4
            }

            for path in files {
                var existing = fileSystem.content(for: path) ?? ""
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                if !existing.contains("func use(") {
                    existing.append("func use(_ a: String, _ b: String) -> String { a + b }\n\n")
                }

                let targetBlock = """
                func render(_ list: [String]) -> String {
                \tvar output = ""
                """
                var targetLines = [String]()
                for idx in 0 ..< expected {
                    targetLines.append("\toutput += use(\"a\(idx)\", \"b\(idx)\")")
                }
                targetLines.append("\treturn output")
                targetLines.append("}")

                let neighborBlock1 = """
                func renderAlt(_ list: [String]) -> String {
                \tvar output = ""
                \toutput += use("x0", "y0")
                \toutput += use("x1", "y1")
                \treturn output
                }
                """
                let neighborBlock2 = """
                func renderHelper(_ list: [String]) -> String {
                \t// helper function
                \tvar output = ""
                \toutput += use("p0", "q0")
                \treturn output
                }
                """
                existing.append(targetBlock)
                existing.append("\n")
                existing.append(targetLines.joined(separator: "\n"))
                existing.append("\n")
                existing.append(neighborBlock1)
                existing.append("\n")
                existing.append(neighborBlock2)
                fileSystem.setFile(path, content: existing)
            }

            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "SwapShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "SwapClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }

            let instructions = [
                "Locate the function named '\(functionName)' in each file.",
                "Swap all use(a, b) calls to use(b, a) within this function.",
                "Your <search> block must include: at least one unchanged line before the first use() call, all use() calls, and at least one unchanged line after (3-8 lines total).",
                "Use tabs for indentation (NOT spaces).",
                "Do NOT modify other functions or code outside '\(functionName)'.",
                "Use precise search-replace; do NOT use placeholders."
            ]

            let acceptance = [
                "All use() calls in function '\(functionName)' have swapped arguments: use(b, a).",
                "Other functions (renderAlt, renderHelper, etc.) remain unchanged.",
                "No code outside '\(functionName)' was modified.",
                "Exactly \(files.count) file(s) were modified."
            ]

            var params: [String: BenchmarkJSONValue] = [
                "functionName": .string(functionName),
                "expectedSwaps": .integer(expected),
                "markerless": .boolean(true),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "swap_args_in_region_swift",
                    type: .swapArgsInRegionSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(1, expected * files.count),
                    instructions: instructions,
                    task: "Swap use(a, b) -> use(b, a) in function '\(functionName)' across multiple files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "swap_args_in_region_swift",
                type: .swapArgsInRegionSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, expected * files.count),
                instructions: instructions,
                task: "Swap use(a, b) -> use(b, a) in function '\(functionName)' across multiple files.",
                acceptance: acceptance,
                params: params
            )
        } else {
            // Marker-based mode (Medium and below)
            var regionSpecs: [(path: String, uid: String, expected: Int)] = []
            for (index, path) in files.enumerated() {
                let uid = randomIdentifier(rng: &rng)
                let decoyUID = randomIdentifier(rng: &rng)
                let shadowUID = randomIdentifier(rng: &rng)
                let expected: Int = {
                    switch difficulty {
                    case .medium, .simple:
                        return 4
                    case .hard:
                        return 8
                    case .veryHard:
                        let base = index == 0 ? 8 : 4
                        return base + (index == files.count - 1 ? 4 : 0)
                    }
                }()
                var existing = fileSystem.content(for: path) ?? ""
                var lines: [String] = []
                if !existing.isEmpty, !existing.hasSuffix("\n") {
                    existing.append("\n")
                }
                if !existing.contains("func use(") {
                    lines.append("func use(_ a: String, _ b: String) -> String { a + b }")
                    lines.append("")
                }
                lines.append("func render(_ list: [String]) -> String {")
                lines.append("\tvar output = \"\"")
                lines.append("\t/* START_SWAP:\(uid) */")
                for idx in 0 ..< expected {
                    lines.append("\toutput += use(\"a\(idx)\", \"b\(idx)\")")
                }
                lines.append("\t/* END_SWAP:\(uid) */")
                lines.append("\t// alternate region")
                lines.append("\t/* START_SWAP:\(decoyUID) */")
                for idx in 0 ..< 2 {
                    lines.append("\toutput += use(\"a\(idx)\", \"b\(idx)\")")
                }
                lines.append("\t/* END_SWAP:\(decoyUID) */")
                lines.append("\t/* START_SWAP:\(shadowUID) */")
                lines.append("\t// additional region")
                for idx in 0 ..< 2 {
                    lines.append("\toutput += use(\"a\(idx)\", \"b\(idx)\")")
                }
                lines.append("\t/* END_SWAP:\(shadowUID) */")
                lines.append("\toutput += use(\"outsideA\", \"outsideB\")")
                lines.append("\toutput += use(\"outsideC\", \"outsideD\")")
                lines.append("\toutput += use(\"outsideE\", \"outsideF\")")
                lines.append("\toutput += use(\"outsideG\", \"outsideH\")")
                lines.append("\treturn output")
                lines.append("}")
                existing.append(lines.joined(separator: "\n"))
                fileSystem.setFile(path, content: existing)
                regionSpecs.append((path, uid, expected))
            }
            var decoyPaths: [String] = []
            if decoys >= 1 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "SwapShadow")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            if decoys >= 2 {
                let decoy = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "SwapClone")
                fileSystem.setFile(decoy.path, content: decoy.content)
                decoyPaths.append(decoy.path)
            }
            let instructions = [
                "Within each START_SWAP/END_SWAP region with the specified UID, swap all use(a, b) calls to use(b, a).",
                "Example: use(\"a0\", \"b0\") becomes use(\"b0\", \"a0\").",
                "Do NOT modify use() calls outside any swap region.",
                "Do NOT modify swap regions with different UIDs - there are decoy regions present.",
                "Do NOT rewrite the entire function - only modify the argument order in targeted calls."
            ]
            let acceptance = [
                "Every use() call inside the specified UID region has swapped arguments: use(b, a).",
                "No use() calls outside any swap region were modified.",
                "All use() calls outside swap regions still use the original (a, b) order.",
                "The number of use() calls inside the region remains unchanged.",
                "Exactly \(files.count) file(s) were modified."
            ]
            let totalSwaps = regionSpecs.reduce(0) { $0 + $1.expected }
            var params: [String: BenchmarkJSONValue] = [
                "regions": .array(regionSpecs.map {
                    .object([
                        "path": .string($0.path),
                        "uid": .string($0.uid),
                        "expectedSwaps": .integer($0.expected)
                    ])
                }),
                "difficulty": .string(difficulty.rawValue),
                "maxDecoys": .integer(decoys)
            ]
            if !decoyPaths.isEmpty {
                params["fullDecoys"] = .array(decoyPaths.map { .string($0) })
            }

            if config.includeAutoPlannedDecoys {
                let draftTask = BenchmarkTaskSpec(
                    id: "swap_args_in_region_swift",
                    type: .swapArgsInRegionSwift,
                    language: .swift,
                    difficulty: difficulty,
                    selectFiles: files,
                    maxEdits: max(1, totalSwaps),
                    instructions: instructions,
                    task: "Swap use(a, b) -> use(b, a) within the marked regions across multiple files.",
                    acceptance: acceptance,
                    params: params
                )
                let baselineSnapshot = fileSystem.snapshot()
                let decoySpecs = DecoyPlanner.materialize(
                    for: draftTask,
                    on: &fileSystem,
                    baseline: baselineSnapshot,
                    policy: config.decoyPolicy
                )
                if !decoySpecs.isEmpty {
                    params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
                }
            }
            params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

            return BenchmarkTaskSpec(
                id: "swap_args_in_region_swift",
                type: .swapArgsInRegionSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: files,
                maxEdits: max(1, totalSwaps),
                instructions: instructions,
                task: "Swap use(a, b) -> use(b, a) within the marked regions across multiple files.",
                acceptance: acceptance,
                params: params
            )
        }
    }

    // MARK: - index_only_apps_ts

    private func generateIndexOnlyTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let apps = ["appA", "appB", "appC"]
        let packages: [String] = switch difficulty {
        case .simple:
            ["pkg1", "pkg2"]
        case .medium:
            ["pkg1", "pkg2", "pkg3", "pkg4"]
        case .hard:
            ["pkg1", "pkg2", "pkg3", "pkg4", "pkg5", "pkg6"]
        case .veryHard:
            ["pkg1", "pkg2", "pkg3", "pkg4", "pkg5", "pkg6", "pkg7", "pkg8"]
        }
        for app in apps {
            let path = "apps/\(app)/src/index.ts"
            let content = "export default function index() {\n    return \"\(app)\";\n}"
            fileSystem.setFile(path, content: content)
        }
        for pkg in packages {
            let path = "packages/\(pkg)/src/index.ts"
            let content = "export const value = \"\(pkg)\";"
            fileSystem.setFile(path, content: content)
        }
        let targetApp = "appB"
        let targetPath = "apps/\(targetApp)/src/index.ts"
        let instructions = [
            "Modify ONLY the file apps/\(targetApp)/src/index.ts (no other files).",
            "Add the comment // DONE:\(targetApp) immediately after the return statement in that file.",
            "Do NOT modify any other index.ts files in apps/ or packages/ directories.",
            "The marker must be added as a new line after the return statement, before the closing brace."
        ]
        let acceptance = [
            "apps/\(targetApp)/src/index.ts contains exactly one line with // DONE:\(targetApp).",
            "The DONE marker appears on the line immediately following the return statement.",
            "The function still returns \"\(targetApp)\" unchanged.",
            "No other index.ts files were modified (no DONE markers, no changed return values).",
            "Total edit count is exactly 1 file modified."
        ]
        var selectFiles = [targetPath]
        selectFiles.append(contentsOf: apps.filter { $0 != targetApp }.map { "apps/\($0)/src/index.ts" })
        selectFiles.append(contentsOf: packages.map { "packages/\($0)/src/index.ts" })

        var params: [String: BenchmarkJSONValue] = [
            "target": .string(targetApp),
            "otherPaths": .array(selectFiles.filter { $0 != targetPath }.map { .string($0) }),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyCount(for: difficulty, config: config))
        ]

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "index_only_apps_ts",
                type: .indexOnlyAppsTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: selectFiles,
                maxEdits: 2,
                instructions: instructions,
                task: "Modify only \(targetPath) to mark completion for \(targetApp).",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "index_only_apps_ts",
            type: .indexOnlyAppsTs,
            language: .ts,
            difficulty: difficulty,
            selectFiles: selectFiles,
            maxEdits: 2,
            instructions: instructions,
            task: "Modify only \(targetPath) to mark completion for \(targetApp).",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - index_only_apps_go

    private func generateIndexOnlyGoTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = rng
        _ = config
        // Scale apps by difficulty: S/M=3, H=6, VH=8
        let apps: [String] = switch difficulty {
        case .simple, .medium:
            ["appA", "appB", "appC"]
        case .hard:
            ["appA", "appB", "appC", "appD", "appE", "appF"]
        case .veryHard:
            ["appA", "appB", "appC", "appD", "appE", "appF", "appG", "appH"]
        }
        let packages: [String] = switch difficulty {
        case .simple:
            ["pkg1", "pkg2"]
        case .medium:
            ["pkg1", "pkg2", "pkg3", "pkg4"]
        case .hard:
            ["pkg1", "pkg2", "pkg3", "pkg4", "pkg5", "pkg6"]
        case .veryHard:
            ["pkg1", "pkg2", "pkg3", "pkg4", "pkg5", "pkg6", "pkg7", "pkg8"]
        }
        // Create all app index files
        for app in apps {
            let path = "apps/\(app)/main.go"
            let content = "package main\n\nfunc index() string {\n    return \"\(app)\"\n}\n"
            fileSystem.setFile(path, content: content)
        }
        // Create all package index files
        for pkg in packages {
            let path = "packages/\(pkg)/main.go"
            let content = "package \(pkg)\n\nfunc value() string { return \"\(pkg)\" }\n"
            fileSystem.setFile(path, content: content)
        }
        // Select target by PRIMARY selector (randomized) and write selector file
        let targetIndex = rng.nextInt(upperBound: apps.count)
        let targetApp = apps[targetIndex]
        fileSystem.setFile("apps/PRIMARY", content: "\(targetApp)\n")
        let targetPath = "apps/\(targetApp)/main.go"

        // Build selection set (target + other apps + packages)
        var selectFiles: [String] = []
        selectFiles.append(targetPath)
        selectFiles.append(contentsOf: apps.filter { $0 != targetApp }.map { "apps/\($0)/main.go" })
        selectFiles.append(contentsOf: packages.map { "packages/\($0)/main.go" })

        // Instructions: explicit target for simple/medium; PRIMARY inference for hard/veryHard
        let instructions: [String] = switch difficulty {
        case .simple, .medium:
            [
                "Modify ONLY the file \(targetPath) (no other files).",
                "Add the comment // DONE:\(targetApp) immediately after the return statement in that file.",
                "Do NOT modify any other main.go files in apps/ or packages/ directories.",
                "The marker must be added as a new line after the return statement, before the closing brace."
            ]
        case .hard, .veryHard:
            [
                "Read apps/PRIMARY to identify the primary app to modify.",
                "Modify ONLY that app's index function file (apps/<app>/main.go).",
                "Add the comment // DONE:<app> immediately after the return statement in that file.",
                "Do NOT modify any other main.go files in apps/ or packages/ directories.",
                "The marker must be added as a new line after the return statement, before the closing brace."
            ]
        }

        // Acceptance remains explicit for verification
        let acceptance = [
            "apps/\(targetApp)/main.go contains exactly one line with // DONE:\(targetApp).",
            "The DONE marker appears on the line immediately following the return statement.",
            "The function still returns \"\(targetApp)\" unchanged.",
            "No other main.go files were modified (no DONE markers, no changed return values).",
            "Total edit count is exactly 1 file modified."
        ]

        // Params: include selectorPath for inference mode and otherPaths for unchanged checks
        let otherPathsArray = selectFiles.filter { $0 != targetPath }
        var params: [String: BenchmarkJSONValue] = [
            "target": .string(targetApp),
            "otherPaths": .array(otherPathsArray.map { .string($0) }),
            "difficulty": .string(difficulty.rawValue),
            "selectorPath": .string("apps/PRIMARY")
        ]

        // Task: explicit for S/M; generic for H/VH
        let taskText = switch difficulty {
        case .simple, .medium:
            "Modify only \(targetPath) to mark completion for \(targetApp)."
        case .hard, .veryHard:
            "Identify the primary app from apps/PRIMARY and add the DONE marker to that app's index file only."
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "index_only_apps_go",
                type: .indexOnlyAppsGo,
                language: .go,
                difficulty: difficulty,
                selectFiles: selectFiles,
                maxEdits: 2,
                instructions: instructions,
                task: taskText,
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "index_only_apps_go",
            type: .indexOnlyAppsGo,
            language: .go,
            difficulty: difficulty,
            selectFiles: selectFiles,
            maxEdits: 2,
            instructions: instructions,
            task: taskText,
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - index_only_apps_swift

    private func generateIndexOnlySwiftTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        _ = rng
        _ = config
        // Scale apps by difficulty: S/M=3, H=6, VH=8
        let apps: [String] = switch difficulty {
        case .simple, .medium:
            ["appA", "appB", "appC"]
        case .hard:
            ["appA", "appB", "appC", "appD", "appE", "appF"]
        case .veryHard:
            ["appA", "appB", "appC", "appD", "appE", "appF", "appG", "appH"]
        }
        let packages: [String] = switch difficulty {
        case .simple:
            ["pkg1", "pkg2"]
        case .medium:
            ["pkg1", "pkg2", "pkg3", "pkg4"]
        case .hard:
            ["pkg1", "pkg2", "pkg3", "pkg4", "pkg5", "pkg6"]
        case .veryHard:
            ["pkg1", "pkg2", "pkg3", "pkg4", "pkg5", "pkg6", "pkg7", "pkg8"]
        }
        // Create all app index files
        for app in apps {
            let path = "Apps/\(app)/index.swift"
            let content = "public func index() -> String {\n\treturn \"\(app)\"\n}\n"
            fileSystem.setFile(path, content: content)
        }
        // Create all package index files
        for pkg in packages {
            let path = "Packages/\(pkg)/index.swift"
            let content = "public func value() -> String {\n\treturn \"\(pkg)\"\n}\n"
            fileSystem.setFile(path, content: content)
        }
        // Select target by PRIMARY selector (randomized) and write selector file
        let targetIndex = rng.nextInt(upperBound: apps.count)
        let targetApp = apps[targetIndex]
        fileSystem.setFile("Apps/PRIMARY", content: "\(targetApp)\n")
        let targetPath = "Apps/\(targetApp)/index.swift"

        // Build selection set (target + other apps + packages)
        var selectFiles: [String] = []
        selectFiles.append(targetPath)
        selectFiles.append(contentsOf: apps.filter { $0 != targetApp }.map { "Apps/\($0)/index.swift" })
        selectFiles.append(contentsOf: packages.map { "Packages/\($0)/index.swift" })

        // Instructions: explicit target for simple/medium; PRIMARY inference for hard/veryHard
        let instructions: [String] = switch difficulty {
        case .simple, .medium:
            [
                "Modify ONLY the file \(targetPath) (no other files).",
                "Add the comment // DONE:\(targetApp) immediately after the return statement in that file.",
                "Do NOT modify any other index.swift files in Apps/ or Packages/ directories.",
                "The marker must be added as a new line after the return statement, before the closing brace."
            ]
        case .hard, .veryHard:
            [
                "Read Apps/PRIMARY to identify the primary app to modify.",
                "Modify ONLY that app's index function file (Apps/<app>/index.swift).",
                "Add the comment // DONE:<app> immediately after the return statement in that file.",
                "Do NOT modify any other index.swift files in Apps/ or Packages/ directories.",
                "The marker must be added as a new line after the return statement, before the closing brace."
            ]
        }

        // Acceptance remains explicit for verification
        let acceptance = [
            "\(targetPath) contains exactly one line with // DONE:\(targetApp).",
            "The DONE marker appears on the line immediately following the return statement.",
            "The function still returns \"\(targetApp)\" unchanged.",
            "No other index.swift files were modified (no DONE markers, no changed return values).",
            "Total edit count is exactly 1 file modified."
        ]

        // Params: include selectorPath for inference mode and otherPaths for unchanged checks
        let otherPathsArray = selectFiles.filter { $0 != targetPath }
        var params: [String: BenchmarkJSONValue] = [
            "target": .string(targetApp),
            "otherPaths": .array(otherPathsArray.map { .string($0) }),
            "difficulty": .string(difficulty.rawValue),
            "selectorPath": .string("Apps/PRIMARY")
        ]

        // Task: explicit for S/M; generic for H/VH
        let taskText = switch difficulty {
        case .simple, .medium:
            "Modify only \(targetPath) to mark completion for \(targetApp)."
        case .hard, .veryHard:
            "Identify the primary app from Apps/PRIMARY and add the DONE marker to that app's index file only."
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "index_only_apps_swift",
                type: .indexOnlyAppsSwift,
                language: .swift,
                difficulty: difficulty,
                selectFiles: selectFiles,
                maxEdits: 2,
                instructions: instructions,
                task: taskText,
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "index_only_apps_swift",
            type: .indexOnlyAppsSwift,
            language: .swift,
            difficulty: difficulty,
            selectFiles: selectFiles,
            maxEdits: 2,
            instructions: instructions,
            task: taskText,
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - rename_export_and_imports_ts

    private func generateRenameExportsTask(
        rng: inout Mulberry32,
        fileSystem: inout BenchmarkMockFileSystem,
        config: BenchConfig,
        difficulty: BenchmarkDifficulty,
        layout: BenchmarkProjectLayout
    ) -> BenchmarkTaskSpec {
        let exporterPath = "src/ts/lib/exporter.ts"
        let barrelPath = "src/ts/lib/index.ts"
        let decoyBarrel = "src/ts/lib/decoyIndex.ts"
        let oldName = "OldX"
        let newName = "NewX"
        let exporterContent = """
        export function \(oldName)(): string { return \"value\" }
        export const usage = \(oldName)()

        // near-miss tokens — keep unchanged
        export function \(oldName)Helper(): number { return 1 }
        export const \(oldName)XY = 2
        export type \(oldName)Type = number
        const label = \"\(oldName)\" // string literal allowed to remain \"OldX\"
        """
        fileSystem.setFile(exporterPath, content: exporterContent)
        fileSystem.setFile(barrelPath, content: """
        export { \(oldName) } from \"./exporter\";
        export * as All from \"./exporter\";
        """)
        fileSystem.setFile(decoyBarrel, content: """
        export { \(oldName) } from \"./exporter\";
        """)
        let importerCount = switch difficulty {
        case .simple:
            2
        case .medium:
            4
        case .hard:
            6
        case .veryHard:
            8
        }
        var importers: [String] = []
        enum ImportStyle { case named, alias, namespace }
        func randomStyle(for difficulty: BenchmarkDifficulty, rng: inout Mulberry32) -> ImportStyle {
            switch difficulty {
            case .simple:
                return .named
            case .medium:
                return rng.nextInt(upperBound: 2) == 0 ? .named : .alias
            case .hard, .veryHard:
                let pick = rng.nextInt(upperBound: 3)
                if pick == 0 {
                    return .named
                }
                return pick == 1 ? .alias : .namespace
            }
        }
        for index in 1 ... importerCount {
            let app = index.isMultiple(of: 2) ? "appB" : "appA"
            let path = "apps/\(app)/src/useX_\(index).ts"
            importers.append(path)
            let viaBarrel = index.isMultiple(of: 3)
            let basePath = viaBarrel ? "../../lib" : "../../lib/exporter"
            let style = randomStyle(for: difficulty, rng: &rng)
            let content = switch style {
            case .named:
                """
                import { \(oldName) } from '\(basePath)';

                export function consume() {
                    return \(oldName)();
                }
                """
            case .alias:
                """
                import { \(oldName) as UseX } from '\(basePath)';

                export function consume() {
                    return UseX();
                }
                """
            case .namespace:
                """
                import * as E from '\(basePath)';

                export function consume() {
                    return E.\(oldName)();
                }
                """
            }
            fileSystem.setFile(path, content: content)
        }
        var otherPaths: [String] = []
        let decoyBudget = decoyCount(for: difficulty, config: config)
        let negativeCount = min(decoyBudget, 3)
        if negativeCount > 0 {
            for index in 1 ... negativeCount {
                let path = "apps/appC/src/decoy_useX_\(index).ts"
                let decoy = """
                import { \(oldName) } from '../../lib/exporter';

                export function probe() {
                    // must remain unchanged
                    return \(oldName)();
                }
                """
                fileSystem.setFile(path, content: decoy)
                otherPaths.append(path)
            }
        }
        otherPaths.append(decoyBarrel)
        let instructions = [
            "Rename the exported function \(oldName) to \(newName) in \(exporterPath) and the barrel \(barrelPath).",
            "Update every export and re-export of \(oldName) to \(newName) in these two files.",
            "Update ONLY the listed importer files to use \(newName) (some import via the barrel, some directly).",
            "Importers may use named imports, aliases, or namespace imports - update the imported symbol name.",
            "Do NOT modify near-miss tokens: \(oldName)Helper, \(oldName)XY, \(oldName)Type (different suffixes/contexts).",
            "Do NOT modify string literals containing \"\(oldName)\".",
            "Do NOT edit files not explicitly listed as importers - other files with \(oldName) must remain unchanged."
        ]
        let acceptance = [
            "\(exporterPath) exports function \(newName) with zero remaining exports named \(oldName).",
            "\(barrelPath) re-exports \(newName) with zero remaining references to \(oldName).",
            "Each listed importer uses \(newName) (via import, alias, or namespace) and has zero references to \(oldName).",
            "Near-miss tokens (\(oldName)Helper, \(oldName)XY, \(oldName)Type) remain unchanged in all files.",
            "Files in otherPaths remain byte-for-byte identical to baseline.",
            "Total files modified: 2 exports + \(importers.count) importers."
        ]
        var selectFiles = [exporterPath, barrelPath]
        selectFiles.append(contentsOf: importers)
        let fullDecoys = decoyBudget > 0 ? makeSimilarTsDecoys(rng: &rng, around: tsWorkPath) : []
        for decoy in fullDecoys {
            fileSystem.setFile(decoy.path, content: decoy.content)
        }
        var params: [String: BenchmarkJSONValue] = [
            "rename": .object([
                "from": .string(oldName),
                "to": .string(newName)
            ]),
            "importPaths": .array(importers.map { .string($0) }),
            "otherPaths": .array(otherPaths.map { .string($0) }),
            "nearMissTokens": .array([
                .string("\(oldName)Helper"),
                .string("\(oldName)XY"),
                .string("\(oldName)Type")
            ]),
            "reexportPaths": .array([.string(barrelPath)]),
            "difficulty": .string(difficulty.rawValue),
            "maxDecoys": .integer(decoyBudget)
        ]
        if !fullDecoys.isEmpty {
            params["fullDecoys"] = .array(fullDecoys.map { .string($0.path) })
        }

        if config.includeAutoPlannedDecoys {
            let draftTask = BenchmarkTaskSpec(
                id: "rename_export_and_imports_ts",
                type: .renameExportImportsTs,
                language: .ts,
                difficulty: difficulty,
                selectFiles: selectFiles,
                maxEdits: 10,
                instructions: instructions,
                task: "Rename \(oldName) to \(newName) across exporter.ts and index.ts, updating ONLY the listed importers.",
                acceptance: acceptance,
                params: params
            )
            let baselineSnapshot = fileSystem.snapshot()
            let decoySpecs = DecoyPlanner.materialize(
                for: draftTask,
                on: &fileSystem,
                baseline: baselineSnapshot,
                policy: config.decoyPolicy
            )
            if !decoySpecs.isEmpty {
                params["decoyPaths"] = .array(decoySpecs.map { .string($0.path) })
            }
        }
        params["hintVerbosity"] = .string(config.guidanceVerbosity.rawValue)

        return BenchmarkTaskSpec(
            id: "rename_export_and_imports_ts",
            type: .renameExportImportsTs,
            language: .ts,
            difficulty: difficulty,
            selectFiles: selectFiles,
            maxEdits: 10,
            instructions: instructions,
            task: "Rename \(oldName) to \(newName) across exporter.ts and index.ts, updating ONLY the listed importers.",
            acceptance: acceptance,
            params: params
        )
    }

    // MARK: - Helpers

    private func randomIdentifier(rng: inout Mulberry32, length: Int = 4) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var chars: [Character] = []
        for _ in 0 ..< length {
            let idx = rng.nextInt(upperBound: alphabet.count)
            chars.append(alphabet[idx])
        }
        return String(chars)
    }

    private func scaledLines(_ base: Int, difficulty: BenchmarkDifficulty) -> Int {
        switch difficulty {
        case .medium:
            max(20, Int(Double(base) * 0.35))
        case .hard:
            max(30, Int(Double(base) * 0.6))
        case .veryHard:
            max(40, base)
        case .simple:
            max(20, Int(Double(base) * 0.35))
        }
    }

    private func decoyCount(for difficulty: BenchmarkDifficulty, config: BenchConfig) -> Int {
        switch difficulty {
        case .medium:
            config.decoysMedium
        case .hard:
            config.decoysHard
        case .veryHard:
            config.decoysVeryHard
        case .simple:
            config.decoysMedium
        }
    }

    private func maxEditsRemoveX(for difficulty: BenchmarkDifficulty) -> Int {
        switch difficulty {
        case .medium:
            1
        case .hard:
            3
        case .veryHard:
            6
        case .simple:
            1
        }
    }

    private func difficultyIsAtLeastHard(_ difficulty: BenchmarkDifficulty) -> Bool {
        switch difficulty {
        case .hard, .veryHard:
            true
        default:
            false
        }
    }

    private func shouldUseMarkerlessMode(for difficulty: BenchmarkDifficulty) -> Bool {
        difficulty == .hard || difficulty == .veryHard
    }

    private func defaultFunctionName(for type: BenchmarkCaseType, language: BenchmarkLanguage) -> String {
        switch type {
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
            "clamp"
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
            "block2"
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            "render"
        default:
            "function"
        }
    }

    private func makeSimilarTsDecoys(rng: inout Mulberry32, around path: String) -> [(path: String, content: String)] {
        let baseDir = (path as NSString).deletingLastPathComponent
        let names = ["WorkShadow", "WorkClone"]
        return names.map { name in
            var content = BelievableCodeFactory.tsUtilityModule(rng: &rng, module: name, approxLines: 60)
            content += """

            export function use(a: string, b: string): string { return a + b }

            export function block2(n: number): number {
                const t = n * 3
                return t
            }
            """
            let decoyPath = baseDir.isEmpty ? "\(name).ts" : "\(baseDir)/\(name).ts"
            return (path: decoyPath, content: content)
        }
    }

    // MARK: - Unified Patch Helpers

    /// Computes the line range for a TypeScript function (including trailing blank line if present)
    /// - Parameters:
    ///   - base: Baseline file lines
    ///   - fnName: Function name (e.g., "b" for "export function b(...)")
    /// - Returns: Closed range in 0-indexed line numbers, or nil if not found
    private func computeTsFunctionRange(_ base: [String], fnName: String) -> ClosedRange<Int>? {
        guard let start = base.firstIndex(where: { $0.hasPrefix("export function \(fnName)(") }) else { return nil }
        var end = start
        while end < base.count, base[end] != "}" {
            end += 1
        }
        if end >= base.count {
            return nil
        }
        // Include trailing blank line if present
        if end + 1 < base.count, base[end + 1].isEmpty {
            end += 1
        }
        return start ... end
    }

    /// Computes the line range for a Go function (including trailing blank line if present)
    private func computeGoFunctionRange(_ base: [String], fnName: String) -> ClosedRange<Int>? {
        guard let start = base.firstIndex(where: { $0.hasPrefix("func \(fnName)(") }) else { return nil }
        var end = start
        while end < base.count, base[end] != "}" {
            end += 1
        }
        if end >= base.count {
            return nil
        }
        // Include trailing blank line if present
        if end + 1 < base.count, base[end + 1].isEmpty {
            end += 1
        }
        return start ... end
    }

    /// Computes the line range for a Swift function (including trailing blank line if present)
    private func computeSwiftFunctionRange(_ base: [String], fnName: String) -> ClosedRange<Int>? {
        guard let start = base.firstIndex(where: { $0.hasPrefix("public func \(fnName)(") }) else { return nil }
        var end = start
        while end < base.count, base[end] != "}" {
            end += 1
        }
        if end >= base.count {
            return nil
        }
        // Include trailing blank line if present
        if end + 1 < base.count, base[end + 1].isEmpty {
            end += 1
        }
        return start ... end
    }

    /// Builds a noise hunk for TypeScript (no-op change with context)
    /// - Parameters:
    ///   - baseline: Original file lines
    ///   - bofAdded: Number of lines added at beginning of file
    ///   - removedSpans: Ranges of lines that will be removed by earlier hunks
    ///   - valueMarker: The line to target for no-op (default: "export const value = 42")
    ///   - context: Number of context lines to include (default: 3)
    /// - Returns: Unified diff hunk string, or empty if marker not found
    private func buildTsNoiseHunk(
        baseline: [String],
        bofAdded: Int,
        removedSpans: [ClosedRange<Int>],
        valueMarker: String = "export const value = 42",
        context: Int = 3
    ) -> String {
        guard let valueIdx = baseline.firstIndex(of: valueMarker), valueIdx > 0 else { return "" }
        let availableAbove = min(context, valueIdx)
        let ctxStart = valueIdx - availableAbove
        let oldStart = ctxStart + 1 // 1-based
        let oldCount = availableAbove + 1 // context above + 1 target
        let removedCount = removedSpans.reduce(0) { $0 + ($1.count) }
        let newStart = oldStart + bofAdded - removedCount

        var lines: [String] = []
        lines.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(oldCount) @@")
        for i in 0 ..< availableAbove {
            lines.append(" \(baseline[ctxStart + i])")
        }
        lines.append("-\(baseline[valueIdx])")
        lines.append("+\(baseline[valueIdx])")
        return lines.joined(separator: "\n")
    }

    /// Builds a noise hunk for Go (no-op change with context)
    private func buildGoNoiseHunk(
        baseline: [String],
        bofAdded: Int,
        removedSpans: [ClosedRange<Int>],
        valueMarker: String = "const value = 42",
        context: Int = 3
    ) -> String {
        guard let idx = baseline.firstIndex(of: valueMarker) else { return "" }
        let availableAbove = min(context, idx)
        let ctxStart = idx - availableAbove
        let oldStart = ctxStart + 1 // 1-based
        let oldCount = availableAbove + 1
        let removed = removedSpans.reduce(0) { $0 + ($1.count) }
        let newStart = oldStart + bofAdded - removed

        var h: [String] = []
        h.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(oldCount) @@")
        for i in 0 ..< availableAbove {
            h.append(" \(baseline[ctxStart + i])")
        }
        h.append("-\(baseline[idx])")
        h.append("+\(baseline[idx])")
        return h.joined(separator: "\n")
    }

    /// Builds a noise hunk for Swift (no-op change with context)
    private func buildSwiftNoiseHunk(
        baseline: [String],
        bofAdded: Int,
        removedSpans: [ClosedRange<Int>],
        valueMarker: String = "public let value = 42",
        context: Int = 3
    ) -> String {
        guard let idx = baseline.firstIndex(of: valueMarker) else { return "" }
        let availableAbove = min(context, idx)
        let ctxStart = idx - availableAbove
        let oldStart = ctxStart + 1 // 1-based
        let oldCount = availableAbove + 1
        let removed = removedSpans.reduce(0) { $0 + ($1.count) }
        let newStart = oldStart + bofAdded - removed

        var h: [String] = []
        h.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(oldCount) @@")
        for i in 0 ..< availableAbove {
            h.append(" \(baseline[ctxStart + i])")
        }
        h.append("-\(baseline[idx])")
        h.append("+\(baseline[idx])")
        return h.joined(separator: "\n")
    }

    /// Creates a slightly mutated clone of a patchable file to act as a decoy
    /// The clone is similar enough to be confusing but different enough that the patch won't apply exactly
    private func makePatchableClone(language: BenchmarkLanguage, origin: [String], variant: Int) -> [String] {
        var clone = origin

        switch language {
        case .ts:
            // Mutate constants by incrementing variant offset
            for (idx, line) in clone.enumerated() {
                if line.contains("export const value = ") {
                    clone[idx] = "export const value = \(42 + variant + 1)"
                } else if line.contains("export const value2 = ") {
                    clone[idx] = "export const value2 = \(7 + variant)"
                } else if line.contains("export const value3 = ") {
                    clone[idx] = "export const value3 = \(100 + variant * 2)"
                }
            }
            // Add a harmless comment near a different function than patch touches
            if let cIdx = clone.firstIndex(where: { $0.hasPrefix("export function c(") }) {
                clone.insert("    // Clone variant \(variant)", at: cIdx + 1)
            }

        case .go:
            // Mutate constants by incrementing variant offset
            for (idx, line) in clone.enumerated() {
                if line.contains("const value = ") {
                    clone[idx] = "const value = \(42 + variant + 1)"
                } else if line.contains("const value2 = ") {
                    clone[idx] = "const value2 = \(7 + variant)"
                } else if line.contains("const value3 = ") {
                    clone[idx] = "const value3 = \(100 + variant * 2)"
                }
            }
            // Add a harmless comment near function c
            if let cIdx = clone.firstIndex(where: { $0.hasPrefix("func c(") }) {
                clone.insert("    // Clone variant \(variant)", at: cIdx + 1)
            }

        case .swift:
            // Mutate constants by incrementing variant offset
            for (idx, line) in clone.enumerated() {
                if line.contains("public let value = ") {
                    clone[idx] = "public let value = \(42 + variant + 1)"
                } else if line.contains("public let value2 = ") {
                    clone[idx] = "public let value2 = \(7 + variant)"
                } else if line.contains("public let value3 = ") {
                    clone[idx] = "public let value3 = \(100 + variant * 2)"
                }
            }
            // Add a harmless comment near function c
            if let cIdx = clone.firstIndex(where: { $0.hasPrefix("public func c(") }) {
                clone.insert("\t// Clone variant \(variant)", at: cIdx + 1)
            }

        @unknown default:
            // For other languages, just add a comment at the top if possible
            if !clone.isEmpty {
                clone.insert("// Clone variant \(variant)", at: 0)
            }
        }

        return clone
    }

    private func removedLineCount(before index: Int, in spans: [ClosedRange<Int>]) -> Int {
        spans.filter { $0.upperBound < index }.map(\.count).reduce(0, +)
    }

    private func newStart(oldStart1Based: Int, bofAdded: Int, removedSpansBeforeTarget: Int) -> Int {
        oldStart1Based + bofAdded - removedSpansBeforeTarget
    }
}
