# SwiftPM Attribution Bundle

RepoPrompt CE packages the upstream license and notice files for every remote
dependency resolved by the root Swift package graph.

[`inventory.tsv`](inventory.tsv) is the machine-checkable inventory. Its columns
are:

```text
identity    resolved version or revision    upstream repository    notice bundle
```

Packages with a directory in this folder preserve the top-level license and
notice files shipped by the exact resolved checkout. `swift-nio/CNIOLLHTTP`
also preserves the license for the compiled llhttp-derived C target.

Tree-sitter grammar packages and the customized `SwiftTreeSitter` wrapper use
the separately curated [`../tree-sitter/`](../tree-sitter/) bundle. The wrapper
is fixed to its approved remote revision; the bundle includes the linked grammar
snapshots, wrapper license, resolved runtime license, and ICU subset notice. Its
own `SHA256SUMS` file protects the complete curated bundle.

[`SHA256SUMS`](SHA256SUMS) records checksums for the copied notice files. Run:

```bash
./Scripts/swiftpm_notice_guardrails.sh
```

after changing `Package.resolved` or any copied notice file.
