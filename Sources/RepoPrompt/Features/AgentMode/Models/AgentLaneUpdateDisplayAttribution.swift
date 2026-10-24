import Foundation
import RepoPromptDomainRuntime

// MARK: - Lane-update display attribution

/// Bounded, **local-display-only** provenance for one accepted automatic lane-update turn.
///
/// It answers one question for the person reading their own transcript: which overseen lanes did
/// RepoPrompt actually deliver an update for when it woke this session? Lane identity, order, and
/// task labels come exclusively from the immutable `RenderedPassiveBatch.entries` of the accepted
/// claim. An optional UI location prefix is joined by exact generation-qualified reference from a
/// synchronous claim-time snapshot. The result therefore describes the lanes whose entries were
/// *delivered* — including snoozed and unselected hitchhikers that rode along on someone else's wake
/// — rather than the lane that happened to cause admission.
///
/// It is deliberately **not** authority data and deliberately **not** part of the provider contract:
///
/// - The row's raw `.system` text stays exactly `canonicalSystemText`, so provider replay,
///   cross-session reads, exports, sync projections, and telemetry keep saying the generic thing.
///   Every one of those projections selects `text` explicitly, which is what keeps this field local.
/// - No UUID, link reference, endpoint identity, target preview, path, provider, waiting reason,
///   readiness bit, timestamp, or admission-cause information is retained. Only at most two
///   already-capped display labels, each with the coarse claim-time status change of the rendered
///   entry it names, a distinct lane count, and one overflow Boolean.
/// - Task and UI location labels are untrusted target-derived data. They are sanitized here against
///   format and bidi controls. A location is prefixed only when the complete compound label fits the
///   `DomainAgentSessionLinkTextBudget`; otherwise the identifying task survives unchanged. Labels
///   are rendered verbatim rather than through Markdown.
///
/// Decoding is a **lossy validation boundary**: a malformed payload decodes to an invalid
/// representation rather than throwing, because a bad nested blob must never fail the enclosing
/// transcript item. Every item/persist/activity boundary converts an invalid value to `nil`, and
/// the formatter validates independently before presenting anything.
public struct AgentLaneUpdateDisplayAttribution: Codable, Sendable, Equatable, Hashable {
    /// Two labels plus fixed grammar is a bounded row. A third would start growing with the batch.
    public static let maximumLabelCount = 2

    /// At most two unique sanitized labels, in first rendered occurrence order.
    public let labels: [String]

    /// Count of distinct rendered lane references, including the ones no label survived for.
    public let attributedLaneCount: Int

    /// Whether the rendered envelope also disclosed dropped changes with no retained attribution.
    public let includesUnattributedOverflow: Bool

    /// The claim-time status change of the rendered entry each label names, index-aligned with
    /// `labels`.
    ///
    /// Optional because rows written before this field existed carry only labels, and because a
    /// malformed or misaligned array degrades to exactly that labels-only form rather than taking the
    /// labels down with it. Only the coarse enum pair is kept: never a preview, a waiting reason, a
    /// readiness bit, or an observation time.
    public let labelStatusChanges: [LaneStatusChange]?

    /// Unvalidated storage. Private on purpose: every producer goes through `make(...)`, and every
    /// consumer goes through `validated`, so an invalid value can only originate from decoding.
    private init(
        unchecked labels: [String],
        attributedLaneCount: Int,
        includesUnattributedOverflow: Bool,
        labelStatusChanges: [LaneStatusChange]? = nil
    ) {
        self.labels = labels
        self.attributedLaneCount = attributedLaneCount
        self.includesUnattributedOverflow = includesUnattributedOverflow
        self.labelStatusChanges = labelStatusChanges
    }

    /// The representation a malformed payload decodes to.
    ///
    /// A negative count rather than a side-channel flag: it fails `isValid` by construction, it can
    /// never collide with anything `make(...)` produces, and it keeps `Equatable`/`Hashable`
    /// synthesized from the three real fields.
    private static let invalid = AgentLaneUpdateDisplayAttribution(
        unchecked: [],
        attributedLaneCount: -1,
        includesUnattributedOverflow: false
    )

