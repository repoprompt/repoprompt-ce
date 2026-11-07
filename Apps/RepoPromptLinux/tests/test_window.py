import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PySide6.QtCore import QProcess, QSettings, Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QMessageBox

from repoprompt_gui.window import MainWindow
from test_engine import APP, ENGINE, call, wait_for


@unittest.skipUnless(ENGINE, "Set REPOPROMPT_GUI_TEST_ENGINE for desktop integration tests")
class DesktopWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rpce-gui-desktop-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "atlas"
        (self.root / "src").mkdir(parents=True)
        self.file = self.root / "src/context.py"
        self.file.write_text('def build_context(files):\n    """Build focused context for a coding agent."""\n    return "hello " + ", ".join(files)\n')
        (self.root / "README.md").write_text("# Atlas\n\nA small project for focused context.\n")
        self.windows = []
        self.settings = QSettings(str(self.base / "desktop.ini"), QSettings.Format.IniFormat)

    def tearDown(self):
        for window in self.windows:
            with patch.object(QMessageBox, "question", return_value=QMessageBox.StandardButton.Discard):
                window.close()
        wait_for(lambda: all(not w._clients for w in self.windows))
        self.temporary.cleanup()

    def open(self):
        window = MainWindow(Path(ENGINE).resolve(), self.settings, self.root, self.base / "profile")
        self.windows.append(window)
        window.show()
        wait_for(lambda: window._workspace_loaded or window.error_label.isVisible())
        self.assertTrue(window._workspace_loaded, window.error_label.text())
        return window

    def test_native_browse_search_codemap_compose_and_persistence(self):
        window = self.open()
        window.open_file(str(self.file))
        wait_for(lambda: "def build_context" in window.preview.toPlainText())
        QTest.mouseClick(window.add_button, Qt.MouseButton.LeftButton)
        wait_for(lambda: str(self.file) in window.selection)
        window.prompt.insertPlainText("Explain the context builder and suggest focused improvements.")
        self.assertTrue(window.prompt.document().isModified())
        QTest.mouseClick(window.save_button, Qt.MouseButton.LeftButton)
        wait_for(lambda: not window.prompt.document().isModified())
        window.tabs.setCurrentIndex(1)
        window.search_edit.setText("hello")
        QTest.mouseClick(window.search_button, Qt.MouseButton.LeftButton)
        wait_for(lambda: window.search_results.rowCount() == 1)
        self.assertEqual(window.search_results.item(0, 0).text(), "src/context.py")
        window.show_codemap()
        wait_for(lambda: "build_context" in window.codemap.toPlainText())
        window.tabs.setCurrentIndex(0)
        QApplication.clipboard().setText("previous clipboard")
        QTest.mouseClick(window.copy_button, Qt.MouseButton.LeftButton)
        wait_for(lambda: not window._copying)
        copied = QApplication.clipboard().text()
        self.assertIn("Explain the context builder", copied)
        self.assertIn("### src/context.py", copied)
        self.assertIn(self.file.read_text(), copied)
        self.assertEqual(self.file.read_text(), 'def build_context(files):\n    """Build focused context for a coding agent."""\n    return "hello " + ", ".join(files)\n')
        screenshot = os.environ.get("REPOPROMPT_GUI_SCREENSHOT")
        if screenshot:
            APP.processEvents()
            window.grab().save(screenshot)
        client = window.client
        window.close()
        wait_for(lambda: client.process.state() == QProcess.ProcessState.NotRunning)
        restarted = self.open()
        self.assertEqual(restarted.selection, [str(self.file)])
        self.assertIn("Explain the context builder", restarted.prompt.toPlainText())

    def test_failed_export_preserves_clipboard_and_browser_excludes_symlinks(self):
        outside = self.base / "outside.txt"
        outside.write_text("PRIVATE_OUTSIDE_CONTENT")
        link = self.root / "escape.txt"
        link.symlink_to(outside)
        window = self.open()
        source = window.file_model.index(str(link))
        self.assertTrue(source.isValid())
        self.assertFalse(window.file_proxy.mapFromSource(source).isValid())
        with self.assertRaises(Exception):
            call(window.client, "manage_selection", {"op": "set", "paths": [str(outside)]})
        call(window.client, "manage_selection", {"op": "set", "paths": [str(self.file)]})
        self.file.unlink()
        self.file.symlink_to(outside)
        window.selection = [str(self.file)]
        window._render_selection()
        QApplication.clipboard().setText("unchanged")
        window.copy_context()
        wait_for(lambda: not window._copying)
        self.assertEqual(QApplication.clipboard().text(), "unchanged")
        self.assertTrue(window.error_label.isVisible())
        self.assertNotIn("PRIVATE_OUTSIDE_CONTENT", window.error_label.text())

    def test_unsaved_prompt_cancel_keeps_window_open_and_save_survives_restart(self):
        window = self.open()
        window.prompt.insertPlainText("Keep these review constraints.")
        with patch.object(QMessageBox, "question", return_value=QMessageBox.StandardButton.Cancel):
            window.close()
        self.assertTrue(window.isVisible())
        self.assertTrue(window.client.is_ready)
        with patch.object(QMessageBox, "question", return_value=QMessageBox.StandardButton.Save):
            window.close()
        wait_for(lambda: not window._clients)
        restarted = self.open()
        self.assertEqual(restarted.prompt.toPlainText(), "Keep these review constraints.")

    def test_literal_search_treats_wildcards_as_text(self):
        self.file.write_text("hello * literal\nother line\n")
        window = self.open()
        window.tabs.setCurrentIndex(1)
        window.search_edit.setText("*")
        window.search()
        wait_for(lambda: window.search_note.text() != "Searching…")
        self.assertEqual(window.search_results.rowCount(), 1)
        self.assertEqual(window.search_results.item(0, 2).text(), "hello * literal")

    def test_switching_default_profiles_keeps_repository_state_separate(self):
        with patch.dict(os.environ, {"XDG_DATA_HOME": str(self.base / "data")}):
            window = MainWindow(Path(ENGINE).resolve(), self.settings, self.root)
            self.windows.append(window)
            window.show()
            wait_for(lambda: window._workspace_loaded)
            window.prompt.insertPlainText("Atlas instructions.")
            window.save_prompt()
            wait_for(lambda: not window.prompt.document().isModified())
            previous = window.client
            stopped = []
            previous.closed.connect(lambda: stopped.append(True))
            second = self.base / "other"
            second.mkdir()
            window.open_repository(second)
            wait_for(lambda: window._workspace_loaded)
            wait_for(lambda: bool(stopped))
            self.assertEqual(window.prompt.toPlainText(), "")
            self.assertEqual(window.selection, [])
            window.open_repository(self.root)
            wait_for(lambda: window._workspace_loaded)
            self.assertEqual(window.prompt.toPlainText(), "Atlas instructions.")
