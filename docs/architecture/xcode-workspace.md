# Generated Xcode Workspace

RepoPrompt CE provides a generated, disposable Xcode workspace for development convenience. `Package.swift` and `Package.resolved` remain the canonical target graph and dependency lock; conductor, SwiftPM, and `Scripts/package_app.sh` remain the authoritative build, test, and app-packaging paths.

## Generate and open

Xcode 26 and Python 3 are required.

```bash
make xcode            # generate and open
make xcode-generate   # generate without opening
make xcode-check      # verify existing output is current
make xcode-validate   # regenerate, check structure, and run xcodebuild -list
make xcode-clean      # remove generated workspace metadata
```

The generator writes `.build/xcode/RepoPromptCE.xcworkspace`. Everything under `.build/xcode` is derived and ignored; never edit or commit it. Regenerate after changes to the package manifest, lockfile, generator, or Xcode workflow wrapper.

## Schemes in Xcode 26.3

Xcode exposes SwiftPM product schemes, including `RepoPrompt` and `repoprompt-mcp`, alongside three repository convenience schemes:

- `RepoPrompt CE App` delegates to conductor to assemble the real debug app through the existing packaging flow, verifies the `.build/debug/RepoPrompt.app` compatibility path, then runs the local debug bundle under `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app`.
- `RepoPrompt CE MCP` delegates to conductor to build and run `.build/debug/repoprompt-mcp`.
- `RepoPrompt CE Tests` delegates to the conductor test runner. It is a legacy build target rather than a native Xcode test bundle because `RepoPromptMCP` is an executable-only SwiftPM target.

The native product schemes are useful for source navigation and indexing. Use `RepoPrompt CE Tests` for the supported full test workflow; optional `REPOPROMPT_XCODE_TEST_FILTER` narrows the delegated run. Sparkle's vendored XCFramework declares a `dSYMs` directory that is not present in the repository, so native Xcode package builds involving the app can fail before compilation. The generator deliberately does not mutate `Vendor/`; the packaged app convenience scheme remains the supported app build.

## Boundaries

This workflow is Debug-only. It does not define a second source graph, alter `Package.swift`, replace SwiftPM test resources, or support release/archive packaging. The app scheme permits ad-hoc signing when no stable identity is available; set `REPOPROMPT_XCODE_SIGN_IDENTITY` to choose an Apple Development identity explicitly. Ad-hoc builds use ephemeral secure storage.

Generated app, MCP, and test builds are conductor-coordinated. Xcode cancellation can stop waiting without canceling the queued daemon job; inspect `./conductor job list` before retrying. The explicit `REPOPROMPT_XCODE_UNCOORDINATED=1` fallback is build/test-only. Xcode Run still requires conductor so its pre-launch action can perform exact-executable lifecycle handling safely.

## Validation ownership

`Scripts/test_xcode_workspace_generator.py` protects deterministic output, manifest assumptions, scheme wiring, safe destinations, and stale-output detection. CI runs both `make xcode-generator-test` and `make xcode-validate`; existing SwiftPM/conductor build and test jobs remain authoritative.
