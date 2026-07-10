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

The native `RepoPrompt` product scheme retains the shipped product, target, and emitted-binary identity. Internally, that executable is now a one-file entry target over the `RepoPromptApp` implementation library. `RepoPromptApp` is an internal SwiftPM target rather than a declared library product, so it does not add a supported product or convenience scheme.

- `RepoPrompt CE App` delegates to conductor to assemble the real debug app through the existing packaging flow, verifies the `.build/debug/RepoPrompt.app` compatibility path, then runs the local debug bundle under `~/Library/Application Support/RepoPrompt CE/DebugApps/RepoPrompt.app`.
- `RepoPrompt CE MCP` delegates to conductor to build and run `.build/debug/repoprompt-mcp`.
- `RepoPrompt CE Tests` delegates to the conductor test runner. Root tests import `RepoPromptApp`, but retain their separate `RepoPromptMCP` dependency/imports; the scheme remains a legacy build target rather than a native Xcode test bundle because `RepoPromptMCP` is executable-only.

The native product schemes are useful for source navigation and indexing. Use `RepoPrompt CE Tests` for the supported full test workflow; optional `REPOPROMPT_XCODE_TEST_FILTER` narrows the delegated run. Sparkle's vendored XCFramework declares a `dSYMs` directory that is not present in the repository, so native Xcode package builds involving the app can fail before compilation. The generator deliberately does not mutate `Vendor/`; the packaged app convenience scheme remains the supported app build.

## Boundaries

This workflow is Debug-only. It does not define a second source graph, alter `Package.swift`, replace SwiftPM test resources, or support release/archive packaging. The app scheme permits ad-hoc signing when no stable identity is available; set `REPOPROMPT_XCODE_SIGN_IDENTITY` to choose an Apple Development identity explicitly. Ad-hoc builds use ephemeral secure storage.

Generated app, MCP, and test builds are conductor-coordinated. This coordination serializes daemon-submitted heavy work, but a running CE debug app remains exposed to filesystem activity produced by those builds/tests when they touch a watched root; the app watcher and codemap pipeline are not paused by the conductor. The app’s watcher recovery path is off the UI queue, bounded, generation-fenced, and emits debug attribution for recovery, watcher-gap invalidation, and projection preload work. Xcode cancellation can stop waiting without canceling the queued daemon job; inspect `./conductor job list` before retrying. The explicit `REPOPROMPT_XCODE_UNCOORDINATED=1` fallback is build/test-only. Xcode Run still requires conductor so its pre-launch action can perform exact-executable lifecycle handling safely.

## Validation ownership

`Scripts/test_xcode_workspace_generator.py` protects deterministic output, the thin `RepoPrompt` → `RepoPromptApp` manifest topology, bridging-header and test dependency ownership, scheme wiring, safe destinations, and stale-output detection. Default CI runs this fast contract through `make xcode-generator-test`; existing SwiftPM/conductor build and test jobs remain authoritative.

Full generated-workspace validation, including the heavier `xcodebuild -list` check in `make xcode-validate`, is explicit. Run it locally when needed, let `pr-ready` select it for executable Xcode workspace boundary changes, or use the dedicated `Xcode Workspace Validation` workflow for manual, scheduled, PR path-filtered, and `main` path-filtered hosted coverage. The hosted workflow also tracks this documentation page; docs-only changes do not broaden the local `pr-ready` lane.
