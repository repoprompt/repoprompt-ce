#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-}"
LAYOUT_LABEL="${2:-Sparkle helper layout}"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

[[ -n "$APP_BUNDLE" ]] || fail "Usage: $0 <app-bundle> [label]"

python3 - "$APP_BUNDLE" "$LAYOUT_LABEL" <<'PYTHON'
import os
import stat
import sys
from pathlib import Path

app = Path(sys.argv[1])
label = sys.argv[2]
framework = app / "Contents" / "Frameworks" / "Sparkle.framework"
versions = framework / "Versions"
version_b = versions / "B"
expected_symlinks = {
    framework / "Autoupdate": "Versions/Current/Autoupdate",
    framework / "Headers": "Versions/Current/Headers",
    framework / "Modules": "Versions/Current/Modules",
    framework / "PrivateHeaders": "Versions/Current/PrivateHeaders",
    framework / "Resources": "Versions/Current/Resources",
    framework / "Sparkle": "Versions/Current/Sparkle",
    framework / "Updater.app": "Versions/Current/Updater.app",
    framework / "XPCServices": "Versions/Current/XPCServices",
    versions / "Current": "B",
}
helper_executables = [
    version_b / "Autoupdate",
    version_b / "Updater.app" / "Contents" / "MacOS" / "Updater",
    version_b / "XPCServices" / "Installer.xpc" / "Contents" / "MacOS" / "Installer",
    version_b / "XPCServices" / "Downloader.xpc" / "Contents" / "MacOS" / "Downloader",
]


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_real_directory(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing Sparkle directory: {path}")
    if not stat.S_ISDIR(mode):
        fail(f"Sparkle path must be a real directory: {path}")


def require_symlink(path: Path, expected_target: str) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing Sparkle framework symlink: {path}")
    if not stat.S_ISLNK(mode):
        fail(f"Sparkle framework path must be a symlink: {path}")
    actual_target = os.readlink(path)
    if actual_target != expected_target:
        fail(f"Sparkle framework symlink target mismatch: {path} -> {actual_target}; expected {expected_target}")
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError:
        fail(f"broken Sparkle framework symlink: {path} -> {actual_target}")
    if not resolved.is_relative_to(framework.resolve(strict=True)):
        fail(f"escaping Sparkle framework symlink: {path} -> {actual_target}")


def require_regular_executable(path: Path) -> None:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        fail(f"missing Sparkle helper executable: {path}")
    if not stat.S_ISREG(mode):
        fail(f"Sparkle helper executable must be a non-symlink regular file: {path}")
    if not mode & 0o111:
        fail(f"Sparkle helper executable must be executable: {path}")


for path in (framework, versions, version_b):
    require_real_directory(path)

for path, expected_target in expected_symlinks.items():
    require_symlink(path, expected_target)

framework_root = framework.resolve(strict=True)
for path in framework.rglob("*"):
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode):
        target = os.readlink(path)
        try:
            resolved = path.resolve(strict=True)
        except FileNotFoundError:
            fail(f"broken Sparkle framework symlink: {path} -> {target}")
        if not resolved.is_relative_to(framework_root):
            fail(f"escaping Sparkle framework symlink: {path} -> {target}")

for path in helper_executables:
    require_regular_executable(path)

print(f"OK: {label} matches the Sparkle helper layout policy.")
PYTHON
