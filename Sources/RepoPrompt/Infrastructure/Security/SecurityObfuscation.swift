//
//  SecurityObfuscation.swift
//  RepoPrompt
//
//  Centralized XOR obfuscation for security-sensitive strings.
//  Encoded values are internal for testability; decoded values stay scoped to their catalog or consumer.
//

import Foundation

enum SecurityObfuscation {
    static let key: UInt8 = 0x5A

    static func decode(_ bytes: [UInt8]) -> String {
        let decoded = bytes.map { $0 ^ key }
        return String(bytes: decoded, encoding: .utf8) ?? ""
    }

    // MARK: - SparkleUpdateManager Keys

    static let expectedFeedURLEncoded: [UInt8] = [
        50, 46, 46, 42, 41, 96, 117, 117, 61, 51, 46, 50, 47, 56, 116,
        57, 53, 55, 117, 40, 63, 42, 53, 42, 40, 53, 55, 42, 46, 117,
        40, 63, 42, 53, 42, 40, 53, 55, 42, 46, 119, 57, 63, 119, 47,
        42, 62, 59, 46, 63, 41, 117, 40, 63, 54, 63, 59, 41, 63, 41,
        117, 54, 59, 46, 63, 41, 46, 117, 62, 53, 45, 52, 54, 53, 59,
        62, 117, 59, 42, 42, 57, 59, 41, 46, 116, 34, 55, 54
    ]

    static let expectedPublicEdKeyEncoded: [UInt8] = [
        98, 110, 111, 49, 42, 99, 44, 111, 113, 49, 42, 110, 15, 108, 52,
        53, 98, 111, 18, 111, 105, 57, 15, 62, 52, 56, 60, 20, 105, 20,
        55, 31, 107, 10, 16, 18, 17, 45, 18, 98, 10, 62, 110, 103
    ]
}
