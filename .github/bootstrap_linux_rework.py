#!/usr/bin/env python3
"""Create the focused Linux headless implementation from the current branch.

This script is intentionally used only by the one-shot bootstrap workflow. It
starts with the current branch (which was created from upstream main), borrows
only the old branch's Linux portability helpers, and writes the final scoped
implementation.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[1]
LEGACY_REF = "refs/remotes/origin/legacy-linux-headless"


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True)


def legacy(path: str) -> str:
    return git("show", f"{LEGACY_REF}:{path}")


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, content: str, *, executable: bool = False) -> None:
    destination = ROOT / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content, encoding="utf-8")
    if executable:
        destination.chmod(0o755)


def replace_once(path: str, old: str, new: str) -> None:
    content = read(path)
    if old not in content:
        raise RuntimeError(f"expected text not found in {path}: {old[:120]!r}")
    write(path, content.replace(old, new, 1))


def replace_all(path: str, old: str, new: str) -> None:
    content = read(path)
    if old not in content:
        raise RuntimeError(f"expected text not found in {path}: {old[:120]!r}")
    write(path, content.replace(old, new))


def replace_regex(path: str, pattern: str, replacement: str, *, count: int = 0) -> None:
    content = read(path)
    updated, substitutions = re.subn(pattern, replacement, content, count=count, flags=re.MULTILINE | re.DOTALL)
    if substitutions == 0:
        raise RuntimeError(f"expected regex not found in {path}: {pattern[:120]!r}")
    write(path, updated)


def current_marketing_version() -> str:
    for line in read("version.env").splitlines():
        if line.startswith("MARKETING_VERSION="):
            return line.split("=", 1)[1].strip().strip('"')
    raise RuntimeError("MARKETING_VERSION missing from version.env")


def install_linux_manifest() -> None:
    current = read("Package.swift")
    if "#if os(Linux)" in current:
        raise RuntimeError("Package.swift already contains a Linux manifest branch")
    legacy_manifest = legacy("Package.swift")
    start = legacy_manifest.index("#if os(Linux)")
    end = legacy_manifest.index("#else\nlet packageRoot", start)
    linux_branch = legacy_manifest[start:end]

    linux_branch = linux_branch.replace(
        '                    "DirectHeadlessOracleCoordinator.swift",\n',
        "",
    )
    if '"DirectHeadlessWorktreeRouting.swift"' not in linux_branch:
        linux_branch = linux_branch.replace(
            '                    "DirectHeadlessRuntimeConfiguration.swift",\n',
            '                    "DirectHeadlessRuntimeConfiguration.swift",\n'
            '                    "DirectHeadlessWorktreeRouting.swift",\n',
        )

    import_marker = "import PackageDescription\n"
    marker_end = current.index(import_marker) + len(import_marker)
    header = current[:marker_end]
    macos_body = current[marker_end:].lstrip("\n")
    wrapped = (
        header
        + "\n"
        + linux_branch
        + "#else\n"
        + macos_body.rstrip()
        + "\n#endif\n"
    )
    write("Package.swift", wrapped)


def install_portability_helpers() -> None:
    write(
        "Sources/RepoPromptMCP/LinuxHeadlessMain.swift",
        legacy("Sources/RepoPromptMCP/LinuxHeadlessMain.swift"),
    )
    write(
        "Sources/RepoPromptMCP/POSIXSocketCompatibility.swift",
        legacy("Sources/RepoPromptMCP/POSIXSocketCompatibility.swift"),
    )
    write(
        "Sources/RepoPromptMCP/DirectHeadlessClientIdentity.swift",
        legacy("Sources/RepoPromptMCP/DirectHeadlessClientIdentity.swift"),
    )
    write(
        "Sources/RepoPromptMCP/CLIProductVersion.swift",
        textwrap.dedent(
            f"""\
            #if os(Linux)
            /// Shipped Linux MCP executable version. CI verifies it against
            /// `version.env`; the macOS executable keeps its existing source.
            let CLI_VERSION = "{current_marketing_version()}"
            #endif
            """
        ),
    )

    # These legacy versions contain portability-only changes and otherwise match
    # the current ownership boundary.
    for path in (
        "Sources/RepoPromptMCP/DirectHeadlessChildBridge.swift",
        "Sources/RepoPromptShared/MCP/BestEffortStderrWriter.swift",
        "Sources/RepoPromptShared/MCP/MCPFilesystemIdentity.swift",
        "Sources/RepoPromptShared/MCP/POSIXDescriptorSupport.swift",
    ):
        write(path, legacy(path))


def patch_cryptokit_imports() -> None:
    roots = [
        ROOT / "Sources/RepoPromptShared",
        ROOT / "Sources/RepoPromptDomainRuntime",
        ROOT / "Sources/RepoPromptCodeMapCore",
        ROOT / "Sources/RepoPromptMCP",
    ]
    replacement = textwrap.dedent(
        """\
        #if canImport(CryptoKit)
            import CryptoKit
        #elseif canImport(Crypto)
            import Crypto
        #endif
        """
    ).rstrip()
    for root in roots:
        for path in root.rglob("*.swift"):
            content = path.read_text(encoding="utf-8")
            updated = re.sub(r"(?m)^import CryptoKit$", replacement, content)
            if updated != content:
                path.write_text(updated, encoding="utf-8")


def patch_child_endpoint() -> None:
    path = "Sources/RepoPromptMCP/DirectHeadlessChildEndpoint.swift"
    replace_once(
        path,
        "import Darwin\n",
        "#if canImport(Darwin)\n    import Darwin\n#elseif canImport(Glibc)\n    import Glibc\n#endif\n",
    )
    replace_once(path, "let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)", "let fd = rpMakeUnixStreamSocket()")
    replace_once(
        path,
        "        var noSigPipe: Int32 = 1\n"
        "        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))",
        "        _ = rpConfigureNoSIGPIPE(fd)",
    )
    replace_once(
        path,
        "            var noSigPipe: Int32 = 1\n"
        "            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))",
        "            _ = rpConfigureNoSIGPIPE(clientFD)",
    )
    replacements = {
        "Darwin.close": "close",
        "Darwin.bind": "bind",
        "Darwin.listen": "listen",
        "Darwin.poll": "poll",
        "Darwin.accept": "accept",
        "Darwin.read": "read",
        "Darwin.shutdown(listener, SHUT_RDWR)": "rpShutdownReadWrite(listener)",
        "Darwin.shutdown(client.fd, SHUT_RDWR)": "rpShutdownReadWrite(client.fd)",
    }
    content = read(path)
    for old, new in replacements.items():
        content = content.replace(old, new)
    write(path, content)
    replace_regex(
        path,
        r"    private nonisolated static func peerPID\(fd: Int32\) -> Int32\? \{\n.*?\n    \}\n\n"
        r"    private nonisolated static func identity",
        "    private nonisolated static func peerPID(fd: Int32) -> Int32? {\n"
        "        rpPeerProcessID(fd)\n"
        "    }\n\n"
        "    private nonisolated static func identity",
        count=1,
    )


def patch_stdio_transport() -> None:
    path = "Sources/RepoPromptMCP/MCPStdioServerTransport.swift"
    replace_once(
        path,
        "import Darwin\n",
        "#if canImport(Darwin)\n    import Darwin\n#elseif canImport(Glibc)\n    import Glibc\n#endif\n",
    )
    old = """\
        var noSigPipe: Int32 = 1
        guard setsockopt(
            stdoutFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 || errno == ENOTSOCK else {
            throw TerminalError.stdoutWrite(errno: errno, bytesWritten: 0, totalBytes: 0)
        }
"""
    new = """\
#if canImport(Darwin)
        var noSigPipe: Int32 = 1
        guard setsockopt(
            stdoutFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 || errno == ENOTSOCK else {
            throw TerminalError.stdoutWrite(errno: errno, bytesWritten: 0, totalBytes: 0)
        }
#else
        _ = rpConfigureNoSIGPIPE(stdoutFD)
#endif
"""
    replace_once(path, old, new)


def patch_service() -> None:
    path = "Sources/RepoPromptMCP/DirectHeadlessMCPService.swift"
    replace_once(
        path,
        "import Darwin\n",
        "#if canImport(Darwin)\n    import Darwin\n#elseif canImport(Glibc)\n    import Glibc\n#endif\n",
    )
    replace_all(path, "Darwin.shutdown(fd, SHUT_RDWR)", "rpShutdownReadWrite(fd)")
    replace_all(path, "CLIEventLogger.detectClientName()", "DirectHeadlessClientIdentity.detectParentExecutableName()")
    replace_regex(
        path,
        r"    nonisolated static func verifiedExecutableFingerprint\(processID: Int32\) -> String\? \{\n.*?\n    \}\n\n"
        r"    private nonisolated static func childPolicyProfile",
        """\
    nonisolated static func verifiedExecutableFingerprint(processID: Int32) -> String? {
        guard let executablePath = rpExecutablePath(processID: processID) else { return nil }
        let path = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let material = "\(path)|\(info.st_dev)|\(info.st_ino)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func childPolicyProfile""",
        count=1,
    )


def write_runtime_files() -> None:
    write(
        "Dockerfile.headless",
        textwrap.dedent(
            """\
            FROM swift:6.2.1-noble AS build

            RUN apt-get update \
                && apt-get install --yes --no-install-recommends \
                    ca-certificates \
                    g++ \
                    git \
                    libstdc++-14-dev \
                    pkg-config \
                    python3 \
                && rm -rf /var/lib/apt/lists/*

            WORKDIR /src
            COPY . .

            ARG SWIFT_JOBS=4
            RUN swift build \
                    --configuration release \
                    --jobs "$SWIFT_JOBS" \
                    --product repoprompt-mcp \
                    --static-swift-stdlib \
                && BINARY="$(swift build --configuration release --show-bin-path)/repoprompt-mcp" \
                && "$BINARY" --version \
                && python3 Scripts/test_linux_headless_mcp.py binary "$BINARY" \
                && install -D -m 0755 "$BINARY" /out/repoprompt-mcp

            FROM ubuntu:24.04 AS runtime

            RUN apt-get update \
                && apt-get install --yes --no-install-recommends \
                    ca-certificates \
                    git \
                    libcurl4t64 \
                    libstdc++6 \
                    tini \
                && groupadd --gid 65532 repoprompt \
                && useradd --uid 65532 --gid 65532 --home-dir /home/repoprompt \
                    --create-home --shell /usr/sbin/nologin repoprompt \
                && install -d -m 0700 -o 65532 -g 65532 /data \
                && install -d -o 65532 -g 65532 /workspace \
                && git config --system --add safe.directory /workspace \
                && git config --system --add safe.directory '/workspace/*' \
                && rm -rf /var/lib/apt/lists/*

            COPY --from=build /out/repoprompt-mcp /usr/local/bin/repoprompt-mcp

            RUN ! ldd /usr/local/bin/repoprompt-mcp | grep -q "not found"

            ENV HOME=/home/repoprompt \
                REPOPROMPT_MCP_HEADLESS_PROFILE_DIR=/data \
                REPOPROMPT_MCP_WORKING_DIRS=/workspace

            WORKDIR /workspace
            USER 65532:65532
            ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/repoprompt-mcp"]
            CMD ["--backend", "headless"]
            """
        ),
    )
    write(
        ".dockerignore",
        textwrap.dedent(
            """\
            .build
            .git
            .github
            .swiftpm
            .DS_Store
            DerivedData
            build
            dist
            node_modules
            """
        ),
    )

    write(
        "Scripts/test_linux_headless_native.sh",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail

            ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
            cd "$ROOT_DIR"

            SWIFT_JOBS="${SWIFT_JOBS:-4}"
            swift build --configuration release --jobs "$SWIFT_JOBS" --product repoprompt-mcp
            BINARY="$(swift build --configuration release --show-bin-path)/repoprompt-mcp"

            "$BINARY" --version
            python3 Scripts/test_linux_headless_mcp.py binary "$BINARY"
            """
        ),
        executable=True,
    )
    write(
        "Scripts/test_linux_headless_docker.sh",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail

            ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
            cd "$ROOT_DIR"

            IMAGE="${1:-repoprompt-ce-headless:local}"
            docker build --file Dockerfile.headless --tag "$IMAGE" .
            docker run --rm --entrypoint /usr/local/bin/repoprompt-mcp "$IMAGE" --version
            python3 Scripts/test_linux_headless_mcp.py docker "$IMAGE"
            """
        ),
        executable=True,
    )

    write(
        "Scripts/test_linux_headless_mcp.py",
        textwrap.dedent(
            r"""\
            #!/usr/bin/env python3
            """Smoke-test the Linux headless MCP binary or final container."""

            from __future__ import annotations

            import json
            import os
            from pathlib import Path
            import select
            import subprocess
            import sys
            import tempfile
            from typing import Any


            REQUIRED_CORE_TOOLS = {
                "bind_context",
                "manage_workspaces",
                "manage_selection",
                "file_actions",
                "get_code_structure",
                "get_file_tree",
                "read_file",
                "file_search",
                "workspace_context",
                "prompt",
                "apply_edits",
                "git",
                "manage_worktree",
            }


            def command(mode: str, target: str, workspace: Path, profile: Path) -> list[str]:
                if mode == "binary":
                    return [target, "--backend", "headless"]
                if mode == "docker":
                    return [
                        "docker",
                        "run",
                        "--rm",
                        "-i",
                        "--network=none",
                        "--mount",
                        f"type=bind,src={workspace},dst=/workspace",
                        "--mount",
                        f"type=bind,src={profile},dst=/data",
                        target,
                        "--backend",
                        "headless",
                    ]
                raise ValueError(f"unsupported mode: {mode}")


            def request(
                process: subprocess.Popen[str],
                identifier: int,
                method: str,
                params: dict[str, Any],
            ) -> dict[str, Any]:
                assert process.stdin is not None
                assert process.stdout is not None
                process.stdin.write(
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": identifier,
                            "method": method,
                            "params": params,
                        }
                    )
                    + "\n"
                )
                process.stdin.flush()
                ready, _, _ = select.select([process.stdout], [], [], 30)
                if not ready:
                    raise TimeoutError(f"timed out waiting for {method}")
                line = process.stdout.readline()
                if not line:
                    stderr = process.stderr.read() if process.stderr is not None else ""
                    raise RuntimeError(f"headless process closed during {method}: {stderr}")
                reply = json.loads(line)
                if reply.get("id") != identifier or "error" in reply:
                    raise AssertionError(f"invalid {method} response: {reply}")
                return reply["result"]


            def tool_value(result: dict[str, Any]) -> Any:
                if result.get("isError", False):
                    raise AssertionError(f"tool returned an error: {result}")
                for item in result.get("content", []):
                    if item.get("type") == "text":
                        try:
                            return json.loads(item["text"])
                        except (KeyError, TypeError, json.JSONDecodeError):
                            continue
                raise AssertionError(f"tool omitted a JSON result: {result}")


            def main() -> None:
                if len(sys.argv) != 3:
                    raise SystemExit(f"usage: {sys.argv[0]} binary|docker TARGET")
                mode, target = sys.argv[1:]
                with tempfile.TemporaryDirectory(prefix="rp-linux-workspace-") as workspace_raw, tempfile.TemporaryDirectory(
                    prefix="rp-linux-profile-"
                ) as profile_raw:
                    workspace = Path(workspace_raw)
                    profile = Path(profile_raw)
                    (workspace / "Sources").mkdir()
                    fixture = workspace / "Sources" / "Sample.swift"
                    fixture.write_text(
                        "struct LinuxHeadlessFixture { let value: Int }\n",
                        encoding="utf-8",
                    )
                    environment = os.environ.copy()
                    environment["REPOPROMPT_MCP_HEADLESS_PROFILE_DIR"] = str(profile)
                    environment["REPOPROMPT_MCP_WORKING_DIRS"] = str(workspace)
                    process = subprocess.Popen(
                        command(mode, target, workspace, profile),
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        env=environment,
                    )
                    try:
                        initialized = request(
                            process,
                            1,
                            "initialize",
                            {
                                "protocolVersion": "2025-06-18",
                                "capabilities": {},
                                "clientInfo": {
                                    "name": "linux-headless-smoke",
                                    "version": "1",
                                },
                            },
                        )
                        if initialized.get("serverInfo", {}).get("name") != "RepoPrompt CE":
                            raise AssertionError(f"unexpected server identity: {initialized}")

                        listed = request(process, 2, "tools/list", {})
                        names = {tool["name"] for tool in listed["tools"]}
                        missing = REQUIRED_CORE_TOOLS - names
                        if missing:
                            raise AssertionError(f"missing core tools: {sorted(missing)}")

                        tree = request(
                            process,
                            3,
                            "tools/call",
                            {
                                "name": "get_file_tree",
                                "arguments": {"type": "files"},
                            },
                        )
                        tree_payload = tool_value(tree)
                        if "Sample.swift" not in json.dumps(tree_payload):
                            raise AssertionError(f"fixture missing from file tree: {tree_payload}")

                        read_result = request(
                            process,
                            4,
                            "tools/call",
                            {
                                "name": "read_file",
                                "arguments": {
                                    "path": str(fixture),
                                    "start_line": 1,
                                    "limit": 5,
                                },
                            },
                        )
                        if "LinuxHeadlessFixture" not in json.dumps(tool_value(read_result)):
                            raise AssertionError(f"read_file omitted fixture: {read_result}")

                        search_result = request(
                            process,
                            5,
                            "tools/call",
                            {
                                "name": "file_search",
                                "arguments": {
                                    "pattern": "LinuxHeadlessFixture",
                                    "path": str(fixture),
                                    "regex": False,
                                },
                            },
                        )
                        if "LinuxHeadlessFixture" not in json.dumps(tool_value(search_result)):
                            raise AssertionError(f"file_search omitted fixture: {search_result}")

                        process.stdin.close()
                        process.wait(timeout=15)
                        if process.returncode != 0:
                            stderr = process.stderr.read() if process.stderr is not None else ""
                            raise AssertionError(f"headless process exited {process.returncode}: {stderr}")
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=5)


            if __name__ == "__main__":
                main()
            """
        ),
        executable=True,
    )

    write(
        ".github/workflows/linux-headless.yml",
        textwrap.dedent(
            """\
            name: Linux Headless MCP

            on:
              pull_request:
                paths:
                  - "Package.swift"
                  - "Dockerfile.headless"
                  - "Sources/RepoPromptCodeMapCore/**"
                  - "Sources/RepoPromptDomainRuntime/**"
                  - "Sources/RepoPromptMCP/**"
                  - "Sources/RepoPromptShared/**"
                  - "Scripts/test_linux_headless_*"
                  - ".github/workflows/linux-headless.yml"
              push:
                branches:
                  - linux-headless-mcp
                  - linux-headless-mcp-rework
              workflow_dispatch:

            permissions:
              contents: read

            concurrency:
              group: linux-headless-${{ github.workflow }}-${{ github.ref }}
              cancel-in-progress: true

            jobs:
              native:
                name: Native Ubuntu headless backend
                runs-on: ubuntu-24.04
                steps:
                  - name: Check out repository
                    uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
                    with:
                      persist-credentials: false

                  - name: Set up Swift 6.2.1
                    uses: swift-actions/setup-swift@7ca6abe6b3b0e8b5421b88be48feee39cbf52c6a
                    with:
                      swift-version: "6.2.1"

                  - name: Install native dependencies
                    run: |
                      sudo apt-get update
                      sudo apt-get install --yes --no-install-recommends g++ git libstdc++-14-dev pkg-config python3

                  - name: Build and exercise headless backend
                    env:
                      SWIFT_JOBS: "4"
                    run: bash Scripts/test_linux_headless_native.sh

              docker:
                name: Docker headless backend
                runs-on: ubuntu-24.04
                steps:
                  - name: Check out repository
                    uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803
                    with:
                      persist-credentials: false

                  - name: Build and exercise final image
                    run: bash Scripts/test_linux_headless_docker.sh "repoprompt-ce-headless:${GITHUB_SHA}"
            """
        ),
    )

    write(
        "docs/linux-headless-container.md",
        textwrap.dedent(
            """\
            # Linux headless container

            The Linux artifact packages only the direct MCP backend:

            ```bash
            docker build -f Dockerfile.headless -t repoprompt-ce-headless .
            docker run --rm -i \
              -v "$PWD:/workspace" \
              -v repoprompt-profile:/data \
              repoprompt-ce-headless
            ```

            The image entrypoint runs:

            ```text
            repoprompt-mcp --backend headless
            ```

            ## Included core

            The acceptance contract covers MCP initialization, tool discovery,
            repository tree traversal, file reads, literal search, selection and
            prompt state, edits, Git/worktree access, workspace context, and code
            structure generation.

            ## Deliberately deferred

            The Linux graph does not include RepoPromptApp, AppKit, SwiftUI,
            Sparkle, the app-proxy backend, interactive/exec CLI modes, bundled
            Node, or a bundled AI CLI. Provider-backed Oracle and agent calls
            report an explicit unavailable-provider error unless the operator
            supplies a compatible external command through the documented
            headless environment.

            “Dependency-free” here means free of macOS frameworks and app
            services. The final Ubuntu image still contains the small set of
            Linux runtime libraries reported by `ldd`, plus `git` and `tini`.
            """
        ),
    )


def main() -> None:
    install_linux_manifest()
    install_portability_helpers()
    patch_cryptokit_imports()
    patch_child_endpoint()
    patch_stdio_transport()
    patch_service()
    write_runtime_files()


if __name__ == "__main__":
    main()
