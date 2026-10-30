"""A compact native-widget palette for the repository workspace."""

STYLESHEET = """
QMainWindow, QWidget { background: #111923; color: #dfe7ef; font-size: 13px; }
QMenuBar, QMenu, QStatusBar { background: #111923; }
QMenu::item:selected { background: #263b49; }
QFrame#header { background: #15212c; border-bottom: 1px solid #2b3947; }
QLabel#brand { font-size: 21px; font-weight: 700; color: #f3f7fa; }
QLabel#subtitle, QLabel#muted { color: #93a6b7; }
QLabel#section { font-size: 11px; font-weight: 700; color: #9aafbf; }
QLabel#project { font-size: 14px; font-weight: 600; }
QLabel#connection { color: #72dfbd; padding: 7px 12px; background: #19352f; border-radius: 12px; }
QLabel#error { color: #ffcdc4; background: #442b2c; padding: 10px; border-radius: 5px; }
QPushButton { background: #243341; border: 1px solid #384a5c; border-radius: 5px; padding: 7px 12px; }
QPushButton:hover { background: #304658; border-color: #638296; }
QPushButton:pressed { background: #192b39; }
QPushButton:disabled { color: #71818e; background: #1c2732; border-color: #293642; }
QPushButton#primary { color: #10271f; background: #72dfbd; border-color: #72dfbd; font-weight: 700; }
QPushButton#primary:hover { background: #9aecd2; }
QPushButton#primary:disabled { color: #71818e; background: #263c37; border-color: #263c37; }
QLineEdit, QPlainTextEdit, QListWidget, QTreeView, QTableWidget {
    background: #101821; border: 1px solid #2c3c4b; border-radius: 5px; padding: 5px;
    selection-background-color: #28574f; selection-color: #f0fff9;
}
QLineEdit:focus, QPlainTextEdit:focus { border-color: #64baaa; }
QTreeView { border: none; }
QTreeView::item { padding: 5px 0; }
QTreeView::item:selected { background: #23483f; }
QListWidget::item { padding: 6px; }
QTabWidget::pane { border: 1px solid #2b3947; border-radius: 4px; }
QTabBar::tab { background: #15212c; color: #99adbd; padding: 10px 18px; border-bottom: 2px solid transparent; }
QTabBar::tab:selected { color: #e1f7ee; border-bottom: 2px solid #72dfbd; }
QHeaderView::section { background: #1c2b37; color: #9fb1c0; padding: 6px; border: none; }
QSplitter::handle { background: #243340; }
QSplitter::handle:horizontal { width: 1px; }
QSplitter::handle:vertical { height: 1px; }
QProgressBar { border: none; background: #15212c; max-height: 3px; }
QProgressBar::chunk { background: #72dfbd; }
QScrollBar:vertical { background: #111923; width: 10px; }
QScrollBar::handle:vertical { background: #354958; min-height: 24px; border-radius: 4px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QToolTip { color: #e1e9ee; background: #263948; border: 1px solid #506675; }
"""
