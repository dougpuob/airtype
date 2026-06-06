"""System tray icon with right-click configuration menu."""

from collections.abc import Callable

from PySide6.QtWidgets import (
    QSystemTrayIcon,
    QMenu,
    QApplication,
)
from PySide6.QtGui import QAction, QActionGroup, QColor, QIcon, QPainter, QPen
from PySide6.QtCore import Qt
from PySide6.QtMultimedia import QMediaDevices


def _make_icon(recording: bool = False) -> QIcon:
    """Create a minimal monochrome microphone icon without external assets."""
    from PySide6.QtGui import QPixmap
    pixmap = QPixmap(32, 32)
    pixmap.fill(Qt.GlobalColor.transparent)

    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)

    ink = QColor("#ef4444") if recording else QColor("#ffffff")
    detail = QColor("#111111")
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(ink)
    painter.drawRoundedRect(10, 3, 12, 19, 6, 6)

    painter.setBrush(Qt.GlobalColor.transparent)
    painter.setPen(QPen(ink, 2.6, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
    painter.drawArc(6, 12, 20, 15, 200 * 16, 140 * 16)
    painter.drawLine(16, 26, 16, 30)
    painter.drawLine(10, 30, 22, 30)

    painter.setPen(QPen(detail, 1.6, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
    painter.drawLine(16, 7, 16, 18)
    painter.end()
    return QIcon(pixmap)


def create_tray(
    language_provider: Callable[[], str],
    on_language_selected: Callable[[str], None],
    microphone_provider: Callable[[], str],
    on_microphone_selected: Callable[[str], None],
    move_lock_provider: Callable[[], bool],
    on_move_lock_selected: Callable[[bool], None],
) -> QSystemTrayIcon:
    """Build and return the system tray configuration menu."""

    tray = QSystemTrayIcon(_make_icon(), QApplication.instance())

    menu = QMenu()
    language_menu = QMenu("Chinese Mode", menu)
    microphone_menu = QMenu("Microphone", menu)
    move_lock_action = QAction("Move Lock", menu)
    move_lock_action.setCheckable(True)
    move_lock_action.triggered.connect(on_move_lock_selected)

    menu.addAction(move_lock_action)
    menu.addSeparator()
    menu.addMenu(language_menu)
    menu.addMenu(microphone_menu)
    menu.addSeparator()

    quit_action = QAction("Quit", menu)
    quit_action.triggered.connect(QApplication.quit)
    menu.addAction(quit_action)

    def _rebuild_language_menu() -> None:
        language_menu.clear()
        selected_language = language_provider()
        group = QActionGroup(language_menu)
        group.setExclusive(True)
        options = (
            ("zh-tw", "Traditional Chinese"),
            ("zh-cn", "Simplified Chinese"),
        )
        for value, label in options:
            action = QAction(label, language_menu)
            action.setCheckable(True)
            action.setChecked(selected_language == value)
            action.triggered.connect(lambda checked=False, mode=value: on_language_selected(mode))
            group.addAction(action)
            language_menu.addAction(action)

    def _rebuild_microphone_menu() -> None:
        microphone_menu.clear()
        selected_order = microphone_provider()
        devices = QMediaDevices.audioInputs()
        if not devices:
            action = QAction("No microphones found", microphone_menu)
            action.setEnabled(False)
            microphone_menu.addAction(action)
            return

        group = QActionGroup(microphone_menu)
        group.setExclusive(True)
        for index, device in enumerate(devices, start=1):
            order = str(index)
            action = QAction(f"{index}. {device.description()}", microphone_menu)
            action.setCheckable(True)
            action.setChecked(selected_order == order)
            action.triggered.connect(
                lambda checked=False, selected_order=order: on_microphone_selected(selected_order)
            )
            group.addAction(action)
            microphone_menu.addAction(action)

    def _refresh_move_lock() -> None:
        move_lock_action.setChecked(move_lock_provider())

    menu.aboutToShow.connect(_refresh_move_lock)
    menu.aboutToShow.connect(_rebuild_language_menu)
    menu.aboutToShow.connect(_rebuild_microphone_menu)
    _refresh_move_lock()
    _rebuild_language_menu()
    _rebuild_microphone_menu()

    tray.setContextMenu(menu)
    tray.setToolTip("AirType Tray")
    tray.setContextMenu(menu)

    return tray


def set_tray_recording(tray: QSystemTrayIcon, recording: bool) -> None:
    tray.setIcon(_make_icon(recording))
    tray.setToolTip("AirType Recording" if recording else "AirType Tray")
