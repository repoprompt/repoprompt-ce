# Swift Runtime Attribution Bundle

Linux release builds embed the Swift standard library and its Foundation,
FoundationICU, Dispatch, and BlocksRuntime components when built with
`--static-swift-stdlib`. This bundle preserves upstream license and notice
files for the Swift 6.2.3 toolchain used by Linux CI. It is separate from the
SwiftPM dependency inventory and the Tree-sitter ICU subset notice.

[`inventory.tsv`](inventory.tsv) records the component, official release tag,
exact source commit, Git blob ID, upstream file URL, copied path, and SHA-256
checksum. All seven license/notice files are unchanged upstream bytes. The
Swift license also matches `usr/share/swift/LICENSE.txt` in the official
Swift 6.2.3 Ubuntu 24.04 toolchain used to validate this port.

The Swift, Foundation, Corelibs Foundation, FoundationICU package, and
libdispatch licenses contain Apache License 2.0 with the Runtime Library
Exception. The exception text is retained in each upstream copy. Foundation's
complete `NOTICE.txt` is included for its incorporated third-party code.

## FoundationICU

The FoundationICU package's Apache license does not replace the licenses of
its ICU source and embedded data. At its `swift-6.2.3-RELEASE` commit,
[`uvernum.h`](https://github.com/swiftlang/swift-foundation-icu/blob/ddd11fa3f970bd34924c418835986167b8e6efeb/icuSources/include/_foundation_unicode/uvernum.h)
declares ICU **74.1** and retains the Unicode copyright and license reference.
The package's
[`README.md`](https://github.com/swiftlang/swift-foundation-icu/blob/ddd11fa3f970bd34924c418835986167b8e6efeb/README.md)
describes its extraction from Apple's ICU distribution and embedded data.

[`swift-foundation-icu/ICU-LICENSE`](swift-foundation-icu/ICU-LICENSE) therefore
preserves the complete upstream ICU 74.1 license, including the Unicode,
IBM, dictionary data, and double-conversion notices. Its original sections
for upstream build tools are retained as part of that unchanged file; their
presence does not assert that those build tools are shipped in the Linux
executable. This ICU notice covers a different runtime component from the
Tree-sitter subset and must accompany the static runtime archive.

## Dispatch and BlocksRuntime

BlocksRuntime is built from the libdispatch source tree. Both
[`src/BlocksRuntime/runtime.c`](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/2df91f94651f2d924d7506c9d14685929386d779/src/BlocksRuntime/runtime.c)
and
[`src/BlocksRuntime/data.c`](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/2df91f94651f2d924d7506c9d14685929386d779/src/BlocksRuntime/data.c)
identify their license as Apache License 2.0 with the Runtime Library
Exception. The unchanged libdispatch `LICENSE` supplies that text for both
components.

## Verification and updates

From this directory, verify the inventory, documentation, and copied notices:

```bash
sha256sum -c SHA256SUMS
```

The Linux workflow includes this directory in
`share/licenses/repoprompt-ce/ThirdPartyLicenses/swift-runtime/` and verifies
its checksums after extracting the archive in the runtime-only job. When
changing the CI Swift toolchain version, review the corresponding official
component release tags, refresh the copied files and inventory, and regenerate
the checksums. This bundle does not inventory system libraries supplied by
the target Linux distribution or unrelated compiler/toolchain components.
