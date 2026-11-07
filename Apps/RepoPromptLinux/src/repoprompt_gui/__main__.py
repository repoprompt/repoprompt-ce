"""Command-line launch and desktop application entrypoint."""

import argparse
import os
from pathlib import Path
import shutil
import sys

from . import __version__


def main(argv=None):
    parser = argparse.ArgumentParser(description="RepoPrompt CE native Linux context workspace")
    parser.add_argument("repository", nargs="?", type=Path, help="Repository directory to open")
    parser.add_argument("--engine", type=Path, help="Path to the Linux repoprompt-mcp executable")
    parser.add_argument("--profile-dir", type=Path, help="Explicit persistent profile directory")
    parser.add_argument("--version", action="version", version=f"RepoPrompt CE Linux GUI {__version__}")
    args = parser.parse_args(argv)
    if not sys.platform.startswith("linux"):
        parser.error("This desktop frontend supports Linux. Use the native macOS application on macOS.")
    value = args.engine or os.environ.get("REPOPROMPT_GUI_ENGINE") or shutil.which("repoprompt-mcp")
    if not value:
        parser.error("repoprompt-mcp was not found on PATH. Install the engine or supply --engine /absolute/path.")
    binary = Path(value).expanduser().resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error(f"Context engine is not executable: {binary}")
    if args.repository and not args.repository.expanduser().is_dir():
        parser.error(f"Repository directory not found: {args.repository}")
    try:
        from PySide6.QtCore import QSettings
        from PySide6.QtWidgets import QApplication
    except ImportError:
        parser.error("PySide6 is missing. Install Apps/RepoPromptLinux or use Scripts/install_linux_gui.py.")
    from .context import xdg_directory
    from .window import MainWindow

    app = QApplication([sys.argv[0]])
    app.setApplicationName("RepoPrompt CE")
    app.setOrganizationName("RepoPrompt")
    app.setDesktopFileName("repoprompt-ce")
    app.setStyle("Fusion")
    config = xdg_directory("XDG_CONFIG_HOME", Path.home() / ".config") / "repoprompt-ce-linux-gui"
    config.mkdir(parents=True, exist_ok=True)
    settings = QSettings(str(config / "desktop.ini"), QSettings.Format.IniFormat)
    window = MainWindow(binary, settings, args.repository,
                        args.profile_dir.expanduser().resolve() if args.profile_dir else None)
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
