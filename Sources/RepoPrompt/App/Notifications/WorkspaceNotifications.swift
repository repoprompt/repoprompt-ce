//
//  Notifications.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-03-08.
//
import Foundation

/// Notification for missing bookmarks
extension Notification.Name {
    static let workspaceListDidChange = Notification.Name("workspaceListDidChange")
    /// Posted after a workspace's root paths are saved by another window.
    /// userInfo: ["managerID": UUID, "workspaceID": UUID]
    static let workspaceRepoPathsDidChange = Notification.Name("workspaceRepoPathsDidChange")
    static let workspacePresetsDidChange = Notification.Name("workspacePresetsDidChange")
    static let missingBookmarksDidChange = Notification.Name("WorkspaceManagerMissingBookmarksDidChange")
    /// Application update
    static let appWillRestartForUpdate = Notification.Name("appWillRestartForUpdate")
    /// Posted when a window's sticky instance number changes.
    /// userInfo: ["windowID": Int, "number": Int or NSNull()]
    static let windowInstanceNumberDidChange = Notification.Name("windowInstanceNumberDidChange")
    /// Posted immediately before switching compose tabs to allow views to flush pending state
    static let willSwitchComposeTab = Notification.Name("willSwitchComposeTab")
    /// Posted immediately before saving workspace state to allow views to flush pending state
    /// userInfo: ["windowID": Int, "workspaceID": UUID]
    static let workspaceWillSave = Notification.Name("workspaceWillSave")
    /// Posted when the number of open windows changes (window added or removed)
    static let windowCountDidChange = Notification.Name("windowCountDidChange")
    /// Posted when Claude Code connection status changes
    /// userInfo: ["windowID": Int] - the window that triggered the connection test
    static let claudeCodeConnectionChanged = Notification.Name("claudeCodeConnectionChanged")
    /// Posted when Codex CLI connection status changes
    /// userInfo mirrors `claudeCodeConnectionChanged`
    static let codexConnectionChanged = Notification.Name("codexConnectionChanged")
    /// Posted when OpenCode CLI connection status changes
    /// userInfo mirrors `claudeCodeConnectionChanged`
    static let openCodeConnectionChanged = Notification.Name("openCodeConnectionChanged")
    /// Posted when Cursor CLI connection status changes
    /// userInfo mirrors `claudeCodeConnectionChanged`
    static let cursorConnectionChanged = Notification.Name("cursorConnectionChanged")
    /// Posted when Droid CLI connection status changes
    /// userInfo mirrors `claudeCodeConnectionChanged`
    static let droidConnectionChanged = Notification.Name("droidConnectionChanged")
}