    // MARK: Validation

    /// Whether this value is presentable and safe to re-encode.
    ///
    /// Checked against `AgentSessionLinkPassiveStatusNotices.maximumPendingTargetCount` rather than
    /// a duplicated literal: the reducer's attributed-lane bound is the only thing that decides how
    /// many distinct references a rendered batch can contain, and a copied `16` would silently stop
    /// agreeing with it.
    public var isValid: Bool {
        guard labels.count <= Self.maximumLabelCount else { return false }
        guard Set(labels).count == labels.count else { return false }
        guard labels.allSatisfy({ !$0.isEmpty }) else { return false }
        guard labels.allSatisfy({ Self.sanitizedLabel($0) == $0 }) else { return false }
        guard (0 ... AgentSessionLinkPassiveStatusNotices.maximumPendingTargetCount)
            .contains(attributedLaneCount)
        else {
            return false
        }
        guard labels.count <= attributedLaneCount else { return false }
        guard attributedLaneCount > 0 || labels.isEmpty else { return false }
        if let labelStatusChanges, labelStatusChanges.count != labels.count { return false }
        // Metadata that claims neither a lane nor an omission describes nothing at all.
        return attributedLaneCount > 0 || includesUnattributedOverflow
    }

    /// This value if it is presentable, otherwise `nil`.
    ///
    /// The single conversion every item, persisted DTO, transcript activity, and formatter applies,
    /// so malformed metadata is dropped exactly once per boundary instead of being re-checked ad hoc.
    public var validated: AgentLaneUpdateDisplayAttribution? {
        isValid ? self : nil
    }

    // MARK: Construction

    /// Builds display attribution from the exact entries one render put in front of the model.
    ///
    /// `renderedEntries` must be `AgentSessionLinkPromptRenderResult.RenderedPassiveBatch.entries`
    /// and nothing else. `locationLabelsByReference` may contain only the exact observer endpoint's
    /// UI projection synchronously captured while this claim is reserved. Live links, current
    /// selection, current snooze state, and any post-claim target lookup are all mutable and would
    /// let a rename, unlink, or rebind rewrite what a delivered turn claimed to have delivered.
    ///
    /// Returns `nil` when the invariants do not hold, which leaves the generic raw row standing
    /// rather than clamping the batch into misleading metadata.
    static func make(
        renderedEntries: [AgentSessionLinkPassiveStatusNotices.PendingEntry],
        includesUnattributedOverflow: Bool,
        locationLabelsByReference: [DomainAgentSessionLinkReference: String] = [:]
    ) -> AgentLaneUpdateDisplayAttribution? {
        // Defensive dedupe by exact generation-qualified reference, first occurrence wins. The
        // reducer keys its pending table by reference and cannot produce a duplicate, so this is a
        // guard against a future renderer, not a known case.
        var seenReferences = Set<DomainAgentSessionLinkReference>()
        var distinctEntries: [AgentSessionLinkPassiveStatusNotices.PendingEntry] = []
        for entry in renderedEntries where seenReferences.insert(entry.reference).inserted {
            distinctEntries.append(entry)
        }

        guard (0 ... AgentSessionLinkPassiveStatusNotices.maximumPendingTargetCount)
            .contains(distinctEntries.count)
        else {
            return nil
        }

        var labels: [String] = []
        var statusChanges: [LaneStatusChange] = []
        for entry in distinctEntries {
            guard labels.count < maximumLabelCount else { break }
            // An unnamed lane, or one whose whole name was invisible scalars, is counted but not
            // named. It reappears in the sentence as "other overseen lane", never as an invention.
            guard let taskLabel = sanitizedLabel(entry.displayName) else { continue }
            let label = displayLabel(
                taskLabel: taskLabel,
                locationLabel: locationLabelsByReference[entry.reference]
            )
            guard !labels.contains(label) else { continue }
            labels.append(label)
            // The same immutable rendered entry that supplied the label supplies its status, so a
            // named lane can never be paired with another lane's change.
            statusChanges.append(LaneStatusChange(entry))
        }

        return AgentLaneUpdateDisplayAttribution(
            unchecked: labels,
            attributedLaneCount: distinctEntries.count,
            includesUnattributedOverflow: includesUnattributedOverflow,
            labelStatusChanges: statusChanges
        ).validated
    }

