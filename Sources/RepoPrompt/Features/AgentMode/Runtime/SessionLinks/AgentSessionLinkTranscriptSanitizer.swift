import Foundation

// MARK: - Sanitized item model

/// Roles an observer may ever see. Deliberately coarser than `AgentChatItemKind`: an observer learns
/// *that* a tool ran, never what it was given or what it returned.
enum AgentSessionLinkTranscriptRole: String, CaseIterable, Equatable {
    case user
    case assistant
    case tool
    case system
    case error
    case summary
}

/// Whether an overseen user row arrived across an oversight link, and whether the reader sent it.
///
/// Deliberately ID-free and name-free. Naming the sending session would disclose the existence and
/// identity of a third session the reader was never granted, which is exactly the enumeration the
/// uniform authorization denial exists to prevent. `thisSession` is safe because the reader already
/// knows its own identity, and it is what makes a transcript honest: without it an observer cannot
/// tell its own injected turns apart from what the target's user typed.
enum AgentSessionLinkTranscriptCrossSessionOrigin: String, CaseIterable, Equatable {
    /// The reading observer sent this message.
    case thisSession = "this_session"
    /// Some other session with a link to this target sent it. No identity is disclosed.
    case otherSession = "other_session"
}

/// Terminal/status word for a tool row. No arguments, results, payloads, or interaction IDs.
enum AgentSessionLinkToolStatusWord: String, CaseIterable, Equatable {
    case called
    case completed
    case failed
}

/// One sanitized, byte-bounded transcript row.
///
/// Every textual field has already been redacted and capped; the MCP layer only escapes at the
/// output boundary. `itemID` is the stable projection row ID used as a read-cursor anchor.
struct AgentSessionLinkTranscriptItem: Equatable {
    let itemID: String
    let sequenceIndex: Int
    let role: AgentSessionLinkTranscriptRole
    let text: String?
    let toolName: String?
    let toolStatus: AgentSessionLinkToolStatusWord?
    let attachmentNote: String?
    let timestamp: Date
    /// Set only on user rows delivered across an oversight link.
    let crossSessionOrigin: AgentSessionLinkTranscriptCrossSessionOrigin?

    init(
        itemID: String,
        sequenceIndex: Int,
        role: AgentSessionLinkTranscriptRole,
        text: String?,
        toolName: String?,
        toolStatus: AgentSessionLinkToolStatusWord?,
        attachmentNote: String?,
        timestamp: Date,
        crossSessionOrigin: AgentSessionLinkTranscriptCrossSessionOrigin? = nil
    ) {
        self.itemID = itemID
        self.sequenceIndex = sequenceIndex
        self.role = role
        self.text = text
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.attachmentNote = attachmentNote
        self.timestamp = timestamp
        self.crossSessionOrigin = crossSessionOrigin
    }

    /// Approximate whole-item byte cost, including the response envelope and separators this row
    /// contributes.
    ///
    /// Budgets are enforced against this value rather than `text.utf8.count` so a page of many tiny
    /// rows cannot blow the output budget through envelope overhead alone.
    ///
    /// It is deliberately a **pre-serialization estimate**: raw UTF-8 payload bytes plus a fixed
    /// per-row envelope allowance, not the JSON the MCP layer finally emits. Escaping (`\"`, `\\`,
    /// `\n`, `\u00xx`) expands text on the wire, so an escape-dense page can exceed the caller's
    /// requested byte ceiling. Measuring the serialized form would mean encoding every candidate row
    /// on the `@MainActor` read path, so the budget is documented as approximate instead — see
    /// `AgentSessionLinkTranscriptBudget`.
    var utf8Cost: Int {
        var cost = AgentSessionLinkTranscriptBudget.perItemEnvelopeBytes
        cost += itemID.utf8.count
        cost += role.rawValue.utf8.count
        cost += text?.utf8.count ?? 0
        cost += toolName?.utf8.count ?? 0
        cost += toolStatus?.rawValue.utf8.count ?? 0
        cost += attachmentNote?.utf8.count ?? 0
        cost += crossSessionOrigin?.rawValue.utf8.count ?? 0
        return cost
    }

    /// Everything in `utf8Cost` except the row text: envelope, identifiers, and enumerated metadata.
    var nonTextUTF8Cost: Int {
        utf8Cost - (text?.utf8.count ?? 0)
    }

