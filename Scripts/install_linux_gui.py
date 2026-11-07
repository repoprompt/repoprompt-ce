#!/usr/bin/env python3
"""Install the optional native desktop frontend into an unprivileged prefix."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Apps/RepoPromptLinux"
MARKER = ".repoprompt-gui-install.json"
PACKAGE_NAME = "repoprompt-ce-gui"


def atomic_write(path, data, mode):
    descriptor, temporary = tempfile.mkstemp(prefix=".repoprompt-gui-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def desktop_value(value):
    return str(value).replace("\\", "\\\\")


def desktop_command(path):
    # Exec quoting and desktop-entry string escaping are separate decoding passes.
    quoted = "".join("\\" + char if char in '\\`"$' else char for char in str(path))
    return '"' + desktop_value(quoted.replace("%", "%%")) + '" %f'


def install(prefix: Path, binary: Path, python: Path, replace=False, no_deps=False):
    if not sys.platform.startswith("linux"):
        raise ValueError("This installer requires Linux.")
    prefix, binary = prefix.expanduser().absolute(), binary.expanduser().resolve()
    # Preserve a venv's interpreter path rather than resolving its symlink to the base interpreter.
    python = python.expanduser().absolute()
    if any(char in str(prefix) for char in "\r\n\t"):
        raise ValueError("The installation prefix must not contain line breaks or tabs.")
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("Install the Linux repoprompt-mcp engine first, or supply --engine PATH.")
    if not python.is_file() or not os.access(python, os.X_OK):
        raise ValueError(f"Python interpreter is not executable: {python}")
    shared = prefix / "share/repoprompt-ce"
    shared.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(shared / ".linux-gui-install.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _install_locked(prefix, binary, python, replace, no_deps)
    finally:
        os.close(lock_fd)


def _install_locked(prefix, binary, python, replace, no_deps):
    destination = prefix / "share/repoprompt-ce/linux-gui"
    launcher = prefix / "bin/repoprompt-gui"
    desktop = prefix / "share/applications/repoprompt-ce.desktop"
    icon = prefix / "share/icons/hicolor/scalable/apps/repoprompt-ce.svg"
    for path in (destination, launcher, desktop, icon):
        if path.is_symlink():
            raise ValueError(f"Refusing to replace a symbolic link: {path}")
        if path.exists() and not replace:
            raise ValueError(f"Destination exists: {path} (use --replace to update)")
        if path != destination and path.exists() and not path.is_file():
            raise ValueError(f"Refusing to replace a non-regular destination: {path}")
    if destination.exists():
        marker = destination / MARKER
        try:
            owned = not marker.is_symlink() and json.loads(marker.read_text())["package"] == PACKAGE_NAME
        except (OSError, ValueError, KeyError, TypeError):
            owned = False
        if not destination.is_dir() or not owned:
            raise ValueError(f"Preserving an unrelated installation directory: {destination}")
    staging = Path(tempfile.mkdtemp(prefix=".linux-gui-stage-", dir=destination.parent))
    backup = None
    previous_files = {}
    published = False
    try:
        command = [str(python), "-m", "pip", "install", "--disable-pip-version-check",
                   "--no-warn-script-location", "--no-compile", "--target", str(staging)]
        if no_deps:
            command.append("--no-deps")
        command.append(str(PACKAGE))
        subprocess.run(command, check=True)
        (staging / MARKER).write_text(json.dumps({"package": PACKAGE_NAME, "version": 1}) + "\n")
        (staging / "launch.py").write_text(
            "import sys\nfrom pathlib import Path\n"
            "sys.path.insert(0, str(Path(__file__).resolve().parent))\n"
            "from repoprompt_gui.__main__ import main\n"
            f"raise SystemExit(main(['--engine', {str(binary)!r}, *sys.argv[1:]]))\n"
        )
        shutil.copy2(ROOT / "LICENSE", staging / "LICENSE")
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", staging / "THIRD_PARTY_NOTICES.md")
        launch_text = f"#!/bin/sh\nexec {shlex.quote(str(python))} {shlex.quote(str(destination / 'launch.py'))} \"$@\"\n"
        desktop_text = (
            "[Desktop Entry]\nType=Application\nName=RepoPrompt CE\n"
            "Comment=Build focused repository context for coding agents\n"
            f"Exec={desktop_command(launcher)}\nTryExec={desktop_value(launcher)}\n"
            f"Icon={desktop_value(icon)}\nTerminal=false\nCategories=Development;\n"
            "StartupNotify=true\nStartupWMClass=repoprompt-ce\n"
        )
        assets = {
            launcher: (launch_text.encode(), 0o755),
            desktop: (desktop_text.encode(), 0o644),
            icon: ((PACKAGE / "src/repoprompt_gui/resources/repoprompt-ce.svg").read_bytes(), 0o644),
        }
        # A failed dependency download leaves a previous installation untouched.
        for path in assets:
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.is_symlink() or (path.exists() and not path.is_file()):
                raise ValueError(f"Destination changed to a non-regular file: {path}")
            previous_files[path] = (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
        if destination.exists():
            backup = Path(tempfile.mkdtemp(prefix=".linux-gui-backup-", dir=destination.parent))
            backup.rmdir()
            os.replace(destination, backup)
        os.replace(staging, destination)
        published = True
        for path, (data, mode) in assets.items():
            atomic_write(path, data, mode)
    except Exception:
        if published:
            shutil.rmtree(destination)
        if backup is not None:
            os.replace(backup, destination)
            backup = None
        for path, previous in previous_files.items():
            if previous is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, *previous)
        raise
    finally:
        if staging.exists():
            shutil.rmtree(staging)
        if backup is not None:
            shutil.rmtree(backup)
    return launcher, desktop


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local", help="Default: ~/.local")
    parser.add_argument("--engine", type=Path, help="Existing repoprompt-mcp executable (not copied)")
    parser.add_argument("--python", type=Path, default=Path(sys.executable), help="Python 3.10+ interpreter with pip")
    parser.add_argument("--replace", action="store_true", help="Update an existing managed GUI installation")
    parser.add_argument("--no-deps", action="store_true", help="Use PySide6 already installed for --python")
    args = parser.parse_args(argv)
    binary = args.engine or args.prefix.expanduser() / "bin/repoprompt-mcp"
    if not binary.is_file() and not args.engine:
        binary = Path(shutil.which("repoprompt-mcp") or binary)
    try:
        launcher, desktop = install(args.prefix, binary, args.python, args.replace, args.no_deps)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Installed native GUI: {launcher}\nApplication menu entry: {desktop}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
