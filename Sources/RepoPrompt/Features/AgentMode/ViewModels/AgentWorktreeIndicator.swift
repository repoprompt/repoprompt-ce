import Foundation
import SwiftUI

/// View-model summary describing the bound-worktree visual identity for one
/// logical workspace root within an Agent session.
///
/// Built from a persisted `AgentSessionWorktreeBindingSummary` plus the global
/// per-repository worktree visual identity. This is presentation-only state for
/// the Agent Mode sidebar/root indicators (Item 10 of the worktree system);
/// runtime path projection and cwd resolution are owned by other items.
struct AgentWorktreeIndicator: Equatable, Identifiable {
    /// Stable binding identity — also used as the row-diffing `id`.
    let bindingID: String
    let repositoryID: String
    let worktreeID: String
    /// Standardized logical workspace-root path this worktree is bound to.
    let logicalRootPath: String
    let logicalRootName: String?
    let worktreeRootPath: String
    let worktreeName: String?
    let branch: String?
    /// Resolved, non-empty display label for the worktree.
    let label: String
    /// Validated `#RRGGBB` color hex for the worktree's visual identity.
    let colorHex: String
    /// SF Symbol name for the worktree capsule glyph.
    let iconName: String
    /// Marker geometry for the session-row indicator (dot / ring / capsule).
    let markerStyle: WorktreeVisualMarkerStyle
    /// False when the bound worktree path is missing on disk. Missing worktrees
    /// keep the persisted binding but render in a stale/unavailable state.
    let isAvailable: Bool

    var id: String {
        bindingID
    }
}

extension AgentWorktreeIndicator {
    /// Pure constructor combining a persisted binding summary with its resolved
    /// global visual identity. Kept side-effect-free so it is directly testable.
    static func make(
        summary: AgentSessionWorktreeBindingSummary,
        resolvedIdentity: WorktreeVisualIdentity,
        isAvailable: Bool
    ) -> AgentWorktreeIndicator {
        AgentWorktreeIndicator(
            bindingID: summary.id,
            repositoryID: summary.repositoryID,
            worktreeID: summary.worktreeID,
            logicalRootPath: summary.logicalRootPath,
            logicalRootName: summary.logicalRootName,
            worktreeRootPath: summary.worktreeRootPath,
            worktreeName: summary.worktreeName,
            branch: summary.branch,
            label: resolvedLabel(for: summary, resolvedIdentity: resolvedIdentity),
            colorHex: resolvedColorHex(for: summary, resolvedIdentity: resolvedIdentity),
            iconName: resolvedIdentity.iconName,
            markerStyle: resolvedIdentity.markerStyle,
            isAvailable: isAvailable
        )
    }

    /// The binding records the visual color persisted at create/bind time; fall
    /// back to the global identity's (deterministic) color when it is missing or
    /// malformed.
    private static func resolvedColorHex(
        for summary: AgentSessionWorktreeBindingSummary,
        resolvedIdentity: WorktreeVisualIdentity
    ) -> String {
        if let bound = summary.visualColorHex?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bound.isEmpty
        {
            let normalized = bound.uppercased()
            if isValidColorHex(normalized) {
                return normalized
            }
        }
        return resolvedIdentity.colorHex
    }

    /// Validates an uppercase `#RRGGBB` color hex string. Mirrors the global
    /// settings validator without coupling to its actor isolation.
    private static func isValidColorHex(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 7, scalars.first == "#" else { return false }
        return scalars.dropFirst().allSatisfy { scalar in
            (48 ... 57).contains(scalar.value) || (65 ... 70).contains(scalar.value)
        }
    }

    private static func resolvedLabel(
        for summary: AgentSessionWorktreeBindingSummary,
        resolvedIdentity: WorktreeVisualIdentity
    ) -> String {
        let candidates = [
            summary.visualLabel,
            resolvedIdentity.label,
            summary.worktreeName,
            summary.branch
        ]
        for candidate in candidates {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !trimmed.isEmpty
            {
                return trimmed
            }
        }
        let worktreeID = summary.worktreeID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !worktreeID.isEmpty {
            // Durable IDs look like `wt_<hash>`; keep a short, stable tail.
            return String(worktreeID.suffix(8))
        }
        return "worktree"
    }
}

// MARK: - Presentation helpers

extension AgentWorktreeIndicator {
    /// Tint color resolved from `colorHex`; falls back to the accent color when
    /// the hex cannot be parsed.
    var color: Color {
        Color(hex: colorHex) ?? .accentColor
    }

    /// Human-readable logical root name for tooltips/capsules.
    var displayRootName: String {
        if let logicalRootName, !logicalRootName.isEmpty {
            return logicalRootName
        }
        let trimmed = logicalRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return logicalRootPath }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    /// Compact capsule label, e.g. `WT feature-x`.
    var capsuleText: String {
        "WT \(label)"
    }

    /// Available worktrees may collapse to a compact `WT` fallback at narrow widths.
    /// Unavailable worktrees keep their identifying label visible for recovery.
    var allowsCompactCapsule: Bool {
        isAvailable
    }

    /// Missing physical worktree path exposed for recovery actions.
    var missingWorktreePath: String? {
        guard !isAvailable else { return nil }
        let trimmed = worktreeRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Tooltip / help text describing the bound worktree.
    var tooltipText: String {
        var parts = ["Agent execution worktree: \(label)"]
        if let branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("branch \(branch)")
        }
        parts.append("root \(displayRootName)")
        var text = parts.joined(separator: " · ")
        if !isAvailable {
            text += " — unavailable (worktree path missing: \(worktreeRootPath))"
        }
        return text
    }

    /// VoiceOver-friendly description.
    var accessibilityText: String {
        isAvailable
            ? "Bound to worktree \(label) for root \(displayRootName)"
            : "Bound to worktree \(label) for root \(displayRootName), worktree unavailable"
    }
}

// MARK: - Resolver

/// Resolves `AgentWorktreeIndicator` values from persisted binding summaries by
/// combining them with the global per-repository visual identity store and a
/// worktree-path availability check.
@MainActor
enum AgentWorktreeIndicatorResolver {
    static func indicator(
        for summary: AgentSessionWorktreeBindingSummary,
        settings: GlobalSettingsStore? = nil,
        fileManager: FileManager = .default
    ) -> AgentWorktreeIndicator {
        let settings = settings ?? GlobalSettingsStore.shared
        let resolvedIdentity = settings.resolvedWorktreeVisualIdentity(
            repositoryID: summary.repositoryID,
            worktreeID: summary.worktreeID,
            fallbackLabel: summary.visualLabel
        )
        return AgentWorktreeIndicator.make(
            summary: summary,
            resolvedIdentity: resolvedIdentity,
            isAvailable: worktreePathIsAvailable(summary.worktreeRootPath, fileManager: fileManager)
        )
    }

    static func indicators(
        for summaries: [AgentSessionWorktreeBindingSummary],
        settings: GlobalSettingsStore? = nil,
        fileManager: FileManager = .default
    ) -> [AgentWorktreeIndicator] {
        let settings = settings ?? GlobalSettingsStore.shared
        return summaries.map { indicator(for: $0, settings: settings, fileManager: fileManager) }
    }

    private static func worktreePathIsAvailable(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
