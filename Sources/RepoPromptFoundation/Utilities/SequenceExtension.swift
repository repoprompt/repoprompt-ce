//
//  SequenceExtension.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-08-18.
//

import Foundation

extension Sequence {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async rethrows -> [T] {
        var results = [T]()
        for element in self {
            if let transformed = try await transform(element) {
                results.append(transformed)
            }
        }
        return results
    }
}
