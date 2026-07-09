//
//  AppcastParser.swift
//  RepoPrompt
//
//  Created by RepoPrompt Code Assistant on 2025-12-05.
//

import Foundation

/// Represents a single version entry from the appcast
struct AppcastVersion {
    let version: String
    let buildNumber: String?
    let date: Date?
    let description: String?
    let releaseNotesURL: String?
    let downloadURL: String?
    let minimumSystemVersion: String?
}

/// Parses Sparkle appcast.xml feeds to extract version information
final class AppcastParser: NSObject, XMLParserDelegate {
    // MARK: - Parsing State

    private var versions: [AppcastVersion] = []
    private var currentElement: String = ""
    private var currentVersion: String?
    private var currentBuildNumber: String?
    private var currentDate: Date?
    private var currentReleaseNotesURL: String?
    private var currentDownloadURL: String?
    private var currentMinimumSystemVersion: String?
    private var currentText: String = ""
    private var inItem = false

    /// Date formatter for pubDate parsing (RFC 2822 format)
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()

    // MARK: - Public API

    /// Parses appcast XML data and returns the latest version, or nil if parsing fails
    func parse(data: Data) -> AppcastVersion? {
        versions.removeAll()
        resetCurrentItem()

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false // Keep prefixes like "sparkle:"
        parser.parse()

        // Return the update with the highest numeric Sparkle build when present,
        // falling back to marketing-version comparison for legacy appcasts.
        return versions.max { lhs, rhs in
            if let lhsBuild = lhs.buildNumber.flatMap(SparkleBuildVersion.init),
               let rhsBuild = rhs.buildNumber.flatMap(SparkleBuildVersion.init)
            {
                return lhsBuild < rhsBuild
            }
            if isVersion(lhs.version, newerThan: rhs.version) { return false }
            return isVersion(rhs.version, newerThan: lhs.version)
        }
    }

    // MARK: - Private Helpers

    private func resetCurrentItem() {
        currentVersion = nil
        currentBuildNumber = nil
        currentDate = nil
        currentReleaseNotesURL = nil
        currentDownloadURL = nil
        currentMinimumSystemVersion = nil
        currentText = ""
        inItem = false
    }

    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let v1Components = v1.split(separator: ".").compactMap { Int($0) }
        let v2Components = v2.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(v1Components.count, v2Components.count)

        for i in 0 ..< maxLength {
            let v1Part = i < v1Components.count ? v1Components[i] : 0
            let v2Part = i < v2Components.count ? v2Components[i] : 0

            if v1Part > v2Part { return true }
            if v1Part < v2Part { return false }
        }
        return false
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "item":
            inItem = true
            // Reset item-specific state but keep inItem = true
            currentVersion = nil
            currentBuildNumber = nil
            currentDate = nil
            currentReleaseNotesURL = nil
            currentDownloadURL = nil
            currentMinimumSystemVersion = nil

        case "enclosure":
            // Extract download URL from enclosure
            if inItem {
                currentDownloadURL = attributeDict["url"]
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmedText = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "item":
            if inItem, let version = currentVersion, !version.isEmpty {
                let appcastVersion = AppcastVersion(
                    version: version,
                    buildNumber: currentBuildNumber,
                    date: currentDate,
                    description: nil,
                    releaseNotesURL: currentReleaseNotesURL,
                    downloadURL: currentDownloadURL,
                    minimumSystemVersion: currentMinimumSystemVersion
                )
                versions.append(appcastVersion)
            }
            inItem = false

        case "sparkle:shortVersionString":
            if inItem, !trimmedText.isEmpty {
                currentVersion = trimmedText
            }

        case "sparkle:version":
            if inItem, !trimmedText.isEmpty {
                currentBuildNumber = trimmedText
                // Use as version fallback if shortVersionString not present
                if currentVersion == nil {
                    currentVersion = trimmedText
                }
            }

        case "pubDate":
            if inItem, !trimmedText.isEmpty {
                currentDate = dateFormatter.date(from: trimmedText)
            }

        case "sparkle:releaseNotesLink":
            if inItem, !trimmedText.isEmpty {
                currentReleaseNotesURL = trimmedText
            }

        case "sparkle:minimumSystemVersion":
            if inItem, !trimmedText.isEmpty {
                currentMinimumSystemVersion = trimmedText
            }

        default:
            break
        }

        currentElement = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        print("[AppcastParser] Parse error: \(parseError)")
    }
}
