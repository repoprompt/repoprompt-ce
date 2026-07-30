import SwiftUI

struct ChatMessagesView: View {
    @ObservedObject var viewModel: OracleViewModel

    /// Tracks whether we automatically scroll to bottom when new messages arrive.
    @Binding var autoScrollEnabled: Bool

    /// Extra space reserved for the floating composer.
    let bottomOcclusion: CGFloat

    /// Whether to show interactive scroll controls inside the transcript.
    let showsScrollControls: Bool

    /// Whether to auto-scroll to bottom when the view appears.
    let autoScrollOnAppear: Bool

    /// Optional transcript session to render without changing global chat focus.
    let sessionIDOverride: UUID?

    private let contentAnimationDuration: Double = 0.2

    /// Tracks if we're near the bottom of the scrollable area.
    @State private var isNearBottom = false

    @State private var didChatChange = false

    @State private var scrollDebounceWorkItem: DispatchWorkItem? = nil
    @State private var scrollWorkGate = WorkItemGate()

    @State private var loadingSessionID: UUID?
    @State private var pinnedOverrideSessionID: UUID?

    /// Used to force-refresh the ScrollView.
    @State private var refreshToken = UUID()

    /// If < macOS 15.0, we never allow autoScrollEnabled to be true.
    private var supportsAutoScroll: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    init(
        viewModel: OracleViewModel,
        autoScrollEnabled: Binding<Bool>,
        bottomOcclusion: CGFloat,
        showsScrollControls: Bool = true,
        autoScrollOnAppear: Bool = true,
        sessionIDOverride: UUID? = nil
    ) {
        self.viewModel = viewModel
        _autoScrollEnabled = autoScrollEnabled
        self.bottomOcclusion = bottomOcclusion
        self.showsScrollControls = showsScrollControls
        self.autoScrollOnAppear = autoScrollOnAppear
        self.sessionIDOverride = sessionIDOverride
    }

    private var renderedSessionID: UUID? {
        sessionIDOverride ?? viewModel.currentSessionID
    }

    private var renderedMessages: [AIChatMessage] {
        guard let sessionIDOverride else { return viewModel.messages }
        _ = viewModel.messageStoreRevision
        return viewModel.messagesSnapshot(for: sessionIDOverride)
    }

