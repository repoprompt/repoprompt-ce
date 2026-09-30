import Foundation

/// Shared process-environment sanitization for child process launches.
///
/// Phase 1 only centralizes the policy and constants. Existing launch callers are
/// migrated in later phases so security detection and spawn-time scrubbing cannot
/// drift on dynamic-loader environment keys. Sanitization treats all `DYLD_` and
/// `__XPC_DYLD_` variables as dynamic-loader state.
enum ProcessEnvironmentSanitizer {
    static let dynamicLoaderInsertLibrariesKey = "DYLD_INSERT_LIBRARIES"

    static let dynamicLoaderKeys: Set<String> = [
        dynamicLoaderInsertLibrariesKey,
        "DYLD_LIBRARY_PATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_ROOT_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH"
    ]

    static let dynamicLoaderKeyPrefixes: [String] = [
        "DYLD_",
        "__XPC_DYLD_"
    ]

    /// Environment selectors that can redirect a provider CLI to a compatible backend,
    /// alternate configuration, or non-default credential storage. Figma login must use the
    /// provider's ordinary user profile, so these are removed rather than overridden.
    static let figmaProviderLoginRemovedKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_API_URL",
        "CLAUDE_CODE_API_KEY",
        "CLAUDE_CODE_BASE_URL",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_API_BASE",
        "OPENCODE_CONFIG_CONTENT",
        "OPENCODE_CONFIG",
        "CURSOR_API_KEY",
        "CURSOR_BASE_URL",
        "FIGMA_PERSONAL_ACCESS_TOKEN",
        "FIGMA_PAT",
        "CODEX_HOME",
        "CODEX_SQLITE_HOME",
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_CACHE_HOME",
        "REPOPROMPT_CONFIG_HOME",
        "REPOPROMPT_DATA_HOME",
        "REPOPROMPT_DEBUG_CONFIG_HOME",
        "REPOPROMPT_CE_CONFIG_HOME"
    ]

    static func removedKeys(for purpose: ProcessLaunchPurpose) -> Set<String> {
        purpose == .figmaProviderLogin ? figmaProviderLoginRemovedKeys : []
    }

    static func sanitizedForChildLaunch(
        _ environment: [String: String],
        additionalRemovedKeys: Set<String> = []
    ) -> [String: String] {
        environment.filter { key, _ in
            !isDynamicLoaderKey(key) && !additionalRemovedKeys.contains(key)
        }
    }

    static func isDynamicLoaderKey(_ key: String) -> Bool {
        if dynamicLoaderKeys.contains(key) {
            return true
        }
        return dynamicLoaderKeyPrefixes.contains { key.hasPrefix($0) }
    }
}
