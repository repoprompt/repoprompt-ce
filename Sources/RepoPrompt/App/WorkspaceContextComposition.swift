import Foundation
import RepoPromptFileSystem
import RepoPromptInstrumentation
import RepoPromptPersistence
import RepoPromptShared
import RepoPromptVCS
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension CodeMapArtifactRuntime {
    static func processWide() throws -> CodeMapArtifactRuntime {
        try processWideProvider.runtime()
    }

    static func makeProcessWideProvider(
        identity: MCPFilesystemIdentity,
        applicationSupportRootURL: URL,
        namespaceSaltProvider: @escaping @Sendable (URL, MCPFilesystemIdentity) throws -> Data = { rootURL, identity in
            try CodeMapRepositoryNamespaceSaltStore.loadOrCreate(rootURL: rootURL, identity: identity)
        },
        bindingIntegrationRegistryFactory: @escaping @Sendable () -> WorkspaceCodemapBindingIntegrationRegistry = {
            WorkspaceCodemapBindingIntegrationRegistry()
        },
        postSuccessfulInitialization: @escaping @Sendable () -> Void = {},
        globalCodeMapsDisabled: @escaping @Sendable () async -> Bool = { false },
        bindingEngineDidInitialize: @escaping @Sendable (WorkspaceCodemapBindingEngine) -> Void = { _ in }
    ) -> CodeMapArtifactRuntimeProvider {
        makeProcessWideProvider(
            bindingServicesFactory: { namespaceSalt in
                WorkspaceCodemapBindingEngineServices(
                    capability: WorkspaceCodemapRootCapabilityService(gitService: GitService(), namespaceSalt: namespaceSalt),
                    identity: GitBlobIdentityService(),
                    materialization: GitBlobSourceMaterializationService()
                )
            },
            identity: identity,
            applicationSupportRootURL: applicationSupportRootURL,
            namespaceSaltProvider: namespaceSaltProvider,
            bindingIntegrationRegistryFactory: bindingIntegrationRegistryFactory,
            postSuccessfulInitialization: postSuccessfulInitialization,
            globalCodeMapsDisabled: globalCodeMapsDisabled,
            bindingEngineDidInitialize: bindingEngineDidInitialize
        )
    }
}

/// App defaults preserve the existing actors, filesystem hooks, and shared helper identities.
extension GitService {
    nonisolated func isGitProcessError(_ error: Error) -> Bool {
        error is GitService.GitError
    }
}

extension WorkspaceFileContextHost {
    static func app() -> Self {
        Self(
            rootReusableSnapshotCoordinator: .shared,
            rootMaterializationHintEvaluator: .shared,
            rootSeedPlanner: .shared,
            workspaceStateAuthority: .shared,
            worktreeSeedGitService: GitService(),
            fileSystemFactory: WorkspaceFileSystemServiceFactory { path, repo, cursor, symlinks, hierarchical in
                try await FileSystemService(
                    path: path,
                    respectRepoIgnore: repo,
                    respectCursorignore: cursor,
                    skipSymlinks: symlinks,
                    enableHierarchicalIgnores: hierarchical
                )
            }
        )
    }
}

extension WorkspaceCodemapGitEligibilityProbe {
    static func production(gitService: GitService = GitService()) -> Self {
        production(gitService: gitService as any WorkspaceGitClient)
    }
}

extension WorkspaceRootMaterializationHintEvaluator {
    static let shared = WorkspaceRootMaterializationHintEvaluator()

    init(gitService: GitService = GitService(), authority: GitWorkspaceStateAuthority = .shared) {
        self.init(gitService: gitService as any WorkspaceGitClient, authority: authority)
    }
}

extension WorkspaceRootReusableSnapshotCoordinator {
    static let shared = WorkspaceRootReusableSnapshotCoordinator()

    init(gitService: GitService = GitService(), authority: GitWorkspaceStateAuthority = .shared) {
        self.init(gitService: gitService as any WorkspaceGitClient, authority: authority)
    }
}

extension WorkspaceRootSeedPlanner {
    static let shared = WorkspaceRootSeedPlanner()

    init(
        gitService: GitService = GitService(),
        authority: GitWorkspaceStateAuthority = .shared,
        flightCoordinator: WorkspaceRootTargetEvidenceCoordinator = .shared,
        namespaceResourcePolicy: WorkspaceRootNamespaceManifestResourcePolicy = .default,
        evidenceResourcePolicy: GitTargetEvidenceResourcePolicy = .default,
        planResourcePolicy: WorkspaceRootTargetSeedPlanResourcePolicy = .default
    ) {
        self.init(
            gitService: gitService as any WorkspaceGitClient,
            authority: authority,
            flightCoordinator: flightCoordinator,
            namespaceResourcePolicy: namespaceResourcePolicy,
            evidenceResourcePolicy: evidenceResourcePolicy,
            planResourcePolicy: planResourcePolicy
        )
    }
}

