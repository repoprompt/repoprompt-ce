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
/// - No UUID, link reference, endpoint identity, target preview, path, provider, status payload, or
///   admission-cause information is retained. Only at most two already-capped display labels, a
///   distinct lane count, and one overflow Boolean.
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

    /// Unvalidated storage. Private on purpose: every producer goes through `make(...)`, and every
    /// consumer goes through `validated`, so an invalid value can only originate from decoding.
    private init(
        unchecked labels: [String],
        attributedLaneCount: Int,
        includesUnattributedOverflow: Bool
    ) {
        self.labels = labels
        self.attributedLaneCount = attributedLaneCount
        self.includesUnattributedOverflow = includesUnattributedOverflow
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
        }

        return AgentLaneUpdateDisplayAttribution(
            unchecked: labels,
            attributedLaneCount: distinctEntries.count,
            includesUnattributedOverflow: includesUnattributedOverflow
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
        self.init(
            unchecked: labels,
            attributedLaneCount: attributedLaneCount,
            includesUnattributedOverflow: overflow ?? false
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
            let first = Self.quoted(labels[0])
            guard additional > 0 else {
                return "\(Self.sentenceOpening) an update for overseen lane \(first)."
            }
            return "\(Self.sentenceOpening) updates for overseen lane \(first) and \(Self.otherLanePhrase(additional))."
        default:
            let first = Self.quoted(labels[0])
            let second = Self.quoted(labels[1])
            guard additional > 0 else {
                return "\(Self.sentenceOpening) updates for overseen lanes \(first) and \(second)."
            }
            return "\(Self.sentenceOpening) updates for overseen lanes \(first), \(second), and \(Self.otherLanePhrase(additional))."
        }
    }

    static func otherLanePhrase(_ count: Int) -> String {
        count == 1 ? "1 other overseen lane" : "\(count) other overseen lanes"
    }

    /// Typographic quotes so a label containing an ASCII quote cannot look like it closed the span.
    static func quoted(_ label: String) -> String {
        "\u{201C}\(label)\u{201D}"
    }
}