    // MARK: Label sanitization

    /// Prefixes a surviving task with its exact claim-time UI location only when the complete pair
    /// fits the existing label byte budget. A missing, invalid, or oversized location degrades to the
    /// task-only label so the identifying half is never truncated or erased by presentation context.
    private static func displayLabel(taskLabel: String, locationLabel: String?) -> String {
        guard let locationLabel = sanitizedLabel(locationLabel) else { return taskLabel }
        let combined = "\(locationLabel): \(taskLabel)"
        guard combined.utf8.count <= DomainAgentSessionLinkTextBudget.displayNameMaxBytes,
              let sanitizedCombined = sanitizedLabel(combined)
        else {
            return taskLabel
        }
        return sanitizedCombined
    }

    /// The narrow defense added on top of the existing display-name normalization.
    ///
    /// `DomainAgentSessionLinkTextBudget.normalized` already collapses whitespace and `Cc` control
    /// characters and caps the result at `displayNameMaxBytes`; it is authoritative and is applied
    /// again after this pass so the cap is never widened. What it does not remove is category `Cf`
    /// — zero-width joiners, soft hyphens, byte-order marks — and the bidi embedding, override, and
    /// isolate scalars, which can reorder a rendered line so a label reads as something it is not.
    ///
    /// It also folds the two curly double quotes to ASCII. The sentence wraps every label in `“ ”`,
    /// so a name is otherwise free to close the span the grammar opened: a target called
    /// `Build” and 9 other overseen lanes` would render as trusted RepoPrompt prose. Folding rather
    /// than stripping keeps the name legible while leaving exactly one thing that can end a quoted
    /// span — the grammar's own delimiter.
    ///
    /// Deliberately no second per-label byte cap and no whole-row cap: two already-capped labels
    /// plus fixed grammar is bounded, and a second budget would only add a way for the two to
    /// disagree.
    static func sanitizedLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where !isStrippedScalar(scalar) {
            scalars.append(isQuoteDelimiter(scalar) ? foldedQuote : scalar)
        }
        return DomainAgentSessionLinkTextBudget.normalized(
            String(scalars),
            maxBytes: DomainAgentSessionLinkTextBudget.displayNameMaxBytes
        )
    }

    private static func isStrippedScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .format || scalar.properties.isBidiControl
    }

    /// Exactly the pair `quoted(_:)` wraps labels in, and nothing else: an ASCII quote inside a label
    /// is harmless, so folding more would only mangle names for no gain.
    private static func isQuoteDelimiter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{201C}" || scalar == "\u{201D}"
    }

    private static let foldedQuote: Unicode.Scalar = "\u{22}"

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case labels
        case attributedLaneCount
        case includesUnattributedOverflow
        case labelStatusChanges
    }

    /// Never throws. A malformed container, a malformed field type, or a missing required field
    /// yields `invalid`, which every boundary then drops — the enclosing transcript item survives.
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self = Self.invalid
            return
        }
        guard let labels = try? container.decodeIfPresent([String].self, forKey: .labels),
              let attributedLaneCount = try? container.decodeIfPresent(
                  Int.self,
                  forKey: .attributedLaneCount
              )
        else {
            self = Self.invalid
            return
        }
        // A malformed overflow flag degrades to "no omission disclosed" instead of invalidating the
        // whole value: the lane count and labels are still exactly what was delivered.
        let overflow = try? container.decodeIfPresent(
            Bool.self,
            forKey: .includesUnattributedOverflow
        )
        // Statuses are decoration on labels that are already exact. A legacy row has none, and an
        // unknown status word or an array that no longer lines up with the labels degrades to the
        // labels-only form rather than pairing a lane with a status it may not have had.
        var statusChanges = (try? container.decodeIfPresent(
            [LaneStatusChange].self,
            forKey: .labelStatusChanges
        )) ?? nil
        if let decoded = statusChanges, decoded.count != labels.count {
            statusChanges = nil
        }
        self.init(
            unchecked: labels,
            attributedLaneCount: attributedLaneCount,
            includesUnattributedOverflow: overflow ?? false,
            labelStatusChanges: statusChanges
        )
    }

    /// Invalid metadata encodes as an empty object rather than being written back out.
    ///
    /// A carrier that holds an activity wholesale would otherwise resave whatever malformed labels
    /// it decoded. The empty object decodes back to `invalid` on the next load, so the value stays
    /// dropped instead of oscillating.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        guard isValid else { return }
        try container.encode(labels, forKey: .labels)
        try container.encode(attributedLaneCount, forKey: .attributedLaneCount)
        try container.encode(includesUnattributedOverflow, forKey: .includesUnattributedOverflow)
        try container.encodeIfPresent(labelStatusChanges, forKey: .labelStatusChanges)
    }
}

