# Third-Party Notices

Original RepoPrompt CE code is released under the Apache License, Version 2.0, as provided in [`LICENSE`](LICENSE). Third-party components remain subject to their own copyright notices and license terms.

This file records attribution material for bundled source and the resolved root
SwiftPM dependency graph. It is not legal advice or a substitute for legal
review.

## Sparkle

RepoPrompt CE vendors the upstream Sparkle 2.9.2 Swift Package Manager
distribution. The copied license is included at
[`ThirdPartyLicenses/sparkle/LICENSE`](ThirdPartyLicenses/sparkle/LICENSE), and
the downloaded asset checksum and provenance are recorded under
[`Vendor/Sparkle/`](Vendor/Sparkle/).

## OpenAI Codex

RepoPrompt CE bundles the complete official OpenAI Codex 0.144.6 standalone
package for the selected macOS architecture. Codex is licensed under the
Apache License, Version 2.0. Its copied license and notice are included under
[`ThirdPartyLicenses/codex/`](ThirdPartyLicenses/codex/), and the exact release
archives, checksums, layouts, architectures, and upstream macOS signing
identities are pinned in [`Vendor/Codex/manifest.json`](Vendor/Codex/manifest.json).
The complete Codex package also contains Zsh 5.9 at
`codex-resources/zsh/bin/zsh`; its upstream licence is copied as
[`ThirdPartyLicenses/codex/ZSH-LICENCE`](ThirdPartyLicenses/codex/ZSH-LICENCE).

## UniversalCharsetDetection / uchardet

RepoPrompt CE vendors UniversalCharsetDetection and uchardet source. Their
copied licenses and author notice are included under
[`ThirdPartyLicenses/universal-charset-detection/`](ThirdPartyLicenses/universal-charset-detection/).

## PCRE2 and SLJIT

RepoPrompt CE includes PCRE2 source and its SLJIT dependency. Their copied
licenses are included at [`ThirdPartyLicenses/pcre2/LICENSE.txt`](ThirdPartyLicenses/pcre2/LICENSE.txt)
and [`ThirdPartyLicenses/sljit/LICENSE`](ThirdPartyLicenses/sljit/LICENSE).

## Tree-sitter grammar packages and runtime

RepoPrompt CE links Tree-sitter grammar package products through fixed, source-preserving SwiftPM revision pins. Those package dependencies still require attribution when distributed.

The curated [`ThirdPartyLicenses/tree-sitter/`](ThirdPartyLicenses/tree-sitter/) bundle maps the directly linked grammar products to their exact upstream repositories and revisions, and includes full license copies for the grammar packages, `SwiftTreeSitter`, its embedded Tree-sitter runtime, and the ICU subset notice shipped with that runtime.

## Resolved SwiftPM dependencies

[`ThirdPartyLicenses/swiftpm/`](ThirdPartyLicenses/swiftpm/) preserves upstream
license and notice files for every remote dependency resolved by the root Swift
package graph. Its machine-checkable
[`inventory.tsv`](ThirdPartyLicenses/swiftpm/inventory.tsv) maps each exact
resolved version or revision to its upstream repository and copied notice
bundle. Tree-sitter packages refer to the separately curated bundle above.

## Markdownosaur

Portions of the following source file are adapted from [Markdownosaur](https://github.com/christianselig/Markdownosaur) by Christian Selig, licensed under the Apache License, Version 2.0:

- `Sources/RepoPrompt/Infrastructure/UI/Markdown/EnhancedMarkdownCompiler.swift`

The adapted implementation has been substantially modified for RepoPrompt. The Apache-2.0 license text is available in the repository root [`LICENSE`](LICENSE).

## wildmatch / OpenBSD-derived fnmatch material

The repository includes wildmatch material in:

- `Sources/RepoPromptC/src/wildmatch/wildmatch.c`
- `Sources/RepoPromptC/include/wildmatch.h`

The source files state that the implementation is based on the fnmatch implementation from OpenBSD. The notice material below is reproduced from the checked-in files; no further external provenance is asserted here.

### Notice reproduced from `wildmatch.c`

```text
Copyright (c), 2016 David Aguilar
Based on the fnmatch implementation from OpenBSD.

Copyright (c) 1989, 1993, 1994
 The Regents of the University of California.  All rights reserved.

This code is derived from software contributed to Berkeley by
Guido van Rossum.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of the University nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.
```

### Notice reproduced from `wildmatch.h`

```text
Copyright (c), 2016 David Aguilar
Based on the fnmatch implementation from OpenBSD.

Copyright (c) 1992, 1993
   The Regents of the University of California.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. All advertising materials mentioning features or use of this software
   must display the following acknowledgement:
   This product includes software developed by the University of
   California, Berkeley and its contributors.
4. Neither the name of the University nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

   @(#)fnmatch.h    8.1 (Berkeley) 6/2/93
   $OpenBSD: fnmatch.h,v 1.4 1997/09/22 05:25:32 millert Exp $
```
