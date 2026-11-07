"""Native desktop presentation; all file contents and context state come from MCP."""

from pathlib import Path
import re

from PySide6.QtCore import QDir, QSettings, QSortFilterProxyModel, Qt, QTimer
from PySide6.QtGui import QAction, QFontDatabase, QIcon, QKeySequence
from PySide6.QtWidgets import (
    QApplication, QFileDialog, QFileSystemModel, QFrame, QHBoxLayout, QHeaderView,
    QLabel, QListWidget, QListWidgetItem, QMainWindow, QMessageBox, QPlainTextEdit,
    QProgressBar, QPushButton, QSplitter, QTabWidget, QTableWidget, QTableWidgetItem,
    QTreeView, QVBoxLayout, QWidget, QLineEdit,
)

from .context import MAX_CONTEXT_BYTES, MAX_CONTEXT_FILES, compose_context, display_path, profile_directory
from .engine import EngineClient
from .style import STYLESHEET

ICON_PATH = Path(__file__).parent / "resources/repoprompt-ce.svg"


class RepositoryProxy(QSortFilterProxyModel):
    """Qt supplies lazy directory presentation. Symlinks are not navigable roots."""

    def filterAcceptsRow(self, row, parent):
        index = self.sourceModel().index(row, 0, parent)
        return not self.sourceModel().fileInfo(index).isSymLink()


def caption(text):
    label = QLabel(text)
    label.setObjectName("section")
    return label


def button(text, callback, name=""):
    result = QPushButton(text)
    result.setObjectName(name)
    result.clicked.connect(callback)
    return result


