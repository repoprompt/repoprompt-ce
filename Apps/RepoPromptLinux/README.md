# RepoPrompt CE for Linux

A native Qt desktop workspace backed by the production `repoprompt-mcp` engine.
Open a repository, browse and search files, preview source and CodeMaps, curate a
persistent selection, edit your prompt, and copy assembled Markdown context.

Requires Linux, Python 3.10+, PySide6 6.10.3, and a Linux `repoprompt-mcp` build.
The GUI owns a long-lived MCP stdio connection; it starts no HTTP listener.
File contents, search, selection, prompt persistence, and path confinement use
the existing engine. Qt's filesystem model supplies lazy directory presentation;
symlinks are excluded from navigation. This frontend does not modify source files.

From the repository root:

```bash
python3 -m venv .venv-linux-gui
.venv-linux-gui/bin/python -m pip install ./Apps/RepoPromptLinux
.venv-linux-gui/bin/repoprompt-gui --engine "$PWD/.build/release/repoprompt-mcp" ~/src/project
```

The application-menu installer and distribution prerequisites are documented in
[`docs/linux.md`](../../docs/linux.md). This first desktop version focuses on
context composition; the macOS application's full Agent Mode, Overseer, session
administration, and native editor integrations are not part of this frontend.

Selections and saved prompts live in a separate profile per repository and engine
path under `$XDG_DATA_HOME/repoprompt-ce-linux-gui` (default `~/.local/share`).
`--profile-dir` selects a dedicated existing or new profile instead. Use Ctrl+S
to persist prompt edits; closing or changing repositories asks about unsaved text.
Copy context includes the current editor text and full selected text files, up to
100 files and 2 MiB. A failed read leaves the clipboard unchanged. Binary files,
directory selections, and files refused by the engine cannot be exported.

Development tests can run without a display:

```bash
QT_QPA_PLATFORM=offscreen REPOPROMPT_GUI_TEST_ENGINE="$PWD/.build/release/repoprompt-mcp" \
  .venv-linux-gui/bin/python -m unittest discover -s Apps/RepoPromptLinux/tests
```

RepoPrompt CE code is Apache-2.0. Qt for Python/PySide6 and Shiboken are separate
LGPL-3.0 dependencies installed from PyPI. Their wheels retain their upstream
license notices; see [Qt for Python licensing](https://doc.qt.io/qtforpython-6/licenses.html).