    /// A copy whose whole-item cost fits `remainingBudget`, used for the first row of a page.
    ///
    /// `minimumTextBytes` is a floor rather than a hard bound: a row that carries text must never
    /// degrade into a text-less row, because a forward-moving cursor would then step past content the
    /// observer can never request again. The residual overshoot is therefore bounded by a small
    /// constant instead of by `narrativeItemMaxBytes`, and a grapheme too wide to clip becomes an
    /// explicit marker rather than an empty string.
    func withTextTruncated(toRemainingBudget remainingBudget: Int, minimumTextBytes: Int) -> Self {
        guard let text else { return self }
        let allowance = max(minimumTextBytes, remainingBudget - nonTextUTF8Cost)
        guard text.utf8.count > allowance else { return self }
        let clipped = AgentSessionLinkTranscriptBudget.truncatedRowText(text, maxBytes: allowance)
        return AgentSessionLinkTranscriptItem(
            itemID: itemID,
            sequenceIndex: sequenceIndex,
            role: role,
            text: clipped,
            toolName: toolName,
            toolStatus: toolStatus,
            attachmentNote: attachmentNote,
            timestamp: timestamp,
            crossSessionOrigin: crossSessionOrigin
        )
    }
}

/// Why a resumed cursor could not continue from its anchor.
enum AgentSessionLinkReadCursorResetReason: String, Equatable {
    /// Compaction or projection replacement removed the anchor row.
    case anchorMissing = "anchor_missing"
}

/// One sanitized page plus its paging/observability metadata.
struct AgentSessionLinkTranscriptPage: Equatable {
    let items: [AgentSessionLinkTranscriptItem]
    /// Anchor the caller should resume strictly after.
    ///
    /// `page(...)` always produces one — an empty transcript yields `.beforeStart` rather than `nil`,
    /// because a reader that consumed nothing still has a place to resume from. The optionality is a
    /// wire shape the read path deliberately treats as fail-closed: no anchor means no successor
    /// cursor, and a page with no successor cursor is never released.
    let nextAnchor: AgentSessionLinkTranscriptAnchor?
    let hasMore: Bool
    let cursorReset: Bool
    let cursorResetReason: AgentSessionLinkReadCursorResetReason?
    /// Thinking rows skipped **within this page's span**, not across the whole transcript.
    let omittedThinkingCount: Int
    let truncated: Bool
    /// Approximate response size: raw UTF-8 payload plus fixed envelope allowances, measured before
    /// JSON serialization. See `AgentSessionLinkTranscriptItem.utf8Cost`.
    let outputUTF8Bytes: Int
}

/// Stable transcript anchor. Mirrors the domain cursor record without importing it into the pure
/// sanitizer, so paging can be golden-tested without an authority.
struct AgentSessionLinkTranscriptAnchor: Equatable {
    /// Empty means "before the first row"; a fresh `start` read resumes from the beginning.
    let itemID: String
    let sequenceIndex: Int

    static let beforeStart = AgentSessionLinkTranscriptAnchor(itemID: "", sequenceIndex: -1)

    var isBeforeStart: Bool {
        itemID.isEmpty
    }
}

enum AgentSessionLinkReadDirectionInput: String, CaseIterable, Equatable {
    case tail
    case start
}

// MARK: - Budgets

/// UTF-8 byte budgets. Never `String.count`: a page of emoji or CJK text would otherwise blow the
/// wire budget by a factor of three or four.
///
/// The budgets are **approximate wire budgets**, by choice. They count raw UTF-8 payload bytes plus
/// the fixed envelope allowances below, which is what makes budgeting a single cheap pass on the
/// `@MainActor` read path. They do not count JSON escaping expansion, so a page whose text is dense
/// in quotes, backslashes, newlines, or control characters can serialize larger than the caller's
/// requested ceiling. Enforcing an exact serialized bound would require encoding each candidate row
/// before deciding whether it fits.
enum AgentSessionLinkTranscriptBudget {
    static let defaultMaxItems = 30
    static let maximumMaxItems = 100
    static let defaultMaxOutputBytes = 8000
    static let maximumMaxOutputBytes = 20000

    /// Per-item cap for narrative rows (user/assistant/summary).
    static let narrativeItemMaxBytes = 4000
    /// Per-item cap for system/error rows.
    static let diagnosticItemMaxBytes = 500
    /// Fixed per-row envelope/separator allowance included in every item's cost.
    static let perItemEnvelopeBytes = 96
    /// Fixed page-level envelope allowance.
    static let pageEnvelopeBytes = 256
    /// Bytes of row text the first item on a page keeps even when the caller's byte budget is
    /// smaller than the row. It guarantees forward cursor progress without silently blanking a row.
    static let firstItemMinimumTextBytes = 256