// MARK: - Claim-time lane status

public extension AgentLaneUpdateDisplayAttribution {
    /// A lane's coarse status, mirrored from the passive reducer's vocabulary so the persisted form
    /// does not depend on an internal runtime type.
    enum LaneStatus: String, Codable, Sendable, Hashable, CaseIterable {
        case idle
        case running
        case waiting
        case unavailable

        /// What the lane is doing now, phrased as an observation.
        ///
        /// Idle is deliberately just idle: RepoPrompt observed that the target stopped, not that its
        /// work succeeded, so no phrase may read as done, finished, or complete.
        public var currentStatePhrase: String {
            switch self {
            case .idle: "now idle"
            case .running: "now running"
            case .waiting: "waiting for input"
            case .unavailable: "now unavailable"
            }
        }

        /// Title-case state name for the hover detail. `waiting` is the monitor's awaiting-user
        /// state, so it is spelled out as waiting for input rather than left ambiguous.
        public var title: String {
            switch self {
            case .idle: "Idle"
            case .running: "Running"
            case .waiting: "Waiting for input"
            case .unavailable: "Unavailable"
            }
        }
    }

    /// The first-to-final status interval the rendered entry carried when this turn was claimed.
    struct LaneStatusChange: Codable, Sendable, Equatable, Hashable {
        public let from: LaneStatus
        public let to: LaneStatus

        public init(from: LaneStatus, to: LaneStatus) {
            self.from = from
            self.to = to
        }

        /// Hover detail; never shown as the primary status.
        public var changeDescription: String {
            "Changed from \(from.title) to \(to.title)"
        }
    }
}

extension AgentLaneUpdateDisplayAttribution.LaneStatus {
    /// Exhaustive so a new reducer status has to be classified here rather than silently narrated.
    init(_ status: AgentSessionLinkPassiveStatusNotices.Status) {
        switch status {
        case .idle: self = .idle
        case .running: self = .running
        case .waiting: self = .waiting
        case .unavailable: self = .unavailable
        }
    }
}

extension AgentLaneUpdateDisplayAttribution.LaneStatusChange {
    init(_ entry: AgentSessionLinkPassiveStatusNotices.PendingEntry) {
        self.init(from: .init(entry.fromStatus), to: .init(entry.toStatus))
    }
}

// MARK: - Deterministic local presentation

public extension AgentLaneUpdateDisplayAttribution {
    /// The exact raw text of every accepted lane-update row, in every build, forever.
    ///
    /// Rich display keys off this string being present verbatim, so a row whose text was rewritten,
    /// summarized, or restored from a differently worded build falls back to showing its own text.
    /// It is also what provider replay and every cross-session projection keep emitting.
    static let canonicalSystemText =
        "[lane-update] RepoPrompt auto-woke this session for overseen-session status updates."

