#if DEBUG
    enum WorkspaceSwitchSearchIndexDiagnostics {
        static func fields(
            storeBefore: WorkspaceFileContextStore.StoreWorkDiagnosticsSnapshot,
            storeAfter: WorkspaceFileContextStore.StoreWorkDiagnosticsSnapshot,
            searchBefore: WorkspaceSearchService.RebuildWorkDiagnosticsSnapshot,
            searchAfter: WorkspaceSearchService.RebuildWorkDiagnosticsSnapshot,
            snapshot: WorkspaceSearchCatalogSnapshot,
            requestedCapability: WorkspaceSearchCatalogAccessRequirement
        ) -> [String: String] {
            let beforeShards = storeBefore.rootCatalogShards
            let afterShards = storeAfter.rootCatalogShards
            let beforeAuthoritative = beforeShards.roots.reduce(0) { $0 + $1.authoritativeRebuildCount }
            let afterAuthoritative = afterShards.roots.reduce(0) { $0 + $1.authoritativeRebuildCount }
            let beforeFallback = beforeShards.roots.reduce(0) { $0 + $1.fallbackCount }
            let afterFallback = afterShards.roots.reduce(0) { $0 + $1.fallbackCount }
            let beforePathIndex = beforeShards.roots.reduce(0) { $0 + $1.pathIndexBuildCount }
            let afterPathIndex = afterShards.roots.reduce(0) { $0 + $1.pathIndexBuildCount }
            let beforeOverlayPathIndex = beforeShards.roots.reduce(0) { $0 + $1.overlayPathIndexBuildCount }
            let afterOverlayPathIndex = afterShards.roots.reduce(0) { $0 + $1.overlayPathIndexBuildCount }
            let beforeFallbackReasons = fallbackReasonCounts(beforeShards)
            let afterFallbackReasons = fallbackReasonCounts(afterShards)

            return [
                "requestedCapability": searchCatalogRequirementDescription(requestedCapability),
                "snapshotPathIndexes": "\(snapshot.rootPathIndexes.count)",
                "catalogRebuildWorkDelta": "\(storeAfter.catalogRebuild.rebuildCount - storeBefore.catalogRebuild.rebuildCount)",
                "searchRebuildWorkDelta": "\(searchAfter.rebuildCount - searchBefore.rebuildCount)",
                "searchStaleDiscardedDelta": "\(searchAfter.staleDiscardedCount - searchBefore.staleDiscardedCount)",
                "searchDebounceCancellationDelta": "\(searchAfter.debounceCancellationCount - searchBefore.debounceCancellationCount)",
                "searchLastEntryCount": "\(searchAfter.lastEntryCount)",
                "shardBuildDelta": "\(afterShards.totalBuildCount - beforeShards.totalBuildCount)",
                "authoritativeRebuildDelta": "\(afterAuthoritative - beforeAuthoritative)",
                "pathIndexBuildDelta": "\(afterPathIndex - beforePathIndex)",
                "overlayPathIndexBuildDelta": "\(afterOverlayPathIndex - beforeOverlayPathIndex)",
                "fallbackDelta": "\(afterFallback - beforeFallback)",
                "fallbackReasonDeltas": fallbackReasonDeltas(before: beforeFallbackReasons, after: afterFallbackReasons),
                "publishedShardCount": "\(afterShards.publishedShardCount)",
                "totalShardBuildCount": "\(afterShards.totalBuildCount)",
                "totalShardFallbackCount": "\(afterFallback)",
                "totalAuthoritativeRebuildCount": "\(afterAuthoritative)"
            ]
        }

        private static func searchCatalogRequirementDescription(_ requirement: WorkspaceSearchCatalogAccessRequirement) -> String {
            switch requirement {
            case .recordsOnly:
                "recordsOnly"
            case .recordsAndPathIndexes:
                "recordsAndPathIndexes"
            }
        }

        private static func fallbackReasonCounts(
            _ snapshot: WorkspaceFileContextStore.RootCatalogShardDebugSnapshot
        ) -> [String: Int] {
            var counts: [String: Int] = [:]
            for root in snapshot.roots {
                for (reason, count) in root.fallbackReasonCounts {
                    counts[reason.rawValue, default: 0] += count
                }
            }
            return counts
        }

        private static func fallbackReasonDeltas(before: [String: Int], after: [String: Int]) -> String {
            let reasons = Set(before.keys).union(after.keys).sorted()
            let deltas = reasons.compactMap { reason -> String? in
                let delta = (after[reason] ?? 0) - (before[reason] ?? 0)
                guard delta != 0 else { return nil }
                return "\(reason):\(delta)"
            }
            return deltas.isEmpty ? "none" : deltas.joined(separator: ",")
        }
    }
#endif