    /// Upper bound on **source** rows a single page may walk before it stops and reports `has_more`.
    ///
    /// Item and byte budgets can only stop a walk that is producing content, and omitted rows
    /// (thinking/reasoning) produce none — so a long uninterrupted reasoning range would otherwise
    /// let one read scan arbitrarily far on the `@MainActor`. The ceiling turns that into an empty
    /// but forward-moving page: the cursor advances to the last row walked and the reader continues
    /// with its next call. It is far above `maximumMaxItems`, so it can never cut a page short while
    /// that page still had room for content.
    static let pageSourceRowScanLimit = 512

    /// Stands in for row text that cannot be represented within its byte allowance without splitting
    /// a grapheme cluster.
    ///
    /// A single extended grapheme cluster — a long combining-mark run or ZWJ emoji sequence — can be
    /// wider than a whole per-row allowance, and `truncatedUTF8` then has no whole `Character` to
    /// keep. Emitting no text in that case would hand the observer a text-less row *and* advance the
    /// cursor past it, making the content permanently unrequestable. The marker keeps forward
    /// progress while stating, visibly, that something was dropped.
    static let oversizedTextMarker = "[text omitted: exceeds byte budget]"

    static func clampedMaxItems(_ requested: Int?) -> Int {
        guard let requested else { return defaultMaxItems }
        return min(maximumMaxItems, max(1, requested))
    }

    static func clampedMaxOutputBytes(_ requested: Int?) -> Int {
        guard let requested else { return defaultMaxOutputBytes }
        return min(maximumMaxOutputBytes, max(perItemEnvelopeBytes + pageEnvelopeBytes, requested))
    }

    /// Truncates row text to `maxBytes`, substituting `oversizedTextMarker` when not one whole
    /// grapheme fits.
    ///
    /// Every caller passes an allowance of at least `firstItemMinimumTextBytes` (256) or
    /// `diagnosticItemMaxBytes` (500), both far wider than the marker, so the substitution cannot
    /// itself overrun the allowance.
    static func truncatedRowText(_ text: String, maxBytes: Int) -> String {
        guard !text.isEmpty else { return text }
        let clipped = truncatedUTF8(text, maxBytes: maxBytes)
        return clipped.isEmpty ? oversizedTextMarker : clipped
    }

    /// Truncates to at most `maxBytes` UTF-8 bytes on a `Character` boundary, so a page can never
    /// emit a split Unicode scalar or a partial grapheme cluster.
    ///
    /// Returns `""` when the first grapheme is already wider than `maxBytes`; row text goes through
    /// `truncatedRowText` so that case becomes a marker instead of a blank.
    static func truncatedUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var result = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > maxBytes { break }
            result.append(character)
            used += width
        }
        return result
    }
}

// MARK: - Redaction

/// Oversight-scoped conservative redactor.
///
/// Structural stripping in the sanitizer already removes the highest-risk capability payloads (tool
/// arguments, tool results, `ask_user` bodies, provider metadata). This layer bounds the obvious
/// secrets that can still appear inside ordinary user/assistant prose, and normalizes home-directory
/// paths so an observer cannot learn the operator's account name or checkout location.
///
/// It deliberately prefers false-positive redaction over disclosure.
enum AgentSessionLinkTextRedactor {
    static let placeholder = "[redacted]"

    private struct Rule {
        let regex: NSRegularExpression
        /// Template referencing capture groups, so the *shape* survives while the value does not.
        let template: String
    }

