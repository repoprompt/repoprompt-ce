import Combine
import Foundation

// MARK: - Wizard Step

/// Identifies wizard steps in the recommendation flow.
enum RecommendationWizardStep: String, CaseIterable, Identifiable {
    case intro
    case chatModel
    case contextBuilder
    case presets
    case mcpAgentDefaults
    case summary

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .intro: "Setup Wizard"
        case .chatModel: "Oracle"
        case .contextBuilder: "Context Builder"
        case .presets: "MCP Presets"
        case .mcpAgentDefaults: "Agent Role Defaults"
        case .summary: "Summary"
        }
    }

    var subtitle: String {
        switch self {
        case .intro: "Optimize your RepoPrompt setup"
        case .chatModel: "Choose your Oracle"
        case .contextBuilder: "Configure context building"
        case .presets: "Configure MCP presets"
        case .mcpAgentDefaults: "How Oracle assigns default agents by task"
        case .summary: "Setup complete"
        }
    }

    var systemImage: String {
        switch self {
        case .intro: "wand.and.stars"
        case .chatModel: "bubble.left.and.bubble.right"
        case .contextBuilder: "doc.text.magnifyingglass"
        case .presets: "slider.horizontal.3"
        case .mcpAgentDefaults: "person.3.fill"
        case .summary: "checkmark.circle"
        }
    }
}

// MARK: - Refresh Navigation Mode

/// Describes how the wizard should update currentStepIndex when recommendations change.
enum RefreshNavigationMode {
    /// Reset to intro step (default for fresh start)
    case resetToIntro
    /// Preserve the current step if possible, otherwise advance
    case preserveCurrentStep
    /// Advance from a specific step to the next logical one
    case advanceFrom(previousStep: RecommendationWizardStep?)
}

// MARK: - Recommendation Wizard ViewModel

/// UI-facing state for the recommendation wizard toolbar button and popover.
@MainActor
final class RecommendationWizardViewModel: ObservableObject {
    // MARK: - Constants

    /// Canonical ordering of wizard steps for navigation calculations.
    private static let orderedSteps: [RecommendationWizardStep] = [
        .intro, .chatModel, .contextBuilder, .presets, .mcpAgentDefaults, .summary
    ]

    // MARK: - Published State

    /// Current wizard steps (filtered based on available recommendations).
    @Published private(set) var steps: [RecommendationWizardStep] = []

    /// Current step index in the wizard.
    @Published var currentStepIndex: Int = 0

    /// All recommendations for the current workspace.
    @Published private(set) var recommendations: RecommendationSet = .init()

    /// Whether there are any active (non-muted) recommendations.
    @Published private(set) var hasActiveRecommendations: Bool = false

    /// Loading state for refresh operations.
    @Published private(set) var isLoading: Bool = false

    /// Provider status snapshot.
    @Published private(set) var providerStatus: ProviderStatusSnapshot?

    /// Providers the wizard is allowed to consider when generating model/agent recommendations.
    @Published var enabledRecommendationProviders: Set<RecommendationProviderKind> = Set(RecommendationProviderKind.allCases)

    /// The provider set that was last applied (used to detect pending changes in the filter popover).
    @Published private(set) var appliedRecommendationProviders: Set<RecommendationProviderKind> = Set(RecommendationProviderKind.allCases)

    // MARK: - Chat Model Step State

    /// User's selection for chat backend (in the chat model step).
    @Published var selectedChatBackend: ChatBackendKind = .claudeCode

    /// Tracks whether the user has explicitly selected a chat backend in the wizard UI.
    /// When true, `updateSelectedChatBackend` will not overwrite the user's selection during refresh.
    private var userDidSelectChatBackend: Bool = false

    /// Forces provider-sensitive recommendations back into the wizard after the provider filter changes.
    /// Example: the current Oracle may still be a viable model, but Apply should reset it to the filtered recommendation.
    private var shouldReapplyProviderSensitiveRecommendations = false

    // MARK: - Dependencies