    /// Appended verbatim when a batch carried both attributed lanes and dropped changes.
    static let unattributedOverflowSentence =
        "The batch also included status changes without retained lane attribution."

    /// The sentence to display for one transcript row, or `nil` to display the row's own text.
    ///
    /// Returns `nil` — meaning "render the generic raw row" — for a non-system row, a row whose text
    /// is not the canonical marker, absent or malformed metadata, and the overflow-only case, where
    /// there is no lane to name and the generic sentence is already the whole truth.
    static func richDisplayText(for item: AgentChatItem) -> String? {
        guard item.kind == .system else { return nil }
        return richDisplayText(
            rawText: item.text,
            attribution: item.laneUpdateDisplayAttribution
        )
    }

    static func richDisplayText(
        rawText: String,
        attribution: AgentLaneUpdateDisplayAttribution?
    ) -> String? {
        guard rawText == canonicalSystemText else { return nil }
        guard let attribution = attribution?.validated else { return nil }
        guard attribution.attributedLaneCount > 0 else { return nil }
        var sentence = attribution.deliverySentence
        if attribution.includesUnattributedOverflow {
            sentence += " " + unattributedOverflowSentence
        }
        return sentence
    }
}

// MARK: - Structured row presentation

extension AgentLaneUpdateDisplayAttribution {
    /// The scannable local row for one canonical lane-update item: a fixed system header, one line per
    /// named lane with its claim-time status, a truthful `+N more` tail, and the overflow disclosure.
    ///
    /// Every field is derived from the same validated claim-time metadata as `richDisplayText`. The
    /// accessibility reading is computed from these fields rather than stored, so what VoiceOver hears
    /// can never drift from what the row shows.
    struct RowPresentation: Equatable {
        struct Lane: Equatable {
            /// Sanitized, target-derived text. Rendered verbatim, never through Markdown.
            let label: String
            /// `nil` for rows written before statuses were captured.
            let statusChange: LaneStatusChange?

            /// Wrapped in the grammar's own delimiters, which sanitization guarantees a label cannot
            /// contain, so a name can never appear to end early and continue as RepoPrompt prose.
            var quotedLabel: String {
                AgentLaneUpdateDisplayAttribution.quoted(label)
            }
        }

        static let title = "Lane update"

        /// One line under the header: who woke the session and, when known, for how many lanes.
        let summary: String
        let lanes: [Lane]
        /// Delivered lanes not listed by name. Zero whenever `lanes` is empty, because the summary
        /// already states the whole count and a bare `+N` would read as additional to nothing.
        let additionalLaneCount: Int
        let overflowNote: String?

        var additionalLanesText: String? {
            guard additionalLaneCount > 0 else { return nil }
            return additionalLaneCount == 1
                ? "+1 more overseen lane"
                : "+\(additionalLaneCount) more overseen lanes"
        }

        /// The whole event as VoiceOver should hear it: no raw `[lane-update]` marker, and each named
        /// lane's full claim-time transition, which sighted users otherwise only get on hover.
        ///
        /// Transitions are phrased in the past tense ("changed from Running to Idle") rather than
        /// with the visible row's "now idle", because a spoken row has no adjacent timestamp to anchor
        /// "now" and an old transcript must not sound like it describes the lane's current state.
        var accessibilityLabel: String {
            var sentences = ["\(Self.title).", summary]
            for lane in lanes {
                if let change = lane.statusChange {
                    sentences.append(
                        "\(lane.quotedLabel) changed from \(change.from.title) to \(change.to.title)."
                    )
                } else {
                    sentences.append("\(lane.quotedLabel), status not recorded.")
                }
            }
            if additionalLaneCount > 0 {
                sentences.append(
                    additionalLaneCount == 1
                        ? "Plus 1 more overseen lane."
                        : "Plus \(additionalLaneCount) more overseen lanes."
                )
            }
            if let overflowNote {
                sentences.append(overflowNote)
            }
            return sentences.joined(separator: " ")
        }

        /// The accessibility value carrying when the update was delivered, given the row's
        /// already-formatted timestamp.
        static func accessibilityDeliveryValue(timestamp: String) -> String {
            "Delivered \(timestamp)"
        }
    }

