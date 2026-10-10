#if DEBUG
    import AppKit
    import QuartzCore
    import SwiftUI

    // MARK: - Reading Position

    /// Pure reading-position telemetry for the stress harness.
    ///
    /// While the user reads detached history, the block at the top of the viewport (the
    /// "anchor") should not move unless the user scrolls. Every measured anchor movement of more
    /// than `shiftThresholdPoints` without user input or programmatic scrolling is counted as a
    /// position shift. Block frames are viewport-relative (`.scrollView` coordinate space), so
    /// `minY` is the block top's distance from the viewport top.
    struct AgentChatStressReadingPositionTracker: Equatable {
        struct Context: Equatable {
            /// User detached from the live bottom (not following).
            var isDetachedReading: Bool
            /// A user scroll gesture or its momentum is in progress.
            var hasUserScrollInput: Bool
            /// A programmatic scroll or restore is moving the viewport.
            var isProgrammaticScrollInFlight: Bool

            /// Reading with nothing that legitimately moves the viewport.
            var isSteadyReading: Bool {
                isDetachedReading && !hasUserScrollInput && !isProgrammaticScrollInFlight
            }
        }

        static let shiftThresholdPoints: CGFloat = 1

        private(set) var anchorBlockID: String?
        private(set) var anchorMinY: CGFloat?
        private(set) var positionShiftWhileReadingCount = 0
        private(set) var maxPositionShiftWhileReading: CGFloat = 0

        /// Records a block's measured viewport-relative top. Returns the shift magnitude when the
        /// reading anchor moved by more than the threshold during steady reading.
        @discardableResult
        mutating func recordFrame(blockID: String, minY: CGFloat, context: Context) -> CGFloat? {
            guard blockID == anchorBlockID else { return nil }
            let previousMinY = anchorMinY
            anchorMinY = minY
            guard context.isSteadyReading, let previousMinY else { return nil }
            let shift = abs(minY - previousMinY)
            guard shift > Self.shiftThresholdPoints else { return nil }
            positionShiftWhileReadingCount += 1
            maxPositionShiftWhileReading = max(maxPositionShiftWhileReading, shift)
            return shift
        }

        /// Keeps the current anchor during steady reading while it is still on screen; otherwise
        /// re-anchors to the top-visible block (smallest `minY` among blocks whose bottom is below
        /// the viewport top).
        mutating func refreshAnchor(frames: [String: CGRect], context: Context) {
            if context.isSteadyReading,
               let anchorBlockID,
               let anchorFrame = frames[anchorBlockID],
               anchorFrame.maxY > 0
            {
                return
            }
            var bestID: String?
            var bestMinY = CGFloat.greatestFiniteMagnitude
            for (blockID, frame) in frames where frame.maxY > 0 {
                if frame.minY < bestMinY || (frame.minY == bestMinY && blockID < (bestID ?? blockID)) {
                    bestID = blockID
                    bestMinY = frame.minY
                }
            }
            anchorBlockID = bestID
            anchorMinY = bestID == nil ? nil : bestMinY
        }

        mutating func reset() {
            self = AgentChatStressReadingPositionTracker()
        }
    }

    /// Collects per-block frames reported by `AgentChatStressReadingProbeModifier` and feeds the
    /// pure tracker. Not observable: mutations never invalidate SwiftUI views.
    @MainActor
    final class AgentChatStressReadingProbe {
        private(set) var tracker = AgentChatStressReadingPositionTracker()
        private var framesByBlockID: [String: CGRect] = [:]

        func recordFrame(
            blockID: String,
            frame: CGRect,
            context: AgentChatStressReadingPositionTracker.Context
        ) -> CGFloat? {
            framesByBlockID[blockID] = frame
            return tracker.recordFrame(blockID: blockID, minY: frame.minY, context: context)
        }

        func refreshAnchor(context: AgentChatStressReadingPositionTracker.Context) {
            tracker.refreshAnchor(frames: framesByBlockID, context: context)
        }

        /// Drops frames for blocks that are no longer rendered.
        func retainFrames(for blockIDs: Set<String>) {
            framesByBlockID = framesByBlockID.filter { blockIDs.contains($0.key) }
        }

        func reset() {
            tracker.reset()
            framesByBlockID.removeAll()
        }
    }

    /// Reports a transcript block's viewport-relative frame to the stress reading probe.
    struct AgentChatStressReadingProbeModifier: ViewModifier {
        let isEnabled: Bool
        let blockID: String
        let onFrameChange: (String, CGRect) -> Void

        func body(content: Content) -> some View {
            if isEnabled {
                content.onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .scrollView)
                } action: { frame in
                    onFrameChange(blockID, frame)
                }
            } else {
                content
            }
        }
    }

    // MARK: - Frame Intervals

    /// Fixed-capacity ring buffer of display frame intervals with nearest-rank percentiles.
    struct AgentChatStressFrameIntervalRecorder: Equatable {
        struct Summary: Equatable {
            let sampleCount: Int
            let p50MS: Double
            let p95MS: Double
            let p99MS: Double
        }

        let capacity: Int
        private var intervalsMS: [Double] = []
        private var nextWriteIndex = 0
        private var lastTimestamp: CFTimeInterval?

        init(capacity: Int = 1024) {
            self.capacity = max(1, capacity)
            intervalsMS.reserveCapacity(self.capacity)
        }

        var sampleCount: Int {
            intervalsMS.count
        }

        /// Records a display frame timestamp (seconds). The first frame after a break only
        /// establishes the baseline.
        mutating func recordFrame(at timestamp: CFTimeInterval) {
            defer { lastTimestamp = timestamp }
            guard let lastTimestamp, timestamp > lastTimestamp else { return }
            append((timestamp - lastTimestamp) * 1000)
        }

        /// Forgets the previous timestamp so a pause in collection is not recorded as one long frame.
        mutating func breakSequence() {
            lastTimestamp = nil
        }

        mutating func reset() {
            intervalsMS.removeAll(keepingCapacity: true)
            nextWriteIndex = 0
            lastTimestamp = nil
        }

        func summary() -> Summary? {
            guard !intervalsMS.isEmpty else { return nil }
            let sorted = intervalsMS.sorted()
            return Summary(
                sampleCount: sorted.count,
                p50MS: Self.percentile(50, ofSorted: sorted),
                p95MS: Self.percentile(95, ofSorted: sorted),
                p99MS: Self.percentile(99, ofSorted: sorted)
            )
        }

        /// Nearest-rank percentile of an ascending, non-empty array.
        static func percentile(_ percentile: Double, ofSorted sorted: [Double]) -> Double {
            precondition(!sorted.isEmpty)
            let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up))
            return sorted[min(sorted.count - 1, max(0, rank - 1))]
        }

        private mutating func append(_ intervalMS: Double) {
            if intervalsMS.count < capacity {
                intervalsMS.append(intervalMS)
            } else {
                intervalsMS[nextWriteIndex] = intervalMS
            }
            nextWriteIndex = (nextWriteIndex + 1) % capacity
        }
    }

    /// Samples display frame intervals while the transcript streams. Fed by
    /// `AgentChatStressFrameProbeView`; collection is toggled by the transcript view.
    @MainActor
    final class AgentChatStressFrameIntervalSampler {
        private static let summaryRefreshInterval: TimeInterval = 0.25

        private var recorder = AgentChatStressFrameIntervalRecorder()
        private(set) var isCollecting = false
        private var cachedSummary: AgentChatStressFrameIntervalRecorder.Summary?
        private var cachedSummaryAt: Date?

        func setCollecting(_ collecting: Bool) {
            guard collecting != isCollecting else { return }
            isCollecting = collecting
            recorder.breakSequence()
        }

        func recordDisplayFrame(timestamp: CFTimeInterval) {
            guard isCollecting else { return }
            recorder.recordFrame(at: timestamp)
        }

        /// Percentile summary, recomputed at most every `summaryRefreshInterval`.
        func currentSummary(now: Date = Date()) -> AgentChatStressFrameIntervalRecorder.Summary? {
            if let cachedSummaryAt, now.timeIntervalSince(cachedSummaryAt) < Self.summaryRefreshInterval {
                return cachedSummary
            }
            cachedSummary = recorder.summary()
            cachedSummaryAt = now
            return cachedSummary
        }

        func reset() {
            recorder.reset()
            isCollecting = false
            cachedSummary = nil
            cachedSummaryAt = nil
        }
    }

    /// Zero-size view that drives an `NSView` display link and feeds frame timestamps to the
    /// sampler. Only mounted when the stress harness is active.
    struct AgentChatStressFrameProbeView: NSViewRepresentable {
        let sampler: AgentChatStressFrameIntervalSampler

        func makeNSView(context _: Context) -> AgentChatStressFrameProbeNSView {
            AgentChatStressFrameProbeNSView(sampler: sampler)
        }

        func updateNSView(_ nsView: AgentChatStressFrameProbeNSView, context _: Context) {
            nsView.sampler = sampler
        }
    }

    final class AgentChatStressFrameProbeNSView: NSView {
        var sampler: AgentChatStressFrameIntervalSampler
        private var displayLink: CADisplayLink?

        init(sampler: AgentChatStressFrameIntervalSampler) {
            self.sampler = sampler
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil else { return }
            let link = displayLink(target: self, selector: #selector(handleDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func handleDisplayLink(_ link: CADisplayLink) {
            sampler.recordDisplayFrame(timestamp: link.timestamp)
        }
    }
#endif
