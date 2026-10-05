import Foundation

/// Canonical global-ignore settings values; legacy defaults migration stays in the app adapter.
package enum IgnoreSettingsDefaults {
    package static let globalIgnoreDefaultsKey = "globalIgnoreDefaults"
    package static let globalIgnoreDefaultsVersionKey = "globalIgnoreDefaultsVersion"
    /// Bump when we add new "required by default" patterns.
    package static let currentGlobalIgnoreDefaultsVersion = 2

    /// Canonical default patterns (do NOT include `.git`; that is always ignored separately).
    /// These mirror our "big dirs" heuristic plus a few common temp files.
    package static let canonicalGlobalIgnoreDefaults: String = """
    # RepoPrompt global ignore defaults (v\(currentGlobalIgnoreDefaultsVersion))
    **/node_modules/
    **/.npm/
    **/.pnpm-store/
    **/.yarn/
    **/.cache/
    **/bower_components/

    **/__pycache__/
    **/.pytest_cache/
    **/.mypy_cache/

    **/.gradle/
    **/.m2/
    **/.nuget/
    **/.cargo/
    **/.stack-work/
    **/.ccache/

    **/.idea/
    **/.vscode/
    **/.bundle/
    **/.gem/

    # Virtual environments
    **/.venv/
    **/venv/

    # Common temp/junk files
    **/*.swp
    **/*~
    **/*.tmp
    **/*.temp
    **/*.bak
    """
}
