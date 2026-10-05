//
//  FileSystemProviding.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-08-02.
//

import Foundation

/// Production-neutral seam for filesystem operations used by filesystem services.
public protocol FileSystemProviding {
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL]
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func createDirectory(
        atPath path: String,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws
    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws
    func removeItem(at url: URL) throws
    func moveItemToTrash(at url: URL) throws -> URL?
    func isWritableFile(atPath path: String) -> Bool
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions,
        errorHandler: ((URL, Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator?
    func contents(atPath path: String) -> Data?
}

extension FileManager: FileSystemProviding {
    public func moveItemToTrash(at url: URL) throws -> URL? {
        var resultingItemURL: NSURL?
        try trashItem(at: url, resultingItemURL: &resultingItemURL)
        return resultingItemURL as URL?
    }
}
