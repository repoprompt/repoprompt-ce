# Sparkle Vendoring Provenance

RepoPrompt CE vendors the Sparkle `2.9.2` Swift Package Manager distribution from the upstream Sparkle GitHub release:

- Release: `https://github.com/sparkle-project/Sparkle/releases/tag/2.9.2`
- Asset: `Sparkle-for-Swift-Package-Manager.zip`
- Download URL: `https://github.com/sparkle-project/Sparkle/releases/download/2.9.2/Sparkle-for-Swift-Package-Manager.zip`
- SHA-256: `b83e37436774556ed055e0244b297ef2c790e0737393bf65bf495fcbba6eed65`

Vendored contents:

- `Sparkle.xcframework`, including `macos-arm64_x86_64/dSYMs`
- `bin/BinaryDelta`
- `bin/generate_appcast`
- `bin/generate_keys`
- `bin/sign_update`
- `LICENSE`

The vendored binaries are copied without source modification from the upstream release asset.

The upstream `dSYMs` directory (five `.dSYM` bundles, about 20.8 MB) was
initially omitted because the repository `.gitignore` rule `*.dSYM/` silently
excluded it when Sparkle was vendored. The XCFramework `Info.plist` declares
`DebugSymbolsPath = dSYMs`, and Xcode 27 fails builds when that declared path is
missing, so the unmodified upstream bundles were restored from the verified
release asset above and a narrow `.gitignore` exception keeps them tracked.
`SHA256SUMS` lists the release asset checksum followed by per-file checksums for
the restored dSYM files. `Scripts/xcframework_declared_paths_guardrails.sh`
fails `make guardrails` if a vendored XCFramework declares a path that does not
exist on disk.

[`INSTALLED_MANIFEST.tsv`](INSTALLED_MANIFEST.tsv) records the complete installed
framework and trusted command-line tool tree, including entry types, symlink
targets, and SHA-256 checksums for regular files. Release preflight verifies that
closed-world manifest before building.
