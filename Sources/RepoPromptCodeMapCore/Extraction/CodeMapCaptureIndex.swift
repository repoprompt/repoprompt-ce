//
//  CodeMapCaptureIndex.swift
//  RepoPrompt
//
//  Created by Claude on 2026-01-29.
//

import Foundation
import SwiftTreeSitter

/// Indexed access to Tree-sitter captures for efficient lookup.
/// Eliminates O(n²) scans when searching for captures by name or containment.
struct CodeMapCaptureIndex {
    /// All captures sorted by location
    let all: [NamedRange]

    /// Captures grouped by name, each list sorted by location
    let byName: [String: [NamedRange]]

    /// Creates an index from an array of captures
    init(_ captures: [NamedRange]) {
        all = captures.sorted { $0.range.location < $1.range.location }

        var grouped: [String: [NamedRange]] = [:]
        for cap in all {
            grouped[cap.name, default: []].append(cap)
        }
        byName = grouped
    }

    /// Returns all captures with the given name, sorted by location
    func captures(named name: String) -> [NamedRange] {
        byName[name] ?? []
    }

    /// Returns the first capture with the given name that is fully contained within the parent range
    func firstCapture(named name: String, containedIn parent: NSRange) -> NamedRange? {
        guard let candidates = byName[name] else { return nil }

        // Binary search to find the first candidate that could be in range
        let startIdx = candidates.binarySearch { $0.range.location < parent.location }

        for i in startIdx ..< candidates.count {
            let cap = candidates[i]
            // If we've gone past the parent range, stop
            if cap.range.location >= NSMaxRange(parent) { break }
            // Check containment
            if rangeContains(parent, cap.range) {
                return cap
            }
        }
        return nil
    }

    /// Returns all captures with the given name that are fully contained within the parent range
    func captures(named name: String, containedIn parent: NSRange) -> [NamedRange] {
        guard let candidates = byName[name] else { return [] }

        var results: [NamedRange] = []

        // Binary search to find the first candidate that could be in range
        let startIdx = candidates.binarySearch { $0.range.location < parent.location }

        for i in startIdx ..< candidates.count {
            let cap = candidates[i]
            // If we've gone past the parent range, stop
            if cap.range.location >= NSMaxRange(parent) { break }
            // Check containment
            if rangeContains(parent, cap.range) {
                results.append(cap)
            }
        }
        return results
    }

    /// Returns all captures (of any name) that are fully contained within the parent range
    func allCaptures(containedIn parent: NSRange) -> [NamedRange] {
        var results: [NamedRange] = []

        // Binary search to find the first capture that could be in range
        let startIdx = all.binarySearch { $0.range.location < parent.location }

        for i in startIdx ..< all.count {
            let cap = all[i]
            // If we've gone past the parent range, stop
            if cap.range.location >= NSMaxRange(parent) { break }
            // Check containment
            if rangeContains(parent, cap.range) {
                results.append(cap)
            }
        }
        return results
    }

    /// Returns the smallest capture with the given name that fully contains the target range.
    func smallestCapture(named name: String, containing target: NSRange) -> NamedRange? {
        guard let candidates = byName[name] else { return nil }
        return smallestCapture(in: candidates, containing: target)
    }

    /// Returns the smallest capture with any of the given names that fully contains the target range.
    func smallestCapture(namedAny names: [String], containing target: NSRange) -> NamedRange? {
        var best: NamedRange? = nil
        for name in names {
            guard let candidate = smallestCapture(named: name, containing: target) else { continue }
            if best == nil || isBetterContainingCandidate(candidate, than: best!) {
                best = candidate
            }
        }
        return best
    }

    private func smallestCapture(in candidates: [NamedRange], containing target: NSRange) -> NamedRange? {
        let endIdx = candidates.binarySearch { $0.range.location <= target.location }
        guard endIdx > 0 else { return nil }

        var best: NamedRange? = nil
        for i in stride(from: endIdx - 1, through: 0, by: -1) {
            let candidate = candidates[i]
            if rangeContains(candidate.range, target),
               best == nil || isBetterContainingCandidate(candidate, than: best!)
            {
                best = candidate
            }
        }
        return best
    }

    private func isBetterContainingCandidate(_ candidate: NamedRange, than current: NamedRange) -> Bool {
        if candidate.range.length != current.range.length {
            return candidate.range.length < current.range.length
        }
        return candidate.range.location < current.range.location
    }

    /// Checks if inner range is fully contained within outer range
    private func rangeContains(_ outer: NSRange, _ inner: NSRange) -> Bool {
        inner.location >= outer.location &&
            NSMaxRange(inner) <= NSMaxRange(outer)
    }
}

// MARK: - Binary Search Extension

private extension Array {
    /// Returns the index of the first element where the predicate returns false.
    /// The array must be partitioned such that all elements where predicate returns true
    /// come before all elements where predicate returns false.
    func binarySearch(predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