extension WorkspaceCodemapRootCapabilityService {
    init(
        gitService: GitService = GitService(),
        namespaceSalt: Data,
        hooks: WorkspaceCodemapRootCapabilityServiceHooks = .none,
        localClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
        pathFingerprintClient: WorkspaceCodemapPathFingerprintClient = .noFollow,
        historicalRecordLimit: Int = 64
    ) {
        self.init(
            gitService: gitService as any WorkspaceGitClient,
            namespaceSalt: namespaceSalt,
            hooks: hooks,
            localClassificationProbe: localClassificationProbe,
            pathFingerprintClient: pathFingerprintClient,
            historicalRecordLimit: historicalRecordLimit
        )
    }
}

extension GitBlobIdentityService {
    init(gitService: GitService = GitService(), hooks: GitBlobIdentityServiceHooks = .none) {
        self.init(gitService: gitService as any WorkspaceGitClient, hooks: hooks)
    }
}

extension GitBlobSourceMaterializationService {
    init(gitService: GitService = GitService(), policy: GitBlobSourceMaterializationPolicy = .default) {
        self.init(gitService: gitService as any WorkspaceGitClient, policy: policy)
    }
}

extension WorkspaceCodemapBindingEngine {
    init(
        runtime: CodeMapArtifactRuntime,
        capabilityService: WorkspaceCodemapRootCapabilityService,
        identityService: GitBlobIdentityService = GitBlobIdentityService(),
        materializationService: GitBlobSourceMaterializationService = GitBlobSourceMaterializationService(),
        sourceReader: WorkspaceCodemapValidatedSourceReaderClient,
        catalogClient: WorkspaceCodemapBindingCatalogClient = .unavailable,
        overlay: WorkspaceCodemapLiveOverlay = WorkspaceCodemapLiveOverlay(),
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
        policy: WorkspaceCodemapBindingEnginePolicy = .default,
        hooks: WorkspaceCodemapBindingEngineHooks = .none,
        graphPullPause: WorkspaceCodemapGraphPullPause = .production,
        manifestWriterRetryWaiter: WorkspaceCodemapManifestWriterRetryWaiter = .production,
        globalCodeMapsDisabled: @escaping @Sendable () async -> Bool = { false },
        initialQueueOrdinal: UInt64 = 1,
        initialAdmissionOrdinal: UInt64 = 1,
        initialCounterValue: UInt64 = 0,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        accessEpochSeconds: @escaping @Sendable () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970)) }
    ) {
        self.init(
            runtime: runtime,
            services: WorkspaceCodemapBindingEngineServices(
                capability: capabilityService,
                identity: identityService,
                materialization: materializationService
            ),
            sourceReader: sourceReader,
            catalogClient: catalogClient,
            overlay: overlay,
            selectionGraphFactory: selectionGraphFactory,
            policy: policy,
            hooks: hooks,
            graphPullPause: graphPullPause,
            manifestWriterRetryWaiter: manifestWriterRetryWaiter,
            globalCodeMapsDisabled: globalCodeMapsDisabled,
            initialQueueOrdinal: initialQueueOrdinal,
            initialAdmissionOrdinal: initialAdmissionOrdinal,
            initialCounterValue: initialCounterValue,
            uptimeNanoseconds: uptimeNanoseconds,
            accessEpochSeconds: accessEpochSeconds
        )
    }
}