class MainWindow(QMainWindow):
    def __init__(self, binary: Path, settings: QSettings, repository: Path | None = None,
                 profile: Path | None = None):
        super().__init__()
        self.binary, self.settings, self.profile_override = binary, settings, profile
        self.repository: Path | None = None
        self.client: EngineClient | None = None
        self._clients: list[EngineClient] = []
        self.selection: list[str] = []
        self.current_file: str | None = None
        self._copying = False
        self._closing = False
        self._workspace_loaded = False
        self.setWindowTitle("RepoPrompt CE")
        self.setWindowIcon(QIcon(str(ICON_PATH)))
        self.resize(1380, 880)
        self.setMinimumSize(1000, 650)
        self.setStyleSheet(STYLESHEET)
        self._build_ui()
        self._menus()
        geometry = settings.value("geometry")
        if geometry:
            self.restoreGeometry(geometry)
        self._actions()
        initial = repository or self._previous_repository()
        if initial:
            QTimer.singleShot(0, lambda: self.open_repository(initial))

    def _previous_repository(self):
        value = self.settings.value("repository", "", type=str)
        return Path(value) if value and Path(value).is_dir() else None

    def _build_ui(self):
        shell = QWidget()
        layout = QVBoxLayout(shell)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        header = QFrame()
        header.setObjectName("header")
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(22, 17, 22, 17)
        brand = QLabel("RepoPrompt CE")
        brand.setObjectName("brand")
        header_layout.addWidget(brand)
        subtitle = QLabel("LINUX WORKSPACE")
        subtitle.setObjectName("subtitle")
        header_layout.addWidget(subtitle)
        header_layout.addStretch()
        self.connection = QLabel("No repository")
        self.connection.setObjectName("connection")
        header_layout.addWidget(self.connection)
        header_layout.addWidget(button("Open repository…", self.choose_repository))
        self.reconnect_button = button("Reconnect", self.reconnect)
        self.reconnect_button.setToolTip("Restart the workspace connection; saved context is retained.")
        header_layout.addWidget(self.reconnect_button)
        layout.addWidget(header)
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        self.progress.hide()
        layout.addWidget(self.progress)
        self.error_label = QLabel()
        self.error_label.setObjectName("error")
        self.error_label.setWordWrap(True)
        self.error_label.setTextFormat(Qt.TextFormat.PlainText)
        self.error_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.error_label.hide()
        layout.addWidget(self.error_label)
        panes = QSplitter(Qt.Orientation.Horizontal)
        panes.setChildrenCollapsible(False)
        panes.addWidget(self._repository_pane())
        panes.addWidget(self._preview_pane())
        panes.addWidget(self._context_pane())
        panes.setSizes([260, 740, 360])
        layout.addWidget(panes, 1)
        self.setCentralWidget(shell)
        self.statusBar().showMessage("Open a repository to build context for your coding agent.")

    def _repository_pane(self):
        pane = QWidget()
        layout = QVBoxLayout(pane)
        layout.setContentsMargins(15, 18, 10, 12)
        layout.addWidget(caption("REPOSITORY"))
        self.project_label = QLabel("Choose a project")
        self.project_label.setObjectName("project")
        self.project_label.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.project_label)
        self.filter_edit = QLineEdit()
        self.filter_edit.setPlaceholderText("Filter filenames…")
        self.filter_edit.setClearButtonEnabled(True)
        layout.addWidget(self.filter_edit)
        self.file_model = QFileSystemModel(self)
        self.file_model.setReadOnly(True)
        self.file_model.setResolveSymlinks(False)
        self.file_model.setFilter(QDir.Filter.AllDirs | QDir.Filter.Files | QDir.Filter.NoDotAndDotDot)
        self.file_model.setNameFilterDisables(False)
        self.file_proxy = RepositoryProxy(self)
        self.file_proxy.setSourceModel(self.file_model)
        self.file_proxy.setDynamicSortFilter(True)
        self.tree = QTreeView()
        self.tree.setObjectName("repositoryTree")
        self.tree.setModel(self.file_proxy)
        self.tree.setHeaderHidden(True)
        self.tree.setAnimated(False)
        self.tree.setSortingEnabled(True)
        self.tree.sortByColumn(0, Qt.SortOrder.AscendingOrder)
        for column in range(1, 4):
            self.tree.hideColumn(column)
        self.tree.clicked.connect(self._tree_clicked)
        self.filter_edit.textChanged.connect(lambda value: self.file_model.setNameFilters([f"*{value}*"] if value else []))
        layout.addWidget(self.tree, 1)
        hint = QLabel("Click a file to preview it.\nAdd files to the context on the right.")
        hint.setObjectName("muted")
        layout.addWidget(hint)
        return pane

    def _preview_pane(self):
        pane = QWidget()
        layout = QVBoxLayout(pane)
        layout.setContentsMargins(10, 18, 10, 12)
        top = QHBoxLayout()
        top.addWidget(caption("FILE PREVIEW"))
        top.addStretch()
        self.add_button = button("+ Add to context", self.toggle_current_file)
        self.add_button.setToolTip("Include or remove this file in the persisted selection (Ctrl+Return).")
        top.addWidget(self.add_button)
        layout.addLayout(top)
        self.file_label = QLabel("Your code, in context")
        self.file_label.setTextFormat(Qt.TextFormat.PlainText)
        self.file_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        layout.addWidget(self.file_label)
        self.tabs = QTabWidget()
        self.preview = self._text_view("Select a file in the repository browser to preview it here.")
        self.preview.setObjectName("filePreview")
        self.tabs.addTab(self.preview, "Source")
        self.tabs.addTab(self._search_pane(), "Search")
        self.codemap = self._text_view("Open a source file, then choose Show CodeMap.")
        self.codemap.setObjectName("codeMapPreview")
        self.tabs.addTab(self.codemap, "CodeMap")
        layout.addWidget(self.tabs, 1)
        bottom = QHBoxLayout()
        self.preview_note = QLabel("File contents are read by the local context engine.")
        self.preview_note.setObjectName("muted")
        bottom.addWidget(self.preview_note, 1)
        self.codemap_button = button("Show CodeMap", self.show_codemap)
        bottom.addWidget(self.codemap_button)
        layout.addLayout(bottom)
        return pane

    def _text_view(self, placeholder):
        view = QPlainTextEdit()
        view.setReadOnly(True)
        view.setLineWrapMode(QPlainTextEdit.LineWrapMode.NoWrap)
        view.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        view.setPlaceholderText(placeholder)
        return view

    def _search_pane(self):
        pane = QWidget()
        layout = QVBoxLayout(pane)
        row = QHBoxLayout()
        self.search_edit = QLineEdit()
        self.search_edit.setObjectName("searchQuery")
        self.search_edit.setPlaceholderText("Search repository contents…")
        self.search_edit.returnPressed.connect(self.search)
        row.addWidget(self.search_edit, 1)
        self.search_button = button("Search", self.search)
        row.addWidget(self.search_button)
        layout.addLayout(row)
        self.search_results = QTableWidget(0, 3)
        self.search_results.setObjectName("searchResults")
        self.search_results.setHorizontalHeaderLabels(["File", "Line", "Match"])
        self.search_results.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.search_results.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        self.search_results.setWordWrap(False)
        self.search_results.verticalHeader().hide()
        self.search_results.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.ResizeToContents)
        self.search_results.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.ResizeToContents)
        self.search_results.horizontalHeader().setStretchLastSection(True)
        self.search_results.cellDoubleClicked.connect(self._open_search_result)
        layout.addWidget(self.search_results, 1)
        self.search_note = QLabel("Literal text search · up to 200 matches · double-click a result to open it")
        self.search_note.setObjectName("muted")
        self.search_note.setWordWrap(True)
        layout.addWidget(self.search_note)
        return pane

    def _context_pane(self):
        pane = QWidget()
        layout = QVBoxLayout(pane)
        layout.setContentsMargins(12, 18, 18, 12)
        top = QHBoxLayout()
        self.selection_title = caption("CONTEXT · 0 FILES")
        top.addWidget(self.selection_title, 1)
        self.clear_button = button("Clear", self.clear_selection)
        top.addWidget(self.clear_button)
        layout.addLayout(top)
        self.selected_files = QListWidget()
        self.selected_files.setObjectName("selectedFiles")
        self.selected_files.setMinimumHeight(140)
        self.selected_files.itemDoubleClicked.connect(lambda item: self.open_file(item.data(Qt.ItemDataRole.UserRole)))
        layout.addWidget(self.selected_files, 2)
        self.remove_button = button("Remove selected file", self.remove_selected_file)
        self.selected_files.itemSelectionChanged.connect(self._actions)
        layout.addWidget(self.remove_button)
        prompt_header = QHBoxLayout()
        prompt_header.addWidget(caption("PROMPT"), 1)
        self.save_state = QLabel("Saved")
        self.save_state.setObjectName("muted")
        prompt_header.addWidget(self.save_state)
        layout.addLayout(prompt_header)
        self.prompt = QPlainTextEdit()
        self.prompt.setObjectName("promptEditor")
        self.prompt.setPlaceholderText("What should your coding agent work on?\n\nAdd goals, constraints, and review notes…")
        self.prompt.document().modificationChanged.connect(self._prompt_modified)
        layout.addWidget(self.prompt, 3)
        self.save_button = button("Save prompt", self.save_prompt)
        self.save_button.setToolTip("Save the prompt to this repository's profile (Ctrl+S).")
        layout.addWidget(self.save_button)
        self.copy_button = button("Copy context", self.copy_context, "primary")
        self.copy_button.setToolTip("Copy the current prompt and full selected text files as Markdown.")
        layout.addWidget(self.copy_button)
        hint = QLabel("Saved locally per repository.\nCopy context to paste into your coding agent.")
        hint.setObjectName("muted")
        hint.setWordWrap(True)
        layout.addWidget(hint)
        return pane

    def _menus(self):
        file_menu = self.menuBar().addMenu("&File")
        for title, shortcut, handler in [
            ("Open repository…", QKeySequence.StandardKey.Open, self.choose_repository),
            ("Save prompt", QKeySequence.StandardKey.Save, self.save_prompt),
            ("Copy context", "Ctrl+Shift+C", self.copy_context),
            ("Reconnect", "F5", self.reconnect),
            ("Quit", QKeySequence.StandardKey.Quit, self.close),
        ]:
            action = QAction(title, self)
            action.setShortcut(QKeySequence(shortcut))
            action.triggered.connect(handler)
            file_menu.addAction(action)
        add = QAction("Toggle current file in context", self)
        add.setShortcut(QKeySequence("Ctrl+Return"))
        add.triggered.connect(self.toggle_current_file)
        self.addAction(add)
        help_menu = self.menuBar().addMenu("&Help")
        about = QAction("About RepoPrompt CE", self)
        about.triggered.connect(lambda: QMessageBox.about(self, "RepoPrompt CE for Linux",
            "Native Linux context workspace\n\nRepository browsing, search, CodeMaps, selection, and prompt composition.\n"
            "Uses the local RepoPrompt CE headless engine.\n\nApache-2.0 · Qt for Python (PySide6), LGPL-3.0.\n"
            "https://github.com/repoprompt/repoprompt-ce"))
        help_menu.addAction(about)

    def _actions(self):
        connected = bool(self.client and self.client.is_ready and self._workspace_loaded and not self._closing)
        self.tree.setEnabled(connected)
        self.filter_edit.setEnabled(connected)
        self.prompt.setReadOnly(not connected)
        self.search_button.setEnabled(connected)
        self.add_button.setEnabled(connected and bool(self.current_file))
        selected = self._current_selected()
        self.add_button.setText("− Remove from context" if selected else "+ Add to context")
        self.codemap_button.setEnabled(connected and bool(self.current_file) and "get_code_structure" in self.client.tools)
        self.clear_button.setEnabled(connected and bool(self.selection))
        self.remove_button.setEnabled(connected and self.selected_files.currentItem() is not None)
        self.save_button.setEnabled(connected and self.prompt.document().isModified())
        self.copy_button.setEnabled(connected and not self._copying and bool(self.selection or self.prompt.toPlainText().strip()))
        self.reconnect_button.setEnabled(self.repository is not None and not self._closing)

    def _current_selected(self):
        if not self.repository or not self.current_file:
            return False
        return any(self._absolute(path) == self.current_file for path in self.selection)

    def _absolute(self, path):
        value = Path(path)
        return str(value if value.is_absolute() else self.repository / value)

    def choose_repository(self):
        path = QFileDialog.getExistingDirectory(self, "Open repository", str(self.repository or Path.home()))
        if path:
            self.open_repository(Path(path))

    def reconnect(self):
        if self.repository:
            self.open_repository(self.repository)

    def open_repository(self, repository: Path):
        repository = repository.expanduser().resolve()
        if not repository.is_dir():
            self._error(f"Repository directory not found: {repository}")
            return
        if ":" in str(repository) or str(repository).strip() != str(repository):
            self._error("Choose a repository path without colons or leading/trailing spaces.")
            return
        if self.prompt.document().isModified():
            answer = QMessageBox.question(self, "Unsaved prompt", "Discard the unsaved prompt and reopen the workspace?",
                QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel, QMessageBox.StandardButton.Cancel)
            if answer != QMessageBox.StandardButton.Discard:
                return
        if self.client:
            previous, self.client = self.client, None
            previous.shutdown()
        self.repository, self.selection, self.current_file = repository, [], None
        self._copying = False
        self._workspace_loaded = False
        self.prompt.clear()
        self.prompt.document().setModified(False)
        self.preview.clear()
        self.codemap.clear()
        self.search_results.setRowCount(0)
        self._render_selection()
        self.error_label.hide()
        self.project_label.setText(repository.name)
        self.project_label.setToolTip(str(repository))
        self.setWindowTitle(f"{repository.name} — RepoPrompt CE")
        self.connection.setText("Connecting…")
        self.file_label.setText("Select a file to preview")
        self.settings.setValue("repository", str(repository))
        profile = self.profile_override or profile_directory(repository, self.binary)
        self.client = EngineClient(self.binary, repository, profile, self)
        client = self.client
        self._clients.append(client)
        client.ready.connect(lambda: self._ready(client))
        client.failed.connect(lambda message: self._engine_failed(client, message))
        client.busy_changed.connect(lambda busy: self.progress.setVisible(busy) if client is self.client else None)
        client.closed.connect(lambda: self._client_closed(client))
        self._actions()
        client.start()

    def _client_closed(self, client):
        if client in self._clients:
            self._clients.remove(client)
        if self._closing and not self._clients:
            QTimer.singleShot(0, self.close)
        # Keep the current client object for its disconnected UI state until replaced.
        if client is not self.client:
            client.deleteLater()

    def _ready(self, client):
        if client is not self.client:
            return
        self.connection.setText("Local engine connected")
        self.file_model.setRootPath(str(self.repository))
        self.tree.setRootIndex(self.file_proxy.mapFromSource(self.file_model.index(str(self.repository))))

        def loaded(value, error):
            if error:
                self._error(str(error))
                return
            if not isinstance(value, dict) or not isinstance(value.get("selection"), list) or not isinstance(value.get("prompt"), str):
                self._error("The engine returned an invalid workspace snapshot.")
                return
            roots = [str(Path(root).resolve()) for root in value.get("roots", [])]
            if str(self.repository) not in roots:
                client.shutdown()
                self.connection.setText("Profile mismatch")
                self._error("This saved profile belongs to another repository. Use a different --profile-dir.")
                self._actions()
                return
            self.selection = [path for path in value["selection"] if isinstance(path, str)]
            self.prompt.setPlainText(value["prompt"])
            self.prompt.document().setModified(False)
            self._workspace_loaded = True
            self._render_selection()
            self.statusBar().showMessage(f"Connected · {self.repository}")
            self._actions()

        self._call("workspace_context", {"op": "snapshot"}, loaded)
        self._actions()

    def _engine_failed(self, client, message):
        if client is self.client:
            self.connection.setText("Engine disconnected")
            self._error(message)
            self._actions()

    def _error(self, message):
        self.error_label.setText(str(message)[:3000])
        self.error_label.show()
        self.statusBar().showMessage("Operation did not complete.")

    def _call(self, name, arguments, callback):
        client = self.client
        if not client:
            self._error("Open a repository first.")
            return

        def completed(value, error):
            if client is self.client and not self._closing:
                callback(value, error)
                self._actions()

        self.error_label.hide()
        client.call_tool(name, arguments, completed)

    def _tree_clicked(self, index):
        source = self.file_proxy.mapToSource(index)
        if not self.file_model.isDir(source):
            self.open_file(self.file_model.filePath(source))

    def open_file(self, path, line=1):
        if not self.client or not self.client.is_ready:
            return
        path = self._absolute(path)
        self.current_file = path
        self.file_label.setText(display_path(path, self.repository))
        self.preview.setPlainText("Loading file…")
        self.codemap.clear()
        self.tabs.setCurrentIndex(0)
        self._actions()

        def loaded(value, error):
            if self.current_file != path:
                return
            if error or not isinstance(value, str):
                self.preview.clear()
                self._error(str(error or "The engine did not return text for this file."))
                return
            maximum = 1_000_000
            self.preview.setPlainText(value[:maximum])
            self.preview_note.setText("Preview limited to 1 million characters; Copy context reads the full file."
                if len(value) > maximum else f"{len(value.splitlines()):,} lines · {len(value.encode('utf-8')):,} bytes")
            cursor = self.preview.textCursor()
            block = self.preview.document().findBlockByNumber(max(0, line - 1))
            if block.isValid():
                cursor.setPosition(block.position())
                self.preview.setTextCursor(cursor)
                self.preview.centerCursor()

        self._call("read_file", {"path": path}, loaded)

    def _render_selection(self):
        self.selected_files.clear()
        for path in self.selection:
            item = QListWidgetItem(display_path(path, self.repository))
            item.setData(Qt.ItemDataRole.UserRole, path)
            item.setToolTip(path)
            self.selected_files.addItem(item)
        self.selection_title.setText(f"CONTEXT · {len(self.selection)} FILE{'S' if len(self.selection) != 1 else ''}")
        self._actions()

    def _change_selection(self, operation, paths=None):
        def changed(value, error):
            if error or not isinstance(value, dict) or not isinstance(value.get("selection"), list):
                self._error(str(error or "The engine returned an invalid selection."))
                return
            self.selection = [path for path in value["selection"] if isinstance(path, str)]
            self._render_selection()
            self.statusBar().showMessage(f"Saved context selection · {len(self.selection)} files")

        arguments = {"op": operation}
        if paths is not None:
            arguments["paths"] = paths
        self._call("manage_selection", arguments, changed)

    def toggle_current_file(self):
        if self.current_file and self.client and self.client.is_ready:
            existing = [path for path in self.selection if self._absolute(path) == self.current_file]
            self._change_selection("remove" if existing else "add", existing or [self.current_file])

    def clear_selection(self):
        if self.selection:
            self._change_selection("clear")

    def remove_selected_file(self):
        item = self.selected_files.currentItem()
        if item:
            self._change_selection("remove", [item.data(Qt.ItemDataRole.UserRole)])

    def _prompt_modified(self, modified):
        self.save_state.setText("Unsaved" if modified else "Saved")
        self._actions()

    def save_prompt(self, _checked=False, on_saved=None):
        if not self.client or not self.client.is_ready or not self._workspace_loaded:
            self._error("The workspace is disconnected. Copy unsaved prompt text before closing, or reconnect.")
            return
        text = self.prompt.toPlainText()

        def saved(_value, error):
            if error:
                self._error(str(error))
                return
            if self.prompt.toPlainText() == text:
                self.prompt.document().setModified(False)
            self.statusBar().showMessage("Prompt saved to this repository's profile.")
            if on_saved:
                on_saved()

        self._call("prompt", {"op": "set", "text": text}, saved)

    def search(self):
        query = self.search_edit.text()
        if not query.strip() or not self.client or not self.client.is_ready:
            return
        self.search_results.setRowCount(0)
        self.search_note.setText("Searching…")

        def found(value, error):
            if self.search_edit.text() != query:
                return
            if error or not isinstance(value, dict) or not isinstance(value.get("matches"), list):
                self.search_note.setText("Search did not complete.")
                self._error(str(error or "The engine returned an invalid search result."))
                return
            matches = value["matches"]
            self.search_results.setRowCount(len(matches))
            for row, match in enumerate(matches):
                for column, text in enumerate([match.get("path", ""), match.get("line", ""), match.get("text", "")]):
                    item = QTableWidgetItem(str(text))
                    item.setData(Qt.ItemDataRole.UserRole, match)
                    self.search_results.setItem(row, column, item)
            self.search_note.setText(f"{len(matches)} matches" + (" · limit reached; narrow your query" if len(matches) >= 200 else " · double-click to open"))

        # The engine also interprets globs with regex=False; escape desktop queries
        # explicitly so the UI's literal, case-insensitive search stays literal.
        self._call("file_search", {"pattern": "(?i)" + re.escape(query), "regex": True,
                                  "mode": "content", "max_results": 200}, found)

    def _open_search_result(self, row, _column):
        item = self.search_results.item(row, 0)
        if item:
            match = item.data(Qt.ItemDataRole.UserRole)
            self.open_file(match["path"], match.get("line", 1))

    def show_codemap(self):
        if not self.current_file:
            return
        path = self.current_file
        self.tabs.setCurrentIndex(2)
        self.codemap.setPlainText("Loading CodeMap…")

        def loaded(value, error):
            if path != self.current_file:
                return
            if error:
                self.codemap.clear()
                self._error(str(error))
                return
            import json
            files = value.get("files", []) if isinstance(value, dict) else []
            parts = []
            for file in files:
                body = file.get("signatures") or file.get("codemap") or file.get("code_map") or file.get("content")
                parts.append(body if isinstance(body, str) else json.dumps(file, indent=2, ensure_ascii=False))
            self.codemap.setPlainText("\n\n".join(parts) or "No CodeMap is available for this file type.")

        self._call("get_code_structure", {"paths": [path]}, loaded)

    def copy_context(self):
        if self._copying or not self.client or not self.client.is_ready:
            return
        if not self.selection and not self.prompt.toPlainText().strip():
            self.statusBar().showMessage("Add files or write a prompt before copying context.")
            return
        self._copying = True
        prompt = self.prompt.toPlainText()
        files = []
        used_bytes = len(prompt.encode("utf-8"))
        self._actions()

        def failed(error):
            self._copying = False
            self._error(str(error))
            self._actions()

        def snapshot(value, error):
            if error or not isinstance(value, dict) or not isinstance(value.get("selection"), list):
                failed(error or "The engine returned an invalid selection.")
                return
            paths = list(value["selection"])
            if len(paths) > MAX_CONTEXT_FILES:
                failed(f"Choose at most {MAX_CONTEXT_FILES} files to copy together.")
                return

            def next_file():
                nonlocal used_bytes
                if not paths:
                    try:
                        text = compose_context(prompt, files)
                    except ValueError as failure:
                        failed(failure)
                        return
                    QApplication.clipboard().setText(text)
                    self._copying = False
                    self.statusBar().showMessage(f"Copied prompt and {len(files)} files · {len(text.encode('utf-8')):,} bytes")
                    self._actions()
                    return
                path = paths.pop(0)
                self.statusBar().showMessage(f"Reading context file {len(files) + 1} of {len(files) + len(paths) + 1}…")

                def read(value, error):
                    nonlocal used_bytes
                    if error or not isinstance(value, str):
                        failed(error or "A selected file could not be read as text. Nothing was copied.")
                        return
                    used_bytes += len(value.encode("utf-8"))
                    if used_bytes > MAX_CONTEXT_BYTES:
                        failed("Context exceeds 2 MiB. Select fewer or smaller files; nothing was copied.")
                        return
                    files.append((display_path(path, self.repository), value))
                    next_file()

                self._call("read_file", {"path": path}, read)

            next_file()

        self._call("workspace_context", {"op": "snapshot"}, snapshot)

    def closeEvent(self, event):
        if self._closing:
            if self._clients:
                event.ignore()
            else:
                event.accept()
            return
        if self.prompt.document().isModified():
            answer = QMessageBox.question(self, "Unsaved prompt", "Save your prompt before closing?",
                QMessageBox.StandardButton.Save | QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel,
                QMessageBox.StandardButton.Save)
            if answer == QMessageBox.StandardButton.Cancel:
                event.ignore()
                return
            if answer == QMessageBox.StandardButton.Save:
                self.save_prompt(on_saved=self.close)
                event.ignore()
                return
        self.settings.setValue("geometry", self.saveGeometry())
        self.settings.sync()
        self._closing = True
        if self._clients:
            event.ignore()
            self.connection.setText("Closing workspace…")
            for client in list(self._clients):
                client.shutdown()
        else:
            event.accept()