    private var isRenderedSessionStreaming: Bool {
        viewModel.isSessionStreaming(renderedSessionID)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                versionedScrollableContent(proxy: proxy)

                // --------------------------------------------------------------------------
                // Bottom-right overlay: refresh button + play/pause/scroll button stacked
                // --------------------------------------------------------------------------
                VStack(spacing: 12) {
                    // Scroll to bottom button
                    if showsScrollControls, shouldShowScrollToBottomButton {
                        Button(action: {
                            handleBottomButtonTap(proxy: proxy)
                        }) {
                            Image(systemName: "arrow.down.circle.fill")
                                .resizable()
                                .frame(width: 30, height: 30)
                                .foregroundColor(.accentColor)
                                .transition(.scale)
                        }
                        .buttonStyle(SmallRoundButtonStyle())
                        .hoverTooltip("Scroll to bottom")
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16 + bottomOcclusion)

                if sessionIDOverride == nil, let switchingSessionID = viewModel.sessionSwitchInProgressID {
                    sessionSwitchOverlay(for: switchingSessionID)
                } else if let loadingSessionID {
                    sessionSwitchOverlay(for: loadingSessionID)
                }
            }
            .animation(.easeInOut, value: shouldShowScrollToBottomButton)
            .onAppear {
                if autoScrollOnAppear {
                    // Scroll to the bottom immediately with no animation
                    scrollToBottom(proxy, true, false)
                }
            }
            .task(id: sessionIDOverride) {
                guard let sessionIDOverride else {
                    loadingSessionID = nil
                    releasePinnedOverrideSession()
                    return
                }
                pinOverrideSession(sessionIDOverride)
                loadingSessionID = sessionIDOverride
                _ = await viewModel.ensureSessionMessagesLoaded(sessionIDOverride)
                if loadingSessionID == sessionIDOverride {
                    loadingSessionID = nil
                }
            }
            .onDisappear {
                loadingSessionID = nil
                releasePinnedOverrideSession()
            }
            .onChange(of: bottomOcclusion) { _, _ in
                guard autoScrollEnabled else { return }
                scrollToBottom(proxy, true, false)
            }

            // Whenever the message list changes, if auto-scroll is enabled, scroll down.
            .onChange(of: renderedMessages) { _, _ in
                if autoScrollEnabled || didChatChange {
                    scrollToBottom(proxy, didChatChange, !didChatChange) // no animation on restore
                    didChatChange = false
                }
            }

            // When AI response starts => refresh & optionally scroll down,
            // When AI finishes => disable auto-scroll.
            .onChange(of: isRenderedSessionStreaming) { _, isInProgress in
                if isInProgress {
                    setAutoScrollEnabled(true)
                    scrollToBottom(proxy, false)
                } else {
                    setAutoScrollEnabled(false)
                }
            }

            // If the session changes, we reset layout, re-enable auto-scroll (if allowed), and scroll down.
            .onChange(of: renderedSessionID) { _, _ in
                didChatChange = true
                refreshToken = UUID() // force view refresh
                if isRenderedSessionStreaming {
                    setAutoScrollEnabled(true)
                }
            }
        }
    }

    // MARK: - Versioned Scrollable Content

    /// Uses `.onScrollPhaseChange` on macOS 15+ to detect manual scrolling.
    @ViewBuilder
    private func versionedScrollableContent(proxy: ScrollViewProxy) -> some View {
        if #available(macOS 15.0, *) {
            ScrollView {
                messageListContent
            }
            .id(refreshToken)
            .transaction { txn in
                if didChatChange {
                    txn.disablesAnimations = true
                }
            }
            .onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting {
                    // User manually scrolled => disable auto-scroll
                    setAutoScrollEnabled(false)
                }
            }
        } else {
            // For older macOS, we just present the scroll view without auto-scroll functionality.
            ScrollView {
                messageListContent
            }
            .id(refreshToken)
            .transaction { txn in
                if didChatChange {
                    txn.disablesAnimations = true
                }
            }
        }
    }

    /// The core message list, shared by both macOS 15+ and older code paths.
    private var messageListContent: some View {
        messagesStack()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func messagesStack() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            topSentinel
            ForEach(renderedMessages) { message in
                MessageBubble(
                    message: message,
                    viewModel: viewModel,
                    isLatestMessage: message.id == renderedMessages.last?.id
                )
                .id(message.id)
                .animation(.default, value: message.revisionCount)
            }
            bottomTarget
            versionedBottomSentinel
        }
    }

    private var topSentinel: some View {
        Color.clear.frame(height: 1).id("topSentinel")
    }

    private var bottomTarget: some View {
        Color.clear
            .frame(height: max(1, bottomOcclusion))
            .id("bottomTarget")
    }

    // MARK: - Versioned Bottom Sentinel

    /// Tracks proximity to bottom. Uses `.onScrollVisibilityChange` on macOS 15+; else fallback.
    @ViewBuilder
    private var versionedBottomSentinel: some View {
        if #available(macOS 15.0, *) {
            Color.clear
                .frame(height: 1)
                .id("bottomSentinel")
                .onScrollVisibilityChange { visible in
                    isNearBottom = visible
                }
        } else {
            Color.clear
                .frame(height: 1)
                .id("bottomSentinel")
                .onAppear {
                    isNearBottom = true
                }
                .onDisappear {
                    isNearBottom = false
                }
        }
    }

    // MARK: - Button Logic

    /// Whether to show the bottom button at all.
    private var shouldShowScrollToBottomButton: Bool {
        !isNearBottom
    }

    @ViewBuilder
    private func sessionSwitchOverlay(for sessionID: UUID) -> some View {
        let sessionName = viewModel.sessions.first(where: { $0.id == sessionID })?.name ?? "chat"
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Opening \"\(sessionName)\"…")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
        .transition(.opacity)
    }

    // MARK: - Actions

    private func pinOverrideSession(_ sessionID: UUID) {
        guard pinnedOverrideSessionID != sessionID else { return }
        releasePinnedOverrideSession()
        viewModel.pinSession(sessionID)
        pinnedOverrideSessionID = sessionID
    }

    private func releasePinnedOverrideSession() {
        guard let pinnedOverrideSessionID else { return }
        viewModel.unpinSession(pinnedOverrideSessionID)
        self.pinnedOverrideSessionID = nil
    }

    /// Scrolls to the "bottomTarget" with an animation.
    private func scrollToBottom(_ proxy: ScrollViewProxy, _ didChange: Bool, _ animate: Bool = true) {
        // Cancel any pending scroll work.
        scrollDebounceWorkItem?.cancel()
        scrollWorkGate.cancel()

        let delay = didChange ? 0 : 0.2

        // Schedule the scroll call with a short delay.
        if animate {
            scrollDebounceWorkItem = scrollWorkGate.schedule(after: delay) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottomSentinel", anchor: .bottom)
                }
            }
        } else {
            scrollDebounceWorkItem = scrollWorkGate.schedule(after: delay) {
                proxy.scrollTo("bottomSentinel", anchor: .bottom)
            }
        }
    }

    /// Handles taps on the bottom button, scrolling to bottom and enabling auto-scroll.
    private func handleBottomButtonTap(proxy: ScrollViewProxy) {
        scrollToBottom(proxy, true)
        setAutoScrollEnabled(true)
    }

    /// Prevents `autoScrollEnabled` from being set to `true` on older macOS versions.
    private func setAutoScrollEnabled(_ newValue: Bool) {
        if supportsAutoScroll {
            autoScrollEnabled = newValue && isRenderedSessionStreaming
        } else {
            autoScrollEnabled = false
        }
    }
}
