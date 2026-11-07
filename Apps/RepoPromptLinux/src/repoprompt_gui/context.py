"""Presentation helpers; repository reads and state remain owned by the engine."""

import hashlib
import os
from pathlib import Path
import re

MAX_CONTEXT_BYTES = 2 * 1024 * 1024
MAX_CONTEXT_FILES = 100


def xdg_directory(variable: str, fallback: Path) -> Path:
    value = os.environ.get(variable, "")
    return Path(value) if value and Path(value).is_absolute() else fallback


def profile_directory(repository: Path, engine: Path) -> Path:
    identity = f"{repository.resolve()}\0{engine.resolve()}".encode()
    key = hashlib.sha256(identity).hexdigest()[:24]
    data = xdg_directory("XDG_DATA_HOME", Path.home() / ".local/share")
    return data / "repoprompt-ce-linux-gui" / "profiles" / key


def display_path(path: str, repository: Path) -> str:
    try:
        return str(Path(path).relative_to(repository)) if Path(path).is_absolute() else path
    except ValueError:
        return path


def compose_context(prompt: str, files: list[tuple[str, str]]) -> str:
    """Produce portable Markdown without allowing source backticks to end a fence."""
    if len(files) > MAX_CONTEXT_FILES:
        raise ValueError(f"Choose at most {MAX_CONTEXT_FILES} files to copy together.")
    sections = [prompt.strip()] if prompt.strip() else []
    for path, content in files:
        fence = "`" * max(3, 1 + max((len(x) for x in re.findall(r"`+", content)), default=0))
        # Keep unusual filenames on one heading line. Actual paths go to the engine unchanged.
        heading = path.replace("\r", "\\r").replace("\n", "\\n")
        sections.append(f"### {heading}\n\n{fence}\n{content}" + ("" if content.endswith("\n") else "\n") + fence)
    result = "\n\n".join(sections) + ("\n" if sections else "")
    if len(result.encode("utf-8")) > MAX_CONTEXT_BYTES:
        raise ValueError("Context exceeds 2 MiB. Select fewer or smaller files; nothing was copied.")
    return result
