# Tree-sitter Attribution Bundle

RepoPrompt CE links the `SwiftTreeSitter` wrapper, the Tree-sitter runtime, and
Tree-sitter grammar package products through exact, source-preserving SwiftPM
pins. This directory maps the resolved components to their copied licenses.

## Grammar packages

| Grammar | Upstream repository | Exact requirement | Resolved revision | SwiftPM product/modules | License copy |
| --- | --- | --- | --- | --- | --- |
| C | <https://github.com/tree-sitter/tree-sitter-c> | `0.24.2` | `b780e47fc780ddc8da13afa35a3f4ed5c157823d` | `TreeSitterC` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| Dart | <https://github.com/UserNobody14/tree-sitter-dart> | revision (no releases) | `be07cf7118d3dba06236a3f19541685a68209934` | `TreeSitterDart` | [`LICENSE-tree-sitter-dart.txt`](LICENSE-tree-sitter-dart.txt) |
| Go | <https://github.com/tree-sitter/tree-sitter-go> | `0.25.0` | `1547678a9da59885853f5f5cc8a99cc203fa2e2c` | `TreeSitterGo` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| Java | <https://github.com/tree-sitter/tree-sitter-java> | `0.23.5` | `94703d5a6bed02b98e438d7cad1136c01a60ba2c` | `TreeSitterJava` | [`LICENSE-tree-sitter-java.txt`](LICENSE-tree-sitter-java.txt) |
| JavaScript | <https://github.com/tree-sitter/tree-sitter-javascript> | `0.25.0` | `44c892e0be055ac465d5eeddae6d3e194424e7de` | `TreeSitterJavaScript` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| Python | <https://github.com/tree-sitter/tree-sitter-python> | `0.25.0` | `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | `TreeSitterPython` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |
| Rust | <https://github.com/tree-sitter/tree-sitter-rust> | `0.24.2` | `77a3747266f4d621d0757825e6b11edcbf991ca5` | `TreeSitterRust` | [`LICENSE-tree-sitter-rust.txt`](LICENSE-tree-sitter-rust.txt) |
| TypeScript / TSX | <https://github.com/tree-sitter/tree-sitter-typescript> | `0.23.2` | `f975a621f4e7f532fe322e13c4f79495e0a7b2e7` | `TreeSitterTypeScript` (`TreeSitterTypeScript`, `TreeSitterTSX`) | [`LICENSE-tree-sitter-typescript.txt`](LICENSE-tree-sitter-typescript.txt) |
| Ruby | <https://github.com/tree-sitter/tree-sitter-ruby> | `0.23.1` | `71bd32fb7607035768799732addba884a37a6210` | `TreeSitterRuby` | [`LICENSE-tree-sitter-ruby.txt`](LICENSE-tree-sitter-ruby.txt) |
| Swift | <https://github.com/alex-pinkus/tree-sitter-swift> | `0.7.3-with-generated-files` | `31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5` | `TreeSitterSwift` | [`LICENSE-tree-sitter-swift.txt`](LICENSE-tree-sitter-swift.txt) |
| C# | <https://github.com/tree-sitter/tree-sitter-c-sharp.git> | `0.23.5` | `cac6d5fb595f5811a076336682d5d595ac1c9e85` | `TreeSitterCSharp` | [`LICENSE-tree-sitter-c-sharp.txt`](LICENSE-tree-sitter-c-sharp.txt) |
| C++ | <https://github.com/tree-sitter/tree-sitter-cpp> | `0.23.4` | `f41e1a044c8a84ea9fa8577fdd2eab92ec96de02` | `TreeSitterCPP` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| PHP | <https://github.com/tree-sitter/tree-sitter-php.git> | `0.24.2` | `5b5627faaa290d89eb3d01b9bf47c3bb9e797dea` | `TreeSitterPHP` | [`LICENSE-tree-sitter-php.txt`](LICENSE-tree-sitter-php.txt) |

Dart remains at its canonical maintained revision because the repository publishes no semantic-version releases. SwiftPM accepts Swift's buildable `0.7.3-with-generated-files` companion tag as an exact semantic version; its plain `0.7.3` release omits generated parser sources. The resolved revisions above remain the CodeMap grammar/cache identity inputs.

The C, Go, JavaScript, and C++ snapshots contain identical MIT license text,
so they intentionally share one copy.

## JavaScript and Python scanner linker compatibility snapshots

The JavaScript and Python package manifests list `scanner.c` conditionally, but
their manifest-time `FileManager` source probes evaluate false in this root
package graph. A clean coordinated link without the shim fails on their
external-scanner ABI symbols. RepoPrompt CE therefore retains a narrow internal
`Sources/TreeSitterScannerSupport` C target with byte-for-byte copies of only
the missing scanner implementations and required helper headers.

| CE source path | Exact upstream snapshot source | Applicable license copy |
| --- | --- | --- |
| `Sources/TreeSitterScannerSupport/src/javascript/scanner.c` | `tree-sitter-javascript/src/scanner.c` at `44c892e0be055ac465d5eeddae6d3e194424e7de` | [`LICENSE-tree-sitter-max-brunsfeld-2014.txt`](LICENSE-tree-sitter-max-brunsfeld-2014.txt) |
| `Sources/TreeSitterScannerSupport/src/python/scanner.c` | `tree-sitter-python/src/scanner.c` at `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |
| `Sources/TreeSitterScannerSupport/include/tree_sitter/parser.h` | Byte-identical in both exact snapshots above | Same grammar license copies above |
| `Sources/TreeSitterScannerSupport/include/tree_sitter/array.h` | `tree-sitter-python/src/tree_sitter/array.h` at `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |
| `Sources/TreeSitterScannerSupport/include/tree_sitter/alloc.h` | `tree-sitter-python/src/tree_sitter/alloc.h` at `293fdc02038ee2bf0e2e206711b69c90ac0d413f` | [`LICENSE-tree-sitter-python.txt`](LICENSE-tree-sitter-python.txt) |

[`scanner-support.sha256`](scanner-support.sha256) records the copied-file
checksums. Remove this compatibility target, its checksum file, guardrails, and
documentation exception together only after a clean coordinated link proves a
future upstream graph compiles the scanner objects directly.

## Swift wrapper, runtime, and ICU subset

`SwiftTreeSitter` 0.10.0 resolves the standalone Tree-sitter 0.25.10 SwiftPM
package. That runtime includes a small subset of ICU headers and the
corresponding full ICU notice file.

| Component | Source | Resolved version / revision | License copy |
| --- | --- | --- | --- |
| `SwiftTreeSitter` | <https://github.com/ChimeHQ/SwiftTreeSitter.git> | `0.10.0` / `f97df585296977d8fcaf644cbde567151d1367b8` | [`LICENSE-SwiftTreeSitter.txt`](LICENSE-SwiftTreeSitter.txt) |
| Tree-sitter runtime | <https://github.com/tree-sitter/tree-sitter> | `0.25.10` / `da6fe9beb4f7f67beb75914ca8e0d48ae48d6406` | [`LICENSE-tree-sitter-runtime.txt`](LICENSE-tree-sitter-runtime.txt) |
| ICU subset used by the runtime | <https://github.com/unicode-org/icu> | `552b01f61127d30d6589aa4bf99468224979b661` from `ICU_SHA` | [`LICENSE-tree-sitter-runtime-ICU.txt`](LICENSE-tree-sitter-runtime-ICU.txt) |

The ICU file is preserved in full because it contains the applicable ICU
copyright and permission notice plus additional third-party notices.
