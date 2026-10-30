# Linux and Omarchy

Linux builds provide the `repoprompt-mcp` context engine and MCP server. They use
the same production domain runtime, workspace authority, parsers, protocol
catalog and mutation policies as the macOS headless backend. The native macOS
`RepoPrompt` graphical application uses SwiftUI and AppKit and is not part of the
Linux product.

The optional **native Linux desktop** is a Qt for Python application over that
same engine. It provides repository browsing, source and CodeMap previews,
content search, saved selections, prompt editing, and clipboard context assembly.
See [Native Linux desktop](#native-linux-desktop) below.

The Linux workflow targets glibc systems with a native Swift toolchain. Omarchy
and other Arch-based systems can use the terminal commands and connect an
MCP-capable editor or agent. No X11, Wayland or desktop service is required by the
server.

## Requirements

- For source builds, Swift 6.2 or newer with Swift Package Manager, a C/C++
  compiler, Git and SQLite development headers. Python 3 runs the build coordinator
  and smoke tests.
- A glibc distribution with **glibc 2.34 or newer**. The toolchain and compiled
  executable may require a newer version. Alpine/musl and a fully static Linux
  SDK build are not validated by this workflow.
- Provider CLI authentication for provider-backed operations. Reading repositories,
  managing selections and editing the stored prompt do not require a model account.

CI pins **Swift 6.2.3 on Ubuntu 24.04** and has separate native **x86_64** and
**aarch64** jobs. A configured matrix is not evidence that every distribution or
architecture has passed: check the Linux workflow result for the commit you are
using. Cross-architecture compilation, macOS-to-Linux SDK builds and the macOS GUI
are outside this build path.

The glibc floor comes from the process launcher's descriptor isolation:
[`posix_spawn_file_actions_addclosefrom_np` was added in glibc 2.34](https://sourceware.org/pipermail/glibc-cvs/2021q3/073654.html).
An executable built on Ubuntu 24.04 is not a claim of binary compatibility with
every distribution that meets that source-level minimum.

### Omarchy / Arch Linux

Install the native build prerequisites:

```bash
sudo pacman -S --needed base-devel git clang pkgconf sqlite python
```

Install the Swift programming-language toolchain. Arch's
[Swift documentation](https://wiki.archlinux.org/title/Swift) lists `swift-bin`
and `swift-language` in the AUR. For systems using `yay`, the binary toolchain is:

```bash
yay -S swift-bin
swift --version
```

Review the AUR package normally before installing it. Its current Swift version
may differ from CI's pinned version. The `swift` packages associated with
OpenStack are unrelated to the Swift compiler.

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install git clang make pkg-config python3 libsqlite3-dev
```

Then install the Swift compiler and its runtime prerequisites using the
[official distribution-specific Swift instructions](https://www.swift.org/install/linux/).
Use the toolchain built for your distribution; copying a Ubuntu toolchain onto
another distribution can leave missing shared libraries.

### Fedora

```bash
sudo dnf install git clang gcc-c++ make pkgconf-pkg-config python3 sqlite-devel
```

Install Swift and its runtime prerequisites from the
[official Fedora instructions](https://www.swift.org/install/linux/fedora/).

### Optional image conversion

The shared attachment normalizer uses ImageMagick on Linux to convert HEIC,
TIFF, BMP and AVIF to PNG or JPEG. It accepts ImageMagick 7's `magick` command or
ImageMagick 6's `identify` and `convert`, found on `PATH`. PNG, JPEG, GIF and WebP
attachments retain their normal byte-preserving path without this dependency.

| Distribution | Optional packages |
| --- | --- |
| Omarchy / Arch | `sudo pacman -S --needed imagemagick libheif libtiff libjpeg-turbo` |
| Ubuntu / Debian | `sudo apt-get install imagemagick` |
| Fedora | `sudo dnf install ImageMagick ImageMagick-heic` |

Codec availability also depends on the distribution's ImageMagick build and
installed codec libraries; see the [Arch package dependencies](https://archlinux.org/packages/extra/x86_64/imagemagick/),
[Debian package](https://packages.debian.org/stable/imagemagick) and
[Fedora HEIC plugin](https://packages.fedoraproject.org/pkgs/ImageMagick/ImageMagick-heic/).
A missing converter or unsupported codec returns an explicit conversion error.
Conversions enforce source-dimension limits, a 20 MiB output limit and a deadline
for each subprocess. Direct Oracle image attachments and native thumbnail UI
remain unavailable in this headless backend.

## Build and install

From a checkout containing the Linux changes:

```bash
./Scripts/build_linux.sh release
./Scripts/install_linux.sh
```

The build script selects the `repoprompt-mcp` product and avoids the macOS app
dependency graph. Installation copies the compiled executable to
`~/.local/bin/repoprompt-mcp`. It does not install packages, modify shell startup
files, start a server or ask for administrator privileges.

If `~/.local/bin` is not already on your shell's `PATH`, add it through your normal
shell configuration. You can use the absolute path immediately:

```bash
"$HOME/.local/bin/repoprompt-mcp" --version
```

Updating an existing installation requires an explicit replacement:

```bash
./Scripts/install_linux.sh --replace
```

Identical binaries are accepted without replacement. Symlinks and directories
at the destination are preserved, even with `--replace`. To install somewhere
else, or install a binary built with a custom SwiftPM scratch path:

```bash
./Scripts/install_linux.sh --prefix "$HOME/apps/repoprompt-ce" --binary /absolute/path/to/repoprompt-mcp
```

For a debug build:

```bash
./Scripts/build_linux.sh debug
CONFIGURATION=debug ./Scripts/install_linux.sh --prefix "$HOME/apps/repoprompt-ce-debug"
```

The build script enables `--static-swift-stdlib` by default for release builds,
including the Swift runtime in the executable. System libraries remain dynamically
linked. Debug builds use the ordinary dynamic Swift runtime. Set
`REPOPROMPT_LINUX_STATIC_SWIFT=0` to opt out for a release build; such binaries also
require a compatible Swift runtime installed at execution time. See Swift's
[static Swift runtime guidance](https://docs.swift.org/latest/documentation/swiftlinux/building/).

### Runtime libraries and CI archives

CI produces separate Ubuntu 24.04 archives for x86_64 and aarch64. It strips debug
information from the staged release executable, then tests that installed copy.
An additional job extracts each archive into a plain Ubuntu 24.04 container and
runs the bundled smoke script without a Swift toolchain or source checkout.

The system runtime packages for the Ubuntu 24.04 build are:

```bash
sudo apt-get install libc6 libstdc++6 libgcc-s1 libcurl4t64 libsqlite3-0 git ca-certificates
```

The executable links libcurl, SQLite, the GNU C/C++ runtimes, libm and the system
loader. It includes the Swift, Foundation, ICU and Dispatch runtime components.
The verified x86_64 release executable requires **glibc 2.38 or newer**; this is
stricter than the source-level glibc 2.34 minimum. The aarch64 artifact's actual
glibc requirement is printed by its native CI runtime job and must be checked
separately. Use Ubuntu 24.04 for these CI archives, and build natively on Omarchy
or another distribution to match its toolchain and system libraries.

Download the archive for your architecture from a successful Linux workflow run
and extract it into a dedicated directory. For example, for x86_64:

```bash
mkdir -p repoprompt-ce-linux
tar -C repoprompt-ce-linux -xzf repoprompt-ce-linux-x86_64.tar.gz
"$PWD/repoprompt-ce-linux/bin/repoprompt-mcp" --version
```

Use that executable's absolute path in the CLI or MCP configuration. The archive
also contains this guide, the smoke script and complete license notices under
`share/`.

## Native Linux desktop

The desktop frontend requires Python 3.10 or newer, pip, Qt's system libraries,
and an X11 or Wayland desktop session. It uses the installed `repoprompt-mcp`
executable; it does not require Swift at runtime when that executable includes
the static Swift runtime. The GUI installer downloads **PySide6 Essentials 6.10.3** and its
dependencies from PyPI into a private application directory. Qt's wheels have
their own distribution/glibc requirements, separate from the engine's.

Install the additional desktop prerequisites:

```bash
# Omarchy / Arch
sudo pacman -S --needed python-pip libglvnd libxkbcommon-x11 xcb-util-cursor xcb-util-wm xcb-util-keysyms

# Ubuntu / Debian
sudo apt-get install python3-pip libegl1 libgl1 libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4 libxcb-keysyms1

# Fedora
sudo dnf install python3-pip libglvnd-egl libglvnd-glx libxkbcommon-x11 xcb-util-cursor xcb-util-wm xcb-util-keysyms
```

After building and installing the engine:

```bash
python3 Scripts/install_linux_gui.py
repoprompt-gui ~/src/project
```

The installer creates `~/.local/bin/repoprompt-gui` and an application-menu entry
named **RepoPrompt CE**. It does not launch the app. Add `~/.local/bin` to your
normal `PATH` if needed, or use its absolute path. Updating an existing managed
installation requires `--replace`; symlinks and unrelated directories are
preserved. A failed dependency download leaves the old installation intact.

For a custom prefix or an existing Python environment containing PySide6:

```bash
python3 Scripts/install_linux_gui.py --prefix "$HOME/apps/repoprompt-ce" \
  --engine "$HOME/.local/bin/repoprompt-mcp" --python /path/to/venv/bin/python --no-deps
```

Custom prefixes place the desktop file under that prefix's `share/applications`;
the session must search that share directory through `XDG_DATA_DIRS` to show it
in the application menu. The command-line launcher works directly.

In the app, open a repository, click a file to preview it, and choose **Add to
context**. Search finds literal text in the repository; double-click a result to
open its file. **Show CodeMap** displays the engine's source signatures. Write
instructions in the prompt editor and use **Save prompt** / Ctrl+S to persist
them. **Copy context** assembles the current prompt text and full selected text
files as Markdown for pasting into an editor or agent. It supports up to 100 files
and 2 MiB; read errors leave the clipboard unchanged. Source files are read-only
in this frontend, and symlinks are excluded from browser navigation.

The window owns a persistent MCP stdio connection and shuts it down on close.
Each repository/engine path gets a separate GUI profile under
`$XDG_DATA_HOME/repoprompt-ce-linux-gui` (default `~/.local/share`). Desktop
preferences use `$XDG_CONFIG_HOME/repoprompt-ce-linux-gui`. `--profile-dir`
selects a dedicated profile; it must belong to the selected repository.

This first native frontend focuses on context composition. It does not expose
the macOS application's full Agent Mode, Overseer, session administration, or
native editor integrations. Its clipboard assembly reads through the existing
engine; CLI `workspace_context` snapshots retain their existing behavior.

For development without installing the application menu entry, follow
[`Apps/RepoPromptLinux/README.md`](../Apps/RepoPromptLinux/README.md), or run
`REPOPROMPT_GUI_PYTHON=/path/to/venv/bin/python Scripts/run_linux_gui.sh /path/to/repository`.
Linux CI exercises native x86_64 and aarch64 Qt workflows against each release
engine, tests the desktop installer, and uploads the Python wheel and a captured
window image. Check the workflow result for the actual commit before claiming
an architecture passed.

## Use the terminal CLI

Choose an existing repository and a dedicated profile directory. Keep those
environment variables for later commands to reuse saved workspace state:

```bash
export REPOPROMPT_MCP_HEADLESS_PROFILE_DIR="$HOME/.local/share/repoprompt-ce-projects/example"
export REPOPROMPT_MCP_WORKING_DIRS="$HOME/src/example"

repoprompt-mcp -l
repoprompt-mcp -e 'tree'
repoprompt-mcp -c read_file -j '{"path":"README.md"}'
repoprompt-mcp -i
```

Replace the example repository path and choose a file that exists in that
repository for `read_file`. `-l` lists tools, `-e` executes a CLI command, `-c`
calls an MCP tool with JSON arguments, and `-i` opens the existing interactive
REPL. Use `exit` to leave the REPL. `--raw-json` requests machine-readable tool
results. `--help` describes the Linux modes and supported options.

Each invocation runs the production headless backend inside its own process.
It reads persistent state from the selected profile; it does not attach to the
in-memory session of an already running stdio server or another CLI invocation.

### Agent lifetime

The owning MCP connection or REPL must remain open while its provider processes
run. Closing it cancels remaining provider work. Saved profiles retain durable
workspace state and history, but another invocation cannot reattach to the old
in-memory agent tasks.

Single-command `--exec` and `--call` invocations reject detached agent starts
before dispatch. If a foreground agent wait returns `running` or
`waiting_for_input`, the command reports an error explaining that exit will
cancel the unfinished work. Use a long-lived MCP client connection or keep the
REPL open to start, poll and wait for agents.

## Connect an MCP client

Start with an explicit profile directory and repository root. This permits a
new Linux installation to create its initial workspace without relying on a
workspace previously saved by the macOS app.

The following is the common `mcpServers` configuration shape; use your client's
MCP settings and replace every `/home/alice` path with an absolute path on your
machine. JSON configuration does not expand `~` or shell variables.

```json
{
  "mcpServers": {
    "repoprompt": {
      "command": "/home/alice/.local/bin/repoprompt-mcp",
      "args": ["--backend", "headless"],
      "env": {
        "REPOPROMPT_MCP_HEADLESS_PROFILE_DIR": "/home/alice/.local/share/repoprompt-ce-projects/example",
        "REPOPROMPT_MCP_WORKING_DIRS": "/home/alice/src/example"
      }
    }
  }
}
```

Use colon-separated absolute paths for multiple repository roots. Each root must
exist and be a directory. Linux defaults to the headless backend; the explicit
flag makes the intended mode clear and also works with the macOS executable.
The client starts and owns the stdio server process; it is not an HTTP service
and needs no listening TCP port.

`repoprompt-mcp -i` starts the terminal REPL. An MCP client supplies pipes for the
server's standard input and output. Running `--backend headless` with either
stream attached to a terminal prints quick-start usage and exits.

### Profiles and permissions

Without an explicit profile directory, Linux stores release data under
`$XDG_DATA_HOME/repoprompt-ce`, falling back to `~/.local/share/repoprompt-ce`.
Debug data uses `repoprompt-ce-debug` in the same base directory. MCP discovery
configuration is under the release data root's `MCP` directory; runtime sockets
use owner-validated private directories under `/tmp`.

`REPOPROMPT_MCP_HEADLESS_PROFILE_DIR` selects an explicit storage boundary. A
nondefault `REPOPROMPT_MCP_HEADLESS_PROFILE` requires that explicit directory.
Debug profile isolation may add a build/profile-specific subdirectory inside
the selected directory. Workspace roots are not inferred from the process's
current directory.

File mutations and model-cost operations retain the headless backend's consent
policy. A tool being listed does not grant permission to execute it. Start with
read-only repository operations; run `repoprompt-mcp policy` from an interactive
terminal to display the grant-management usage. Keep the same profile environment
for the policy command and the MCP server. Do not copy policy files between unrelated profiles
or bypass the checks to make an unavailable operation appear to succeed.

## Feature boundaries

The Linux port exposes the existing headless backend. It does not turn its
existing limitations into desktop feature parity.

| Capability | Linux headless behavior |
| --- | --- |
| Workspace roots, file reads, search, project structure | Uses the shared production runtime |
| CodeMaps and Git queries | Uses the existing headless adapters and domain services |
| Selection and prompt management | Persists selected paths and prompt text in the chosen profile |
| `workspace_context` snapshot | Returns prompt text, selected paths, roots, workspace ID and context ID |
| `workspace_context` export | Writes prompt text and a selected-path list; assembled selected-file contents and frozen-pack creation remain unavailable |
| File creation, edits, moves | Requires the existing explicit mutation policy and root checks |
| File deletion | Currently refused by the direct backend |
| Agent execution | The direct provider catalog currently supports Codex CLI; provider installation and authentication are separate |
| Agent management | `agent_manage` supports provider/session listing, workflow listing and cancellation; `create_session` and `resume_session` remain unavailable |
| Context Builder | One-shot Oracle inference; autonomous discovery, app presets, selection commits and response export require the app-backed implementation |
| Multiple Oracle models | Requires an existing canonical frozen context pack; the direct backend does not create these packs |
| Overseer / session links / window selection | App-dependent operations remain unavailable |
| Interactive user-input UI | No elicitation-capable client adapter is currently registered |
| Native graphical app, menu bar, Keychain, Sparkle updater | macOS only |

Use the normal capability results and explicit errors when deciding what a
client may invoke. Installing a provider does not add all of the macOS app's
provider integrations to the headless runtime.

## Verification

Run the real executable smoke test after building:

```bash
python3 Scripts/linux_headless_smoke.py --binary "$(swift build -c release --show-bin-path)/repoprompt-mcp"
python3 -m unittest discover -s Scripts/tests -p test_install_linux.py
./conductor test --filter 'Linux|RepoPromptProcessTests|RepoPromptMCPCoreTests|RepoPromptVCSTests|DomainMutationPhysicalCapabilityTests|MCPDomainHeadlessFileReaderTests|OracleGroupPersistenceTests|CodeMapSyntaxArtifactTests|DomainProtectedMutationSecurityTests|OracleGroupRuntimeTests'
```

Run the test command as your ordinary user. CI's Swift container runs as root,
so its test step starts a separate build coordinator with filesystem permission
bypass capabilities removed. This lets the same permission-denial tests run
without being skipped.

The Linux CI workflow builds and exercises the actual product on each native
runner, checks installation, then repeats the runtime smoke against the installed
executable from outside the checkout. The smoke covers real file reads, search,
CodeMaps, selection and prompt persistence, context snapshots, mutation consent,
root confinement, terminal CLI modes and rejection of detached one-shot agent
starts. The Swift gate covers Linux portability and the Process, MCP transport
and VCS suites, plus protected mutation, file-reader, Oracle runtime/persistence
and parser tests. This selection does not assert that every legacy test suite
has Linux coverage. Finally, the archive runtime job checks actual ELF dependencies,
verifies the bundled runtime license checksums and runs the same smoke without
Swift installed. macOS build and app tests remain in the existing CI workflow.

The Swift image/version and native runner labels are documented in
[Swift's Ubuntu download list](https://www.swift.org/install/linux/ubuntu/24_04/)
and [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

The remaining full headless-workflow and platform-parity work is tracked in
[#1408](https://github.com/repoprompt/repoprompt-ce/issues/1408),
[#1409](https://github.com/repoprompt/repoprompt-ce/issues/1409) and
[#1411](https://github.com/repoprompt/repoprompt-ce/issues/1411). A successful
Linux build does not by itself complete those behavioral acceptance criteria.