extension WorkspaceFileContextStore {
    #if DEBUG
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
            startupFeatureFlags: WorktreeStartupFeatureFlags = .standaloneOperationalDefault(),
            enableCatalogShardShadowValidation: Bool = true,
            pathSearchCompactionPolicyForTesting: WorkspacePathSearchCompactionPolicy = .production,
            codemapRuntimeProvider: @escaping CodeMapArtifactRuntimeProvider.Factory = {
                try CodeMapArtifactRuntime.processWide()
            },
            codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = .production(),
            codemapGraphIndexBuildRetryPolicy: CodemapGraphIndexBuildRetryPolicy = .production,
            nonGitCodeMapsEnabled: Bool = true,
            codeMapsGloballyDisabled: Bool = false,
            codemapGraphIndexBuildLaunchPolicyForTesting: CodemapGraphIndexBuildLaunchPolicyForTesting = .enabled,
            selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
            selectionGraphQueryBudgetPolicy: WorkspaceCodemapAutomaticSelectionBudgetPolicy = .initial,
            automaticSelectionAccountingMaximum: Int = .max,
            codemapDemandRequestHook: @escaping @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void = { _ in },
            codemapCancellationCleanupHook: @escaping @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void = { _ in },
            codemapReadyPublicationHook: @escaping @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void = { _ in },
            codemapGraphPublicationWaiter: @escaping @Sendable (WorkspaceCodemapRootEpoch) async -> Void = { _ in
                try? await Task.sleep(for: .milliseconds(10))
            },
            codemapDemandResultHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket,
                WorkspaceCodemapBindingDemandResult
            ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
            codemapAutomaticSelectionQueryHook: @escaping @Sendable (WorkspaceCodemapRootEpoch) async -> Void = { _ in },
            restorePerfRecorder: any WorkspaceRestorePerfRecording = NoopWorkspaceRestorePerfRecorder(),
            perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
        ) {
            self.init(
                host: .app(),
                searchLaneConfiguration: searchLaneConfiguration,
                debugNowNanoseconds: debugNowNanoseconds,
                unloadTerminationPolicy: unloadTerminationPolicy,
                startupFeatureFlags: startupFeatureFlags,
                enableCatalogShardShadowValidation: enableCatalogShardShadowValidation,
                pathSearchCompactionPolicyForTesting: pathSearchCompactionPolicyForTesting,
                codemapRuntimeProvider: codemapRuntimeProvider,
                codemapLocalGitClassificationProbe: codemapLocalGitClassificationProbe,
                codemapGitEligibilityProbe: codemapGitEligibilityProbe,
                codemapGraphIndexBuildRetryPolicy: codemapGraphIndexBuildRetryPolicy,
                nonGitCodeMapsEnabled: nonGitCodeMapsEnabled,
                codeMapsGloballyDisabled: codeMapsGloballyDisabled,
                codemapGraphIndexBuildLaunchPolicyForTesting: codemapGraphIndexBuildLaunchPolicyForTesting,
                selectionGraphFactory: selectionGraphFactory,
                selectionGraphQueryBudgetPolicy: selectionGraphQueryBudgetPolicy,
                automaticSelectionAccountingMaximum: automaticSelectionAccountingMaximum,
                codemapDemandRequestHook: codemapDemandRequestHook,
                codemapCancellationCleanupHook: codemapCancellationCleanupHook,
                codemapReadyPublicationHook: codemapReadyPublicationHook,
                codemapGraphPublicationWaiter: codemapGraphPublicationWaiter,
                codemapDemandResultHook: codemapDemandResultHook,
                codemapAutomaticSelectionQueryHook: codemapAutomaticSelectionQueryHook,
                restorePerfRecorder: restorePerfRecorder,
                perfRecorder: perfRecorder
            )
        }
    #else
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production,
            startupFeatureFlags: WorktreeStartupFeatureFlags = .standaloneOperationalDefault(),
            codemapRuntimeProvider: @escaping CodeMapArtifactRuntimeProvider.Factory = {
                try CodeMapArtifactRuntime.processWide()
            },
            codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .production,
            codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = .production(),
            codemapGraphIndexBuildRetryPolicy: CodemapGraphIndexBuildRetryPolicy = .production,
            nonGitCodeMapsEnabled: Bool = false,
            codeMapsGloballyDisabled: Bool = false,
            selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
            selectionGraphQueryBudgetPolicy: WorkspaceCodemapAutomaticSelectionBudgetPolicy = .initial,
            automaticSelectionAccountingMaximum: Int = .max,
            codemapDemandRequestHook: @escaping @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void = { _ in },
            codemapCancellationCleanupHook: @escaping @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void = { _ in },
            codemapReadyPublicationHook: @escaping @Sendable (WorkspaceCodemapArtifactDemandTicket) async -> Void = { _ in },
            codemapGraphPublicationWaiter: @escaping @Sendable (WorkspaceCodemapRootEpoch) async -> Void = { _ in
                try? await Task.sleep(for: .milliseconds(10))
            },
            codemapDemandResultHook: @escaping @Sendable (
                WorkspaceCodemapArtifactDemandTicket,
                WorkspaceCodemapBindingDemandResult
            ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
            codemapAutomaticSelectionQueryHook: @escaping @Sendable (WorkspaceCodemapRootEpoch) async -> Void = { _ in },
            restorePerfRecorder: any WorkspaceRestorePerfRecording = NoopWorkspaceRestorePerfRecorder(),
            perfRecorder: any AgentModePerfRecording = NoopAgentModePerfRecorder()
        ) {
            self.init(
                host: .app(),
                searchLaneConfiguration: searchLaneConfiguration,
                unloadTerminationPolicy: unloadTerminationPolicy,
                startupFeatureFlags: startupFeatureFlags,
                codemapRuntimeProvider: codemapRuntimeProvider,
                codemapLocalGitClassificationProbe: codemapLocalGitClassificationProbe,
                codemapGitEligibilityProbe: codemapGitEligibilityProbe,
                codemapGraphIndexBuildRetryPolicy: codemapGraphIndexBuildRetryPolicy,
                nonGitCodeMapsEnabled: nonGitCodeMapsEnabled,
                codeMapsGloballyDisabled: codeMapsGloballyDisabled,
                selectionGraphFactory: selectionGraphFactory,
                selectionGraphQueryBudgetPolicy: selectionGraphQueryBudgetPolicy,
                automaticSelectionAccountingMaximum: automaticSelectionAccountingMaximum,
                codemapDemandRequestHook: codemapDemandRequestHook,
                codemapCancellationCleanupHook: codemapCancellationCleanupHook,
                codemapReadyPublicationHook: codemapReadyPublicationHook,
                codemapGraphPublicationWaiter: codemapGraphPublicationWaiter,
                codemapDemandResultHook: codemapDemandResultHook,
                codemapAutomaticSelectionQueryHook: codemapAutomaticSelectionQueryHook,
                restorePerfRecorder: restorePerfRecorder,
                perfRecorder: perfRecorder
            )
        }
    #endif
}