    /// The generic body shown when a canonical row has no presentable lane metadata.
    static let genericRowSummary =
        "RepoPrompt auto-woke this session for overseen-session status updates."

    /// The structured row for a canonical lane-update item, or `nil` for every other row.
    ///
    /// Keyed off the exact canonical raw text, so only rows this feature wrote are restyled. Legacy,
    /// malformed, and overflow-only metadata still get the system row styling, with the generic body
    /// that was already the whole truth for them.
    static func rowPresentation(for item: AgentChatItem) -> RowPresentation? {
        guard item.kind == .system else { return nil }
        return rowPresentation(rawText: item.text, attribution: item.laneUpdateDisplayAttribution)
    }

    static func rowPresentation(
        rawText: String,
        attribution: AgentLaneUpdateDisplayAttribution?
    ) -> RowPresentation? {
        guard rawText == canonicalSystemText else { return nil }
        guard let attribution = attribution?.validated,
              attribution.attributedLaneCount > 0
        else {
            return RowPresentation(
                summary: genericRowSummary,
                lanes: [],
                additionalLaneCount: 0,
                overflowNote: nil
            )
        }
        let lanes = attribution.labels.enumerated().map { index, label in
            RowPresentation.Lane(
                label: label,
                statusChange: attribution.labelStatusChanges?[index]
            )
        }
        let count = attribution.attributedLaneCount
        return RowPresentation(
            summary: count == 1
                ? "RepoPrompt auto-woke this session for 1 overseen lane."
                : "RepoPrompt auto-woke this session for \(count) overseen lanes.",
            lanes: lanes,
            additionalLaneCount: lanes.isEmpty ? 0 : count - lanes.count,
            overflowNote: attribution.includesUnattributedOverflow
                ? unattributedOverflowSentence
                : nil
        )
    }
}

private extension AgentLaneUpdateDisplayAttribution {
    static let sentenceOpening = "[lane-update] RepoPrompt auto-woke this session and delivered"

    /// The base grammar. Duplicate labels and unnamed lanes are absorbed into the "other overseen
    /// lane(s)" tail rather than repeated or invented, so the count is always truthful and the
    /// sentence never grows with the batch.
    var deliverySentence: String {
        let additional = attributedLaneCount - labels.count
        switch labels.count {
        case 0:
            return attributedLaneCount == 1
                ? "\(Self.sentenceOpening) an update for an overseen lane."
                : "\(Self.sentenceOpening) updates for \(attributedLaneCount) overseen lanes."
        case 1:
            let first = describedLabel(at: 0)
            guard additional > 0 else {
                return "\(Self.sentenceOpening) an update for overseen lane \(first)."
            }
            return "\(Self.sentenceOpening) updates for overseen lane \(first) and \(Self.otherLanePhrase(additional))."
        default:
            let first = describedLabel(at: 0)
            let second = describedLabel(at: 1)
            guard additional > 0 else {
                return "\(Self.sentenceOpening) updates for overseen lanes \(first) and \(second)."
            }
            return "\(Self.sentenceOpening) updates for overseen lanes \(first), \(second), and \(Self.otherLanePhrase(additional))."
        }
    }

    /// A quoted label followed, when captured, by its claim-time state in parentheses. The status is
    /// outside the quotes so it always reads as RepoPrompt's observation rather than part of a name.
    func describedLabel(at index: Int) -> String {
        let quotedLabel = Self.quoted(labels[index])
        guard let change = labelStatusChanges?[index] else { return quotedLabel }
        return "\(quotedLabel) (\(change.to.currentStatePhrase))"
    }

    static func otherLanePhrase(_ count: Int) -> String {
        count == 1 ? "1 other overseen lane" : "\(count) other overseen lanes"
    }

    /// Typographic quotes so a label containing an ASCII quote cannot look like it closed the span.
    static func quoted(_ label: String) -> String {
        "\u{201C}\(label)\u{201D}"
    }
}
