"""Global right Ctrl double-press listener (cross-platform).

macOS: uses pynput (requires Accessibility permission).
Linux/Windows: uses keyboard library.

Uses Qt signals for thread-safe communication to the main thread.
"""

import platform
import time

from PySide6.QtCore import QObject, Signal

_SYSTEM = platform.system()


class _KeySignal(QObject):
    """Emits a signal when the hotkey is double-pressed."""
    double_pressed = Signal()


class DoubleEqualsListener:
    """Listens for double-press of the right Ctrl key."""

    def __init__(self, on_double_press: callable) -> None:
        self._on_double_press = on_double_press
        self._last_right_ctrl_press_time: float = 0
        self._double_press_threshold = 0.4  # seconds
        self._signals = _KeySignal()
        self._signals.double_pressed.connect(on_double_press)
        self._listener = None
        self._keyboard_hook = None

    def start(self) -> None:
        if _SYSTEM == "Darwin":
            self._start_macos()
        else:
            self._start_other()

    def stop(self) -> None:
        if self._listener:
            self._listener.stop()
            self._listener = None
        if self._keyboard_hook:
            import keyboard

            keyboard.unhook(self._keyboard_hook)
            self._keyboard_hook = None

    def _start_macos(self) -> None:
        from pynput import keyboard as pynput_keyboard

        threshold = 0.4

        def _on_press(key):
            try:
                if getattr(key, "name", None) == "ctrl_r":
                    now = time.monotonic()
                    if now - self._last_right_ctrl_press_time < threshold:
                        self._signals.double_pressed.emit()
                        self._last_right_ctrl_press_time = 0
                    else:
                        self._last_right_ctrl_press_time = now
                    return
            except Exception:
                pass

        self._listener = pynput_keyboard.Listener(on_press=_on_press)
        self._listener.daemon = True
        self._listener.start()

    def _start_other(self) -> None:
        import keyboard

        def _on_key(event):
            if event.event_type != "down":
                return

            if event.name in {"right ctrl", "ctrl right", "ctrl_r"}:
                now = time.monotonic()
                if now - self._last_right_ctrl_press_time < self._double_press_threshold:
                    self._signals.double_pressed.emit()
                    self._last_right_ctrl_press_time = 0
                else:
                    self._last_right_ctrl_press_time = now
                return

        self._keyboard_hook = keyboard.hook(_on_key)