    private static let rules: [Rule] = {
        let specs: [(pattern: String, template: String)] = [
            // `Authorization: Bearer …` / `Authorization: Basic …` headers in pasted logs.
            (#"(?i)\b(authorization\s*[:=]\s*)(?:bearer|basic|token)?\s*\S+"#, "$1\(placeholder)"),
            // Bare credential schemes.
            (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 \(placeholder)"),
            // `api_key = "…"`, `OPENAI_TOKEN=…`, `secret=…`, `password: …`, and JSON field forms.
            //
            // The keyword may carry an arbitrary identifier prefix/suffix (`OPENAI_TOKEN`,
            // `gh_api_key_v2`), because a credential is far more often namespaced than bare. That
            // deliberately over-matches benign names such as `max_tokens`: for a cross-session
            // observer, a redacted number is a much cheaper failure than a leaked credential.
            (
                #"(?i)("?[A-Za-z0-9_.-]*(?:api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|"#
                    + #"auth[_-]?token|secret[_-]?key|client[_-]?secret|private[_-]?key|credential|"#
                    + #"password|passwd|secret|token)[A-Za-z0-9_.-]*"?"#
                    + #"\s*[:=]\s*)(?:"[^"\n]*"|'[^'\n]*'|[^\s,;}\]]+)"#,
                "$1\(placeholder)"
            ),
            // Well-known provider key shapes that can appear without any assignment context.
            (#"\b(?:sk|rk|pk)-[A-Za-z0-9_-]{16,}"#, placeholder),
            (#"\bgh[pousr]_[A-Za-z0-9]{16,}"#, placeholder),
            (#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, placeholder),
            (#"\bAKIA[0-9A-Z]{16}\b"#, placeholder),
            // PEM blocks.
            (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, placeholder)
        ]
        return specs.compactMap { spec in
            guard let regex = try? NSRegularExpression(pattern: spec.pattern) else { return nil }
            return Rule(regex: regex, template: spec.template)
        }
    }()

    /// Redacts secrets, then normalizes home-directory paths.
    static func redact(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var result = text
        for rule in rules {
            result = rule.regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: rule.template
            )
        }
        return normalizeHomePaths(result, homeDirectory: homeDirectory)
    }

    /// Replaces the operator's home directory with `~`, in its bare, `file://`, and percent-encoded
    /// spellings.
    ///
    /// The percent-encoded spelling matters only when the path needs encoding at all — a home
    /// directory containing a space appears as `%20` inside a URL — so it is computed lazily and
    /// skipped when it is identical to the bare form.
    static func normalizeHomePaths(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let trimmedHome = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard trimmedHome.count > 1 else { return text }
        var spellings = ["file://\(trimmedHome)", trimmedHome]
        if let encoded = trimmedHome.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           encoded != trimmedHome
        {
            // Scheme-qualified forms first, so `file://` is consumed before its bare path prefix is.
            spellings = ["file://\(encoded)", "file://\(trimmedHome)", encoded, trimmedHome]
        }
        var result = text
        for spelling in spellings {
            result = result.replacingOccurrences(of: spelling, with: "~")
        }
        return result
    }
}

// MARK: - Sanitizer

/// Pure, golden-testable mapping from the canonical user-visible projection to the only transcript
/// representation an observer may ever receive.
///
/// The oversight layer is deliberately stricter than the normal runtime/persistence tool-result policy:
/// that policy keeps `ask_user` payloads and supported tool summaries because a local user is allowed
/// to see them in their own window. A cross-session observer is not, so tool arguments, tool results,
/// interaction identifiers, prompts/options, reasoning, provider metadata, and attachment content are
/// stripped **structurally** here — never by pattern-matching a payload we then hope is safe.
enum AgentSessionLinkTranscriptSanitizer {
    /// Block kinds whose rows must be presented as compacted summaries rather than live narration.
    static let summaryBlockKinds: Set<AgentTranscriptRenderBlockKind> = [
        .middleSummary,
        .groupedHistory,
        .collapsedHistoryRange
    ]

    /// Maps one canonical projection row.
    ///
    /// - Parameter isSummaryRow: whether the owning render block is a compacted summary block.
    /// - Parameter readerSessionID: the reading observer's session ID, used only to classify a
    ///   cross-session user row as `thisSession` versus `otherSession`. It never emits an identity.
    /// - Returns: `nil` for thinking/reasoning rows, which are omitted and counted instead.
    static func sanitize(
        row: AgentChatItem,
        isSummaryRow: Bool = false,
        readerSessionID: UUID? = nil,
        homeDirectory: String = NSHomeDirectory()
    ) -> AgentSessionLinkTranscriptItem? {
        switch row.kind {
        case .thinking:
            // Omitted entirely; the page reports `omitted_thinking_count`.
            return nil
        case .toolCall, .toolResult:
            // Structural: no text, no arguments, no result, no invocation identifier. This also
            // overrides the normal persistence exception that preserves raw `ask_user` payloads —
            // an observer sees only that `ask_user` ran and how it ended.
            return AgentSessionLinkTranscriptItem(
                itemID: row.id.uuidString,
                sequenceIndex: row.sequenceIndex,
                role: .tool,
                text: nil,
                toolName: normalizedToolName(row.toolName),
                toolStatus: statusWord(for: row),
                attachmentNote: nil,
                timestamp: row.timestamp
            )
        case .user, .assistant, .assistantInline, .system, .error:
            let role = role(for: row.kind, isSummaryRow: isSummaryRow)
            let cap = switch role {
            case .system, .error:
                AgentSessionLinkTranscriptBudget.diagnosticItemMaxBytes
            case .user, .assistant, .summary, .tool:
                AgentSessionLinkTranscriptBudget.narrativeItemMaxBytes
            }
            let redacted = AgentSessionLinkTextRedactor.redact(row.text, homeDirectory: homeDirectory)
            let text = AgentSessionLinkTranscriptBudget.truncatedRowText(redacted, maxBytes: cap)
            return AgentSessionLinkTranscriptItem(
                itemID: row.id.uuidString,
                sequenceIndex: row.sequenceIndex,
                role: role,
                // `reasoning` is never emitted, even when a bubble renders it locally.
                text: text.isEmpty ? nil : text,
                toolName: nil,
                toolStatus: nil,
                attachmentNote: attachmentNote(for: row),
                timestamp: row.timestamp,
                crossSessionOrigin: crossSessionOrigin(for: row, readerSessionID: readerSessionID)
            )
        }
    }

    /// Whether a row's observer-visible representation is final, i.e. whether a cursor may step past
    /// it.
    ///
    /// The projection reuses one `AgentChatItem.id` across mutation, so a stable row ID is **not** a
    /// stable row. Two rewrites happen under an unchanged ID:
    ///
    /// - a streaming assistant row accumulates deltas into the same item and can be replaced
    ///   wholesale by the provider's reconciled text when the segment ends;
    /// - a `.toolCall` row is promoted **in place** to `.toolResult`, which flips both fields a tool
    ///   row ever exposes — `called` is a pending state, never a terminal word.
    ///
    /// A cursor that consumed either would place the row at or before its anchor and never return the
    /// finished form, which is the silent-skip class the paging rules exist to prevent. Omitted kinds
    /// are classified here for completeness; the walk only consults this for rows that produced an
    /// emitted item, because a row with no observer-visible representation has nothing a later
    /// rewrite could change for the reader.
    ///
    /// "Not final" is **not** the same as "will become final". A `.toolCall` can outlive its run: a
    /// crash mid-call persists the row as `.toolCall` (`AgentChatModels.swift` keeps `kind`
    /// verbatim), and cold restore does not promote it — `sanitizeColdRestoredActivity` synthesizes a
    /// cancelled result only when the row is already `.toolResult`, and `normalizeLoadedSession`
    /// skips terminal-tool repair outright when the persisted run state was active. The walk
    /// therefore uses this predicate only at the live edge; see `page(...)`.
    static func isFinalizedForOversight(row: AgentChatItem) -> Bool {
        switch row.kind {
        case .assistant, .assistantInline, .thinking:
            !row.isStreaming
        case .toolCall:
            false
        case .toolResult, .user, .system, .error:
            true
        }
    }

    /// Classifies a row's oversight-link provenance without disclosing who sent it.
    static func crossSessionOrigin(
        for row: AgentChatItem,
        readerSessionID: UUID?
    ) -> AgentSessionLinkTranscriptCrossSessionOrigin? {
        guard row.kind == .user, let attribution = row.crossSessionAttribution else { return nil }
        return attribution.sourceSessionID == readerSessionID ? .thisSession : .otherSession
    }

    private static func role(
        for kind: AgentChatItemKind,
        isSummaryRow: Bool
    ) -> AgentSessionLinkTranscriptRole {
        if isSummaryRow, kind != .user { return .summary }
        switch kind {
        case .user:
            return .user
        case .assistant, .assistantInline:
            return .assistant
        case .system:
            return .system
        case .error:
            return .error
        case .toolCall, .toolResult, .thinking:
            return .system
        }
    }

    /// Tool names are an allowlist-free but shape-constrained value: they identify the capability, so
    /// they are normalized and capped rather than dropped.
    static func normalizedToolName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let filtered = String(raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        })
        guard !filtered.isEmpty else { return nil }
        return AgentSessionLinkTranscriptBudget.truncatedUTF8(filtered, maxBytes: 120)
    }

    private static func statusWord(for row: AgentChatItem) -> AgentSessionLinkToolStatusWord {
        switch row.kind {
        case .toolCall:
            .called
        case .toolResult:
            row.toolIsError == true ? .failed : .completed
        default:
            .called
        }
    }

    /// Count/type note only. Never a filename, path, URL, title, or byte of content.
    static func attachmentNote(for row: AgentChatItem) -> String? {
        var parts: [String] = []
        if !row.attachments.isEmpty {
            parts.append("\(row.attachments.count) image attachment\(row.attachments.count == 1 ? "" : "s")")
        }
        if !row.taggedFileAttachments.isEmpty {
            let count = row.taggedFileAttachments.count
            parts.append("\(count) file attachment\(count == 1 ? "" : "s")")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    // MARK: - Paging

    /// Builds one bounded page from the canonical row sequence.
    ///
    /// Paging always moves forward: a resumed cursor continues strictly *after* its anchor, even when
    /// the source revision advanced through appends. `direction` decides only where a fresh page
    /// starts — `tail` gives the recent tail (so the next cursor tracks new activity), `start` walks
    /// history from the beginning.
    ///
    /// This walk is bounded by the page. Rows are sanitized lazily while it moves outward from the
    /// page's own starting row in its fill direction — backwards from the newest row for a fresh
    /// `tail`, forwards from just after the anchor otherwise — and it stops at the first row that
    /// does not fit the item/byte budget, or at `pageSourceRowScanLimit` source rows when omitted
    /// rows are producing no content to budget against. Only the one refused row is sanitized beyond
    /// the page, and it is what makes `has_more` exact. Resuming costs `O(log n)` to locate the
    /// anchor rather than a linear scan. Redaction is the expensive part of a read, so keeping it
    /// proportional to the page is what stops one authorized `read` from paying for a whole
    /// transcript.
    ///
    /// **Emission and consumption are separate, at the live edge only.** Every row this walk reaches
    /// is *emitted* under the item/byte budgets. The **newest** row is additionally not *consumed* —
    /// it does not carry `nextAnchor` past itself — while its observer-visible representation is
    /// still mutable (`isFinalizedForOversight(row:)`). Consuming it would place it at or before the
    /// cursor, and the finished form it later takes under the same row ID would never be returned.
    /// Left unconsumed, the reader sees the live content now and receives it again, finished, on its
    /// next read: one repeated row instead of lost content, and `item_id` is stable so the reader
    /// updates in place rather than double-counting.
    ///
    /// **Why only the newest row.** Parking on any mutable row anywhere would be a worse bug than the
    /// one it fixes. "Not final" does not imply "will become final": a crash mid-tool-call persists a
    /// `.toolCall` row that cold restore never promotes, so a cursor that parked on it would sit
    /// there forever and every later row — the entire rest of the transcript — would be silently
    /// unreachable. Restricting the park to the newest row makes that impossible by construction:
    /// nothing exists after the newest row, so parking withholds nothing, and the next appended row
    /// ends the park with no timeout, constant, or run-state input. Head-of-line blocking cannot
    /// occur — a long-running tool call never hides the rows behind it.
    ///
    /// The accepted residual is the mirror image: a mutable row that is *not* newest is consumed, so
    /// a streaming assistant row interrupted by a user interjection, or a pending tool call that
    /// completes after a sibling, keeps whatever the observer last saw (for a tool row, `called`).
    /// The staleness is bounded *per row* — only the form already delivered goes stale, never a row
    /// the observer has not seen — and each page can strand at most the mutable rows it consumed.
    /// It is **not** globally single-row: `isFinalizedForOversight(row:)` classifies every pending
    /// `.toolCall` as mutable while only the newest is parked, so a target running tools in parallel
    /// can have several earlier `.toolCall` rows consumed as `called` and promoted afterwards, and
    /// each advance of the live edge can strand one more. It is still deliberately preferred over an
    /// unbounded park: stale text is recoverable context — a fresh `start` read re-delivers every row
    /// in its current form — while an unreachable transcript tail is not.
    ///
    /// **A fresh tail keeps a baseline even when the parked row is all that fits.** The park sets no
    /// consumed anchor, so a fresh `tail` whose budget admits only the live-edge row would otherwise
    /// fall through to `.beforeStart` — which means "resume forward from row zero" — and walk a tail
    /// observer into history it never asked for, contradicting the tail contract and re-delivering
    /// far more than one row. Such a page instead anchors at the row immediately *before* the parked
    /// one, emitted or not. That is legitimate only for a fresh tail, which deliberately excludes
    /// older history and never promised its predecessor: `has_more` already says nothing newer is
    /// pending, and the observer reaches older rows through a `start` cursor. A start or resumed
    /// forward page must never do this — there a refused row is promised content and has to stay
    /// unconsumed.
    ///
    /// The **caller** materializes and sorts the whole canonical projection before this runs, so an
    /// authorized read is still `O(transcript)` end-to-end — that part now happens off the
    /// `@MainActor`. See `AgentModeViewModel.canonicalTranscript(from:sourceItemsRevision:)` for why
    /// memoizing it needs a transcript-side revision this layer does not have.
    ///
    /// - Parameter anchor: `nil` means "fresh page". A supplied `.beforeStart` anchor is a *resumed*
    ///   cursor that has consumed nothing yet, so it pages forward from the first row.
    static func page(
        rows: [AgentChatItem],
        summaryRowIDs: Set<UUID> = [],
        anchor: AgentSessionLinkTranscriptAnchor?,
        direction: AgentSessionLinkReadDirectionInput,
        maxItems: Int,
        maxOutputBytes: Int,
        readerSessionID: UUID? = nil,
        homeDirectory: String = NSHomeDirectory()
    ) -> AgentSessionLinkTranscriptPage {
        var cursorReset = false
        var resetReason: AgentSessionLinkReadCursorResetReason?
        var startIndex = 0
        var isFreshPage = true

        if let anchor {
            if anchor.isBeforeStart {
                // A resumed `.beforeStart` cursor is *not* a fresh page. It is the cursor an empty
                // transcript hands back, and it means "you have consumed nothing yet", so the reader
                // continues from row zero in either direction. Treating it as fresh would refill a
                // `tail` page from the *newest* row and silently skip everything appended in between,
                // while reporting `has_more: false` — which claims there is nothing older to fetch.
                isFreshPage = false
            } else if let index = anchorRowIndex(in: rows, anchor: anchor) {
                startIndex = rows.index(after: index)
                isFreshPage = false
            } else {
                // Anchor existence — not a compaction fingerprint — is the validity rule. A removed
                // anchor returns a fresh page in the original direction and says so explicitly, so a
                // caller can detect the duplication rather than silently skipping content.
                cursorReset = true
                resetReason = .anchorMissing
            }
        }

        // A fresh `tail` page shows the most recent rows, so it fills from the end.
        let fillsFromEnd = isFreshPage && direction == .tail
        let step = fillsFromEnd ? -1 : 1

        var selected: [AgentSessionLinkTranscriptItem] = []
        var omittedThinkingCount = 0
        var usedBytes = AgentSessionLinkTranscriptBudget.pageEnvelopeBytes
        var truncated = false
        var hasMore = false
        // The newest row this page consumed, emitted or omitted. Cursor progress is defined by it.
        var consumedAnchor: AgentSessionLinkTranscriptAnchor?
        // Fresh `tail` only: the row immediately before a parked live edge. It is the page's tail
        // baseline when the budget admits nothing else, so the successor cursor still resumes at the
        // live edge instead of rewinding to row zero.
        var tailParkBaseline: AgentSessionLinkTranscriptAnchor?

        var scannedSourceRows = 0
        var index = fillsFromEnd ? rows.count - 1 : min(startIndex, rows.count)
        walk: while index >= 0, index < rows.count {
            guard scannedSourceRows < AgentSessionLinkTranscriptBudget.pageSourceRowScanLimit else {
                // Item/byte budgets can only stop a walk that is producing content; a long omitted
                // range produces none, so the scan ceiling is what bounds it. For a `start` or
                // resumed walk the page ends where the walk did, and the anchor below is the last row
                // it consumed, so an empty page still moves the reader forward instead of rescanning
                // the same range on every read.
                //
                // A *fresh tail* fill is different and deliberately so: it walks backward from the
                // newest row and anchors at the newest row it consumed, and tail cursors only move
                // toward newer rows. A trailing run of at least `pageSourceRowScanLimit` omitted rows
                // therefore yields a partial or empty tail whose only signal is `truncated`, because
                // by the tail contract there is nothing *newer* left to announce through `has_more`.
                // The reader reaches the older rows by opening a `start` cursor.
                truncated = true
                hasMore = !fillsFromEnd
                break walk
            }
            scannedSourceRows += 1
            let row = rows[index]
            // Set only for rows this page actually emitted, so an omitted row is never treated as
            // mutable content: it has no observer-visible representation for a rewrite to change.
            var parksCursor = false
            // Only the newest row can be the one the target is still writing. Restricting the rule to
            // it is what makes the park harmless: nothing exists after the newest row, so parking
            // there withholds nothing, and the next appended row ends the park automatically.
            let isLiveEdge = index == rows.count - 1
            if let item = sanitize(
                row: row,
                isSummaryRow: summaryRowIDs.contains(row.id),
                readerSessionID: readerSessionID,
                homeDirectory: homeDirectory
            ) {
                if selected.count >= maxItems {
                    truncated = true
                    // A tail page is newest-anchored by construction, so a budget stop leaves only
                    // *older* rows behind — never anything newer to fetch.
                    hasMore = !fillsFromEnd
                    break walk
                }
                var emitted = item
                var cost = item.utf8Cost
                if usedBytes + cost > maxOutputBytes {
                    guard selected.isEmpty else {
                        truncated = true
                        hasMore = !fillsFromEnd
                        break walk
                    }
                    // The first row is budgeted, not exempted. Skipping the check for it would let a
                    // caller that asked for a few hundred bytes receive a full `narrativeItemMaxBytes`
                    // row; refusing it outright would stall the cursor on that row forever. Shrink its
                    // text into the remaining page budget instead, and say the page was truncated.
                    emitted = item.withTextTruncated(
                        toRemainingBudget: maxOutputBytes - usedBytes,
                        minimumTextBytes: AgentSessionLinkTranscriptBudget.firstItemMinimumTextBytes
                    )
                    cost = emitted.utf8Cost
                    truncated = true
                }
                usedBytes += cost
                selected.append(emitted)
                parksCursor = isLiveEdge && !isFinalizedForOversight(row: row)
                if parksCursor, fillsFromEnd, index > 0 {
                    // Recorded before the budget can stop the walk one row later. A fresh tail that
                    // fits only this row has no consumed anchor at all, and `.beforeStart` would send
                    // the observer forward from row zero.
                    tailParkBaseline = AgentSessionLinkTranscriptAnchor(
                        itemID: rows[index - 1].id.uuidString,
                        sequenceIndex: rows[index - 1].sequenceIndex
                    )
                }
            } else {
                // Thinking rows are never emitted, but consuming them is what stops the next read
                // from re-scanning them forever; they are counted against this page, not the whole
                // transcript.
                omittedThinkingCount += 1
            }
            // The row was emitted either way; only the anchor is held back. A forward walk keeps the
            // anchor it had, and a backward fill visits the newest row first, so skipping the
            // assignment leaves the anchor to the next older final row. Neither direction needs to
            // stop walking, so no row is ever withheld and `has_more` needs no special case: a park
            // can only happen at the newest row, where "nothing newer" is literally true.
            if !parksCursor, !fillsFromEnd || consumedAnchor == nil {
                consumedAnchor = AgentSessionLinkTranscriptAnchor(
                    itemID: row.id.uuidString,
                    sequenceIndex: row.sequenceIndex
                )
            }
            index += step
        }
        if fillsFromEnd {
            selected.reverse()
        }

        let nextAnchor: AgentSessionLinkTranscriptAnchor? = if let consumedAnchor {
            // Includes a tail or resumed page whose only consumed rows were omitted: anchoring at the
            // newest consumed row is what stops the next read from replaying them.
            consumedAnchor
        } else if let tailParkBaseline {
            // Fresh tail, parked live edge, nothing else fitted. Only reachable while `isFreshPage`,
            // so it never overrides a caller's own anchor.
            tailParkBaseline
        } else if let anchor, !cursorReset {
            // Nothing new since the last read: keep the caller's place instead of rewinding.
            anchor
        } else {
            .beforeStart
        }

        return AgentSessionLinkTranscriptPage(
            items: selected,
            nextAnchor: nextAnchor,
            hasMore: hasMore,
            cursorReset: cursorReset,
            cursorResetReason: resetReason,
            omittedThinkingCount: omittedThinkingCount,
            truncated: truncated,
            outputUTF8Bytes: usedBytes
        )
    }

    /// Position of the anchor row, or `nil` when the anchor no longer exists.
    ///
    /// Callers supply rows in ascending `(sequenceIndex, timestamp)` order, so the anchor's recorded
    /// `sequenceIndex` locates it in `O(log n)` — a resumed read must not pay a linear scan (with a
    /// `uuidString` allocation per row) over the whole transcript just to find where it left off.
    ///
    /// Ordering is an optimization, never a correctness input: an unordered or re-sequenced row set
    /// falls back to an exact linear scan, so a resumable anchor is never mistaken for a missing one
    /// and reported as a spurious `anchor_missing` reset. Only a genuinely absent anchor pays that
    /// scan, and it resets the cursor once rather than on every read.
    private static func anchorRowIndex(
        in rows: [AgentChatItem],
        anchor: AgentSessionLinkTranscriptAnchor
    ) -> Int? {
        let anchorRowID = UUID(uuidString: anchor.itemID)
        func isAnchorRow(_ row: AgentChatItem) -> Bool {
            if let anchorRowID { return row.id == anchorRowID }
            return row.id.uuidString == anchor.itemID
        }

        var low = 0
        var high = rows.count - 1
        while low <= high {
            let mid = low + (high - low) / 2
            let sequenceIndex = rows[mid].sequenceIndex
            if sequenceIndex < anchor.sequenceIndex {
                low = mid + 1
            } else if sequenceIndex > anchor.sequenceIndex {
                high = mid - 1
            } else {
                // Sequence indices are not guaranteed unique, so walk the equal run in both
                // directions before concluding anything.
                var backward = mid
                while backward >= 0, rows[backward].sequenceIndex == anchor.sequenceIndex {
                    if isAnchorRow(rows[backward]) { return backward }
                    backward -= 1
                }
                var forward = mid + 1
                while forward < rows.count, rows[forward].sequenceIndex == anchor.sequenceIndex {
                    if isAnchorRow(rows[forward]) { return forward }
                    forward += 1
                }
                break
            }
        }
        return rows.firstIndex(where: isAnchorRow)
    }
}