    private let engine: AutoRecommendationEngine
    private let settingsStore: GlobalSettingsStore
    private weak var workspaceManager: WorkspaceManagerViewModel?
    let windowID: Int
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed Properties

    /// Whether to show a badge on the toolbar button.
    var shouldShowBadge: Bool {
        guard let wsID = workspaceManager?.activeWorkspaceID else { return false }
        guard hasActiveRecommendations else { return false }
        return !engine.hasCompletedRecently(workspaceID: wsID)
    }

    /// Current step in the wizard.
    var currentStep: RecommendationWizardStep? {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    /// Progress string for the wizard header.
    var progressText: String {
        guard !steps.isEmpty else { return "" }
        return "Step \(currentStepIndex + 1) of \(steps.count)"
    }

    /// Whether we can go to the previous step.
    var canGoBack: Bool {
        currentStepIndex > 0
    }

    /// Whether we're on the last step.
    var isLastStep: Bool {
        currentStepIndex == steps.count - 1
    }

    /// True when the applied recommendations are limited to a provider subset.
    var isProviderFilterActive: Bool {
        appliedRecommendationProviders != Set(RecommendationProviderKind.allCases)
    }

    /// Compact text describing the active provider filter.
    var providerFilterSummary: String {
        if !isProviderFilterActive {
            return "All providers"
        }
        if appliedRecommendationProviders.isEmpty {
            return "No providers"
        }
        return RecommendationProviderKind.allCases
            .filter { appliedRecommendationProviders.contains($0) }
            .map(\.shortDisplayName)
            .joined(separator: ", ")
    }

    /// Short button title for the provider filter control (reflects applied state).
    var providerFilterButtonTitle: String {
        if !isProviderFilterActive {
            return "Providers"
        }
        if appliedRecommendationProviders.isEmpty {
            return "No providers"
        }
        if appliedRecommendationProviders.count == 1,
           let provider = RecommendationProviderKind.allCases.first(where: { appliedRecommendationProviders.contains($0) })
        {
            return provider.shortDisplayName
        }
        return "\(appliedRecommendationProviders.count) providers"
    }

    // MARK: - Initialization

    /// Whether there are any wizard content steps (beyond intro and summary).
    var hasWizardContentSteps: Bool {
        steps.contains(where: { $0 != .intro && $0 != .summary })
    }

    /// Number of currently actionable recommendations shown in the intro preview.
    var actionableRecommendationCount: Int {
        var count = recommendations.actionableUnsatisfiedCount
        if let chatRec = recommendations.chatModel,
           chatRec.alreadySatisfied,
           shouldShowChatModelRecommendation(chatRec),
           !chatRec.isMuted
        {
            count += 1
        }
        return count
    }

    /// Open the Agent Mode settings tab for this window.
    func openAgentModeSettings() {
        NotificationCenter.default.post(
            name: .showAgentModeSettingsTab,
            object: nil,
            userInfo: ["windowID": windowID]
        )
    }

    init(
        engine: AutoRecommendationEngine,
        settingsStore: GlobalSettingsStore,
        workspaceManager: WorkspaceManagerViewModel?,
        windowID: Int = 0
    ) {
        self.engine = engine
        self.settingsStore = settingsStore
        self.workspaceManager = workspaceManager
        self.windowID = windowID

        let initialProviders = settingsStore.globalRecommendationProviderFilter()
        enabledRecommendationProviders = initialProviders
        appliedRecommendationProviders = initialProviders

        setupSubscriptions()
        refresh(navigation: .resetToIntro)
    }

    // MARK: - Subscriptions

    /// Subscribe to changes that affect recommendations.
    private func setupSubscriptions() {
        // Subscribe to workspace changes - new workspace should start at intro
        workspaceManager?.$activeWorkspaceID
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh(navigation: .resetToIntro)
            }
            .store(in: &cancellables)

        // Subscribe to CLI connection and API key changes
        // Preserve current step if possible when provider status changes
        // Also attempt auto-apply for workspaces that haven't been auto-applied yet
        if let api = engine.apiSettingsViewModel {
            Publishers.MergeMany([
                api.$isClaudeCodeConnected.map { _ in () }.eraseToAnyPublisher(),
                api.$isCodexConnected.map { _ in () }.eraseToAnyPublisher(),
                api.$isCursorConnected.map { _ in () }.eraseToAnyPublisher(),
                api.$isOpenAIKeyValid.map { _ in () }.eraseToAnyPublisher()
            ])
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.tryAutoApplyOnProviderChange()
                self?.refresh(navigation: .preserveCurrentStep)
            }
            .store(in: &cancellables)

            // Startup verification changes effective readiness, but must never auto-apply a
            // transient fallback into persisted recommendation settings.
            Publishers.Merge(
                api.$isContextBuilderProviderValidationComplete.map { _ in () },
                api.$contextBuilderVerifiedCLIProviders.map { _ in () }
            )
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh(navigation: .preserveCurrentStep)
            }
            .store(in: &cancellables)
        }

        // Subscribe to recommendation-related setting changes
        // Filter out notifications that we emitted ourselves to avoid self-triggered loops
        NotificationCenter.default.publisher(for: .recommendationsDidApply)
            .filter { [weak self] notification in
                guard let self else { return false }
                // Ignore notifications emitted by this view model
                return (notification.object as? RecommendationWizardViewModel) !== self
            }
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh(navigation: .preserveCurrentStep)
            }
            .store(in: &cancellables)

        // Subscribe to "inputs changed" invalidation (e.g., Context Builder agent kind changed)
        // This is separate from recommendationsDidApply to avoid triggering PromptVM sync/discard
        NotificationCenter.default.publisher(for: .recommendationsShouldRefresh)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refresh(navigation: .preserveCurrentStep)
            }
            .store(in: &cancellables)

        // Subscribe to workspace creation for auto-apply
        NotificationCenter.default.publisher(for: .workspaceDidCreate)
            .sink { [weak self] notification in
                guard let self,
                      let workspaceID = notification.userInfo?["workspaceID"] as? UUID else { return }
                autoApplyForNewWorkspace(workspaceID: workspaceID)
            }
            .store(in: &cancellables)
    }

    // MARK: - Refresh

    /// Refresh recommendations for the current workspace with specified navigation behavior.
    /// - Parameter navigation: How to handle step navigation after recomputation.
    func refresh(navigation: RefreshNavigationMode = .resetToIntro) {
        guard let wsID = workspaceManager?.activeWorkspaceID else {
            steps = []
            hasActiveRecommendations = false
            providerStatus = nil
            currentStepIndex = 0
            return
        }

        isLoading = true
        let previousStep = currentStep // snapshot before recompute

        // Recompute state (provider status, recommendations, steps)
        let recs = recomputeState(for: wsID)
        steps = buildSteps(from: recs)

        // Navigate based on mode
        switch navigation {
        case .resetToIntro:
            currentStepIndex = 0
            // Reset explicit selection flag when starting fresh
            userDidSelectChatBackend = false

        case .preserveCurrentStep:
            setCurrentStepIndexPreserving(previousStep: previousStep)

        case let .advanceFrom(step):
            setCurrentStepIndexAdvancing(from: step ?? previousStep)
        }

        isLoading = false
    }

    /// Recomputes provider status and recommendations, updates core published state except navigation.
    @discardableResult
    private func recomputeState(for workspaceID: UUID) -> RecommendationSet {
        // 1) Provider status snapshot
        let status = engine.computeProviderStatus()
        providerStatus = status

        // 2) Compute + apply mutes
        let raw = engine.computeRecommendations(for: workspaceID, enabledProviders: appliedRecommendationProviders)
        let filtered = engine.applyMutedFlags(raw, workspaceID: workspaceID)

        // 3) Update VM state (except step index)
        recommendations = filtered
        let shouldReapplyOracle = shouldReapplyProviderSensitiveRecommendations && filtered.chatModel?.isMuted != true && filtered.chatModel != nil
        hasActiveRecommendations = filtered.hasUnsatisfied || shouldReapplyOracle

        // 4) Keep chat backend selection in sync with actual settings
        if let chatRec = filtered.chatModel {
            updateSelectedChatBackend(from: chatRec)
        }

        return filtered
    }

    /// Updates selectedChatBackend for wizard actions.
    /// Skips update if the user has explicitly selected a backend in the wizard UI.
    ///
    /// When a recommendation is unsatisfied, we preselect the recommendation's default backend
    /// so "Apply" and "Quick Apply All" move to the recommended setup by default.
    private func updateSelectedChatBackend(from rec: ChatModelRecommendation) {
        // Don't overwrite if user has explicitly selected a backend in the wizard
        guard !userDidSelectChatBackend else { return }

        // After a provider-filter change, intentionally reset Oracle to the filtered recommendation.
        if shouldReapplyProviderSensitiveRecommendations,
           rec.option(for: rec.defaultBackend) != nil
        {
            selectedChatBackend = rec.defaultBackend
            return
        }

        // For unsatisfied recommendations, default to the recommended backend.
        if !rec.alreadySatisfied, rec.option(for: rec.defaultBackend) != nil {
            selectedChatBackend = rec.defaultBackend
            return
        }

        // Otherwise infer from current model settings.
        if let inferred = engine.inferCurrentChatBackend(from: rec) {
            selectedChatBackend = inferred
        } else {
            selectedChatBackend = rec.defaultBackend
        }
    }

    // MARK: - Navigation Helpers

    /// Preserve the current step if it still exists, otherwise advance to next logical step.
    private func setCurrentStepIndexPreserving(previousStep: RecommendationWizardStep?) {
        guard !steps.isEmpty else { currentStepIndex = 0
            return
        }

        if let prev = previousStep, let idx = steps.firstIndex(of: prev) {
            // Same step still exists
            currentStepIndex = idx
            return
        }

        // If the previous step disappeared (e.g. it became satisfied),
        // try to move to the next logical step; otherwise, summary or intro.
        if let prev = previousStep, let idx = indexForNextStep(after: prev) {
            currentStepIndex = idx
        } else if let summaryIdx = steps.firstIndex(of: .summary) {
            currentStepIndex = summaryIdx
        } else {
            currentStepIndex = 0
        }
    }

    /// Advance from a step to the next logical one in canonical order.
    private func setCurrentStepIndexAdvancing(from previousStep: RecommendationWizardStep?) {
        guard !steps.isEmpty else { currentStepIndex = 0
            return
        }

        if let prev = previousStep, let idx = indexForNextStep(after: prev) {
            currentStepIndex = idx
        } else if let summaryIdx = steps.firstIndex(of: .summary) {
            currentStepIndex = summaryIdx
        } else {
            currentStepIndex = steps.count - 1
        }
    }

    /// Find the index of the next step in canonical order that exists in current steps.
    private func indexForNextStep(after step: RecommendationWizardStep) -> Int? {
        guard let orderIndex = Self.orderedSteps.firstIndex(of: step) else { return nil }

        for next in Self.orderedSteps[(orderIndex + 1)...] {
            if let idx = steps.firstIndex(of: next) {
                return idx
            }
        }
        return nil
    }

    // MARK: - Navigation

    /// Move to the next step.
    func nextStep() {
        if currentStepIndex < steps.count - 1 {
            currentStepIndex += 1
        }
    }

    /// Move to the previous step.
    func previousStep() {
        if currentStepIndex > 0 {
            currentStepIndex -= 1
        }
    }

    /// Go to a specific step.
    func goToStep(_ step: RecommendationWizardStep) {
        if let index = steps.firstIndex(of: step) {
            currentStepIndex = index
        }
    }

    // MARK: - Provider Filter

    /// Returns true when the provider is included in recommendation generation.
    func isRecommendationProviderEnabled(_ provider: RecommendationProviderKind) -> Bool {
        enabledRecommendationProviders.contains(provider)
    }

    /// Toggle whether recommendations should consider a provider (does not recompute until applied).
    func toggleRecommendationProvider(_ provider: RecommendationProviderKind) {
        if enabledRecommendationProviders.contains(provider) {
            enabledRecommendationProviders.remove(provider)
        } else {
            enabledRecommendationProviders.insert(provider)
        }
    }

    /// True when the current provider selection differs from the last applied set.
    var hasUnappliedProviderChanges: Bool {
        enabledRecommendationProviders != appliedRecommendationProviders
    }

    /// Apply the current provider selection globally, clear dismissed state for the active workspace, and recompute recommendations.
    func applyProviderFilter() {
        let providerSelectionChanged = enabledRecommendationProviders != appliedRecommendationProviders
        appliedRecommendationProviders = enabledRecommendationProviders
        if providerSelectionChanged {
            shouldReapplyProviderSensitiveRecommendations = true
        }
        settingsStore.setGlobalRecommendationProviderFilter(appliedRecommendationProviders)
        if let wsID = workspaceManager?.activeWorkspaceID {
            engine.resetWizardState(workspaceID: wsID)
        }
        resetRecommendationComputation()
        NotificationCenter.default.post(
            name: .recommendationsShouldRefresh,
            object: self,
            userInfo: ["reason": "recommendationProviderFilterChanged", "scope": "global"]
        )
    }

    /// Reset provider selection back to all providers (does not recompute until applied).
    func resetProviderFilterToAll() {
        enabledRecommendationProviders = Set(RecommendationProviderKind.allCases)
    }

    /// Reset transient wizard choices and recompute from the first step.
    private func resetRecommendationComputation() {
        userDidSelectChatBackend = false
        appliedRecommendations = RecommendationSet()
        refresh(navigation: .resetToIntro)
    }

    /// True when Oracle should be shown/applied even if the current model was previously considered acceptable.
    func shouldShowChatModelRecommendation(_ rec: ChatModelRecommendation) -> Bool {
        !rec.alreadySatisfied || shouldReapplyProviderSensitiveRecommendations
    }

    // MARK: - User Selection Tracking

    /// Call this when the user explicitly selects a chat backend in the wizard UI.
    /// This prevents automatic refresh from overwriting the user's selection.
    func userDidSelectBackend(_ backend: ChatBackendKind) {
        selectedChatBackend = backend
        userDidSelectChatBackend = true
    }

    // MARK: - Apply Actions

    /// Apply the current step's recommendation and advance to next step.
    func applyCurrentStep() {
        guard let wsID = workspaceManager?.activeWorkspaceID else { return }
        guard let step = currentStep else { return }

        switch step {
        case .chatModel:
            if let rec = recommendations.chatModel {
                engine.applyChatModelRecommendation(rec, backend: selectedChatBackend, workspaceID: wsID)
            }
            // Reset explicit selection flag after applying
            userDidSelectChatBackend = false
            shouldReapplyProviderSensitiveRecommendations = false
        case .contextBuilder:
            if let rec = recommendations.contextBuilder {
                engine.applyContextBuilderRecommendation(rec, workspaceID: wsID)
            }
        case .presets:
            if let rec = recommendations.mcpPresetExposure {
                engine.applyMCPPresetExposure(rec)
            }
        case .mcpAgentDefaults:
            if let rec = recommendations.mcpAgentDefaults, !rec.alreadySatisfied {
                engine.applyMCPAgentDefaultsRecommendation(rec, workspaceID: wsID)
            }
        case .intro, .summary:
            // Nothing to apply for intro/summary
            return
        }

        // 1) Recompute recommendations and advance from the step we just applied
        refresh(navigation: .advanceFrom(previousStep: step))

        // 2) Notify other view models (PromptViewModel, ContextBuilderAgentViewModel, etc)
        // Pass self as object so our own subscription filters it out
        NotificationCenter.default.post(
            name: .recommendationsDidApply,
            object: self,
            userInfo: ["workspaceID": wsID]
        )
    }

    /// Skip the current step without applying.
    func skipCurrentStep() {
        if currentStep == .chatModel {
            shouldReapplyProviderSensitiveRecommendations = false
        }
        nextStep()
    }

    /// Mute the current step's recommendation and advance to next step.
    func muteCurrentStep() {
        guard let wsID = workspaceManager?.activeWorkspaceID else { return }
        guard let step = currentStep else { return }

        let kind: RecommendationKind? = switch step {
        case .chatModel: .chatModel
        case .contextBuilder: .contextBuilderAgent
        case .presets: .mcpPresetExposure
        case .mcpAgentDefaults: .mcpAgentDefaults
        case .intro, .summary: nil
        }

        guard let kind else { return }

        engine.mute(kind, workspaceID: wsID)
        if step == .chatModel {
            shouldReapplyProviderSensitiveRecommendations = false
        }

        // Treat mute as "we're done with this step; go to the next one"
        refresh(navigation: .advanceFrom(previousStep: step))
    }

    /// Mark wizard as completed (call on dismiss or finish).
    func markCompleted() {
        guard let wsID = workspaceManager?.activeWorkspaceID else { return }
        engine.markWizardCompleted(workspaceID: wsID)
    }

    /// Reset to intro step (shows status view when no active recommendations).
    func resetToIntro() {
        currentStepIndex = 0
        appliedRecommendations = RecommendationSet()
    }

    // MARK: - Auto-Apply for New Workspaces

    /// Called when a workspace is newly created in this window.
    /// Applies eligible recommendations, then refreshes wizard state.
    func autoApplyForNewWorkspace(workspaceID: UUID) {
        let didApply = engine.autoApplyRecommendationsIfEligible(for: workspaceID)

        if didApply {
            // Post notification so PromptVM/ContextBuilderVM can update bindings correctly
            NotificationCenter.default.post(
                name: .recommendationsDidApply,
                object: self,
                userInfo: ["workspaceID": workspaceID]
            )
        }

        // Refresh wizard state to reflect any changes
        refresh(navigation: .resetToIntro)
    }

    /// Called when provider status changes (CLI connected, API key validated).
    /// Attempts auto-apply for workspaces that haven't been auto-applied yet.
    /// This handles the case where a workspace was created before any CLI was connected.
    private func tryAutoApplyOnProviderChange() {
        guard let wsID = workspaceManager?.activeWorkspaceID else { return }

        let didApply = engine.autoApplyRecommendationsIfEligible(for: wsID)

        if didApply {
            // Post notification so PromptVM/ContextBuilderVM can update bindings correctly
            NotificationCenter.default.post(
                name: .recommendationsDidApply,
                object: self,
                userInfo: ["workspaceID": wsID]
            )
        }
    }

    // MARK: - Apply All

    /// Track what was applied for summary display
    @Published private(set) var appliedRecommendations: RecommendationSet = .init()

    /// Apply all recommendations at once (for quick setup).
    /// After applying, verifies by recomputing recommendations before deciding whether to show Summary.
    func applyAllRecommendations() {
        guard let wsID = workspaceManager?.activeWorkspaceID else {
            return
        }

        // Only apply and track unsatisfied, non-muted recommendations
        var applied = RecommendationSet()

        if let rec = recommendations.chatModel, shouldShowChatModelRecommendation(rec), !rec.isMuted {
            engine.applyChatModelRecommendation(rec, backend: selectedChatBackend, workspaceID: wsID)
            applied.chatModel = rec
            // Reset explicit selection flag after applying
            userDidSelectChatBackend = false
            shouldReapplyProviderSensitiveRecommendations = false
        }
        if let rec = recommendations.contextBuilder, !rec.alreadySatisfied, !rec.isMuted {
            engine.applyContextBuilderRecommendation(rec, workspaceID: wsID)
            applied.contextBuilder = rec
        }
        if let rec = recommendations.mcpPresetExposure, !rec.alreadySatisfied, !rec.isMuted {
            engine.applyMCPPresetExposure(rec)
            applied.mcpPresetExposure = rec
        }
        if let rec = recommendations.mcpAgentDefaults, !rec.alreadySatisfied, !rec.isMuted {
            engine.applyMCPAgentDefaultsRecommendation(rec, workspaceID: wsID)
            applied.mcpAgentDefaults = rec
        }

        appliedRecommendations = applied

        // Post single notification AFTER all recommendations applied
        // Pass self as object so our own subscription filters it out
        NotificationCenter.default.post(
            name: .recommendationsDidApply,
            object: self,
            userInfo: ["workspaceID": wsID]
        )

        markCompleted()

        // Verify the settings actually satisfy recommendations before clearing the UI.
        refresh(navigation: .preserveCurrentStep)

        // Only navigate to Summary once recomputation confirms nothing actionable remains.
        if !hasActiveRecommendations {
            goToStep(.summary)
        }
    }

    // MARK: - Mute Recommendations

    /// Mute a recommendation and skip to next step.
    func muteAndSkip(_ kind: RecommendationKind) {
        guard let wsID = workspaceManager?.activeWorkspaceID else { return }

        engine.mute(kind, workspaceID: wsID)

        // Set isMuted flag on the recommendation (keep it in the set)
        switch kind {
        case .chatModel:
            recommendations.chatModel?.isMuted = true
        case .contextBuilderAgent:
            recommendations.contextBuilder?.isMuted = true
        case .mcpPresetExposure:
            recommendations.mcpPresetExposure?.isMuted = true
        case .mcpAgentDefaults:
            recommendations.mcpAgentDefaults?.isMuted = true
        }

        // Rebuild steps and move to next
        steps = buildSteps(from: recommendations)
        hasActiveRecommendations = recommendations.hasUnsatisfied

        // If we're past the available steps, go to summary
        if currentStepIndex >= steps.count {
            currentStepIndex = steps.count - 1
        }
    }

    /// Unmute a recommendation and refresh.
    func unmute(_ kind: RecommendationKind) {
        guard let wsID = workspaceManager?.activeWorkspaceID else { return }

        engine.unmute(kind, workspaceID: wsID)

        // Clear isMuted flag
        switch kind {
        case .chatModel:
            recommendations.chatModel?.isMuted = false
        case .contextBuilderAgent:
            recommendations.contextBuilder?.isMuted = false
        case .mcpPresetExposure:
            recommendations.mcpPresetExposure?.isMuted = false
        case .mcpAgentDefaults:
            recommendations.mcpAgentDefaults?.isMuted = false
        }

        // Rebuild steps
        steps = buildSteps(from: recommendations)
        hasActiveRecommendations = recommendations.hasUnsatisfied
    }

    // MARK: - Private Helpers

    /// Build wizard steps based on available recommendations.
    /// Only includes steps for recommendations that need action (not satisfied and not muted).
    private func buildSteps(from recs: RecommendationSet) -> [RecommendationWizardStep] {
        var steps: [RecommendationWizardStep] = [.intro]

        // Only show steps for recommendations that need action (not satisfied, not muted)
        if let chatRec = recs.chatModel, shouldShowChatModelRecommendation(chatRec), !chatRec.isMuted {
            steps.append(.chatModel)
        }
        if let cbRec = recs.contextBuilder, !cbRec.alreadySatisfied, !cbRec.isMuted {
            steps.append(.contextBuilder)
        }
        if let mcpRec = recs.mcpPresetExposure, !mcpRec.alreadySatisfied, !mcpRec.isMuted {
            steps.append(.presets)
        }
        // Agent defaults step shows when available, even if already satisfied
        if let agentRec = recs.mcpAgentDefaults, !agentRec.isMuted, !agentRec.recommendedRoleDefaults.isEmpty {
            steps.append(.mcpAgentDefaults)
        }

        steps.append(.summary)

        return steps
    }
}

// MARK: - Best Practices Table Helper

extension RecommendationWizardViewModel {
    var bestPracticesTitle: String {
        BestPracticeProfiles.tableTitle
    }

    /// Get the best practices use cases for display.
    var bestPracticesUseCases: [BestPracticeProfiles.UseCase] {
        BestPracticeProfiles.all
    }

    /// Get the codex vs openai explanation text.
    var codexVsOpenAIExplanation: String {
        BestPracticeProfiles.codexVsOpenAIExplanation
    }
}
