"""AirType Tray — cross-platform system tray app with floating dialog."""

import os
import platform
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication
from pynput.keyboard import Controller, Key

from tray_icon import create_tray, set_tray_recording
from floating_dialog import DEFAULT_BACKEND_ENDPOINT, FloatingDialog
from key_listener import DoubleEqualsListener


BACKEND_STARTUP_TIMEOUT_SECONDS = 8
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG_PATH = REPO_ROOT / "config.toml"
CONFIG_PATH = Path(os.getenv("AIRTYPE_CONFIG_PATH", str(DEFAULT_CONFIG_PATH)))
DEFAULT_CONFIG = """# AirType user config

[chinese-mode]
# Options: "zh-tw", "zh-cn"
mode = "zh-tw"

[backend]
# Options: "local", "remote"
mode = "local"
local_endpoint = "http://localhost:8003"
remote_endpoint = ""

[microphone]
# Leave empty to use the system default microphone.
selected_order = ""

[floating-dialog]
# Position is stored as the dialog center ratio across the whole desktop.
position_x_ratio = 0.5
position_y_ratio = 0.62
move_lock = true

[whisper-local]
# Local whisper.cpp runtime and model locations.
whisper_bin_dir = "/opt/homebrew/bin"
model_path = "~/.airtype/models/ggml-large-v3-turbo-q5_0.bin"
"""


def frontmost_app() -> dict[str, str]:
    """Return the currently focused macOS app identity when available."""
    if platform.system() != "Darwin":
        return {}

    app = _frontmost_app_with_appkit()
    if app:
        return app

    script = """
    tell application "System Events"
        set frontApp to first application process whose frontmost is true
        set appName to name of frontApp
        try
            set bundleId to bundle identifier of frontApp
        on error
            set bundleId to ""
        end try
        return bundleId & linefeed & appName
    end tell
    """
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=2,
            check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return {}

    lines = result.stdout.splitlines()
    return {
        "bundle_id": lines[0].strip() if lines else "",
        "name": lines[1].strip() if len(lines) > 1 else "",
    }


def _frontmost_app_with_appkit() -> dict[str, str]:
    try:
        from AppKit import NSWorkspace
    except ImportError:
        return {}

    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    if app is None:
        return {}

    return {
        "bundle_id": app.bundleIdentifier() or "",
        "name": app.localizedName() or "",
    }


def hide_dock_icon() -> None:
    """Hide the macOS Dock icon while keeping the tray/menu-bar app running."""
    if platform.system() != "Darwin":
        return

    try:
        from AppKit import NSApplication, NSApplicationActivationPolicyAccessory
    except ImportError:
        return

    NSApplication.sharedApplication().setActivationPolicy_(NSApplicationActivationPolicyAccessory)


def activate_app(app_identity: dict[str, str]) -> None:
    """Activate a previously focused macOS app."""
    if platform.system() != "Darwin" or not app_identity:
        return

    bundle_id = app_identity.get("bundle_id")
    name = app_identity.get("name")
    if bundle_id:
        script = f'tell application id "{bundle_id}" to activate'
    elif name:
        escaped_name = name.replace("\\", "\\\\").replace('"', '\\"')
        script = f'tell application "{escaped_name}" to activate'
    else:
        return

    try:
        subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=2)
    except (OSError, subprocess.SubprocessError):
        pass


def paste_text_at_cursor(text: str, target_app: dict[str, str] | None = None) -> None:
    """Paste text into the currently focused app using the system clipboard."""
    if not text:
        return

    app = QApplication.instance()
    if app is None:
        return

    clipboard = app.clipboard()
    previous_text = clipboard.text()

    def send_paste() -> None:
        clipboard.setText(text)
        app.processEvents()
        if target_app:
            activate_app(target_app)

        keyboard = Controller()
        paste_modifier = Key.cmd if platform.system() == "Darwin" else Key.ctrl
        time.sleep(0.3)
        with keyboard.pressed(paste_modifier):
            time.sleep(0.03)
            keyboard.press("v")
            time.sleep(0.03)
            keyboard.release("v")
        print("[AirType] Pasted ASR text at cursor.", flush=True)

        def restore_clipboard() -> None:
            if clipboard.text() == text:
                clipboard.setText(previous_text)

        QTimer.singleShot(5000, restore_clipboard)

    QTimer.singleShot(150, send_paste)


def ensure_user_config() -> None:
    if CONFIG_PATH.exists():
        return

    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(DEFAULT_CONFIG, encoding="utf-8")
    print(f"[AirType] Created config: {CONFIG_PATH}", flush=True)


def read_user_config() -> dict:
    ensure_user_config()
    try:
        with CONFIG_PATH.open("rb") as config_file:
            return tomllib.load(config_file)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        print(f"[AirType] Could not read config {CONFIG_PATH}: {exc}", flush=True)
        return {}


def _toml_string(value: object) -> str:
    text = str(value)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _toml_float(value: object, default: float) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = default
    return f"{number:.4f}".rstrip("0").rstrip(".")


def _bool(value: object, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    text = str(value).strip().lower()
    if text in {"1", "true", "yes", "on", "locked"}:
        return True
    if text in {"0", "false", "no", "off", "unlocked"}:
        return False
    return default


def _toml_bool(value: object, default: bool) -> str:
    return "true" if _bool(value, default) else "false"


def write_user_config(config: dict) -> None:
    chinese_mode = config.get("chinese-mode") or {}
    backend = config.get("backend") or {}
    microphone = config.get("microphone") or {}
    floating_dialog = config.get("floating-dialog") or {}
    whisper_local = config.get("whisper-local") or {}
    text = "\n".join(
        [
            "# AirType user config",
            "",
            "[chinese-mode]",
            '# Options: "zh-tw", "zh-cn"',
            f"mode = {_toml_string(chinese_mode.get('mode') or 'zh-tw')}",
            "",
            "[backend]",
            '# Options: "local", "remote"',
            f"mode = {_toml_string(backend.get('mode') or 'local')}",
            f"local_endpoint = {_toml_string(backend.get('local_endpoint') or DEFAULT_BACKEND_ENDPOINT)}",
            f"remote_endpoint = {_toml_string(backend.get('remote_endpoint') or '')}",
            "",
            "[microphone]",
            "# Leave empty to use the system default microphone.",
            f"selected_order = {_toml_string(microphone.get('selected_order') or '')}",
            "",
            "[floating-dialog]",
            "# Position is stored as the dialog center ratio across the whole desktop.",
            f"position_x_ratio = {_toml_float(floating_dialog.get('position_x_ratio'), 0.5)}",
            f"position_y_ratio = {_toml_float(floating_dialog.get('position_y_ratio'), 0.62)}",
            f"move_lock = {_toml_bool(floating_dialog.get('move_lock'), True)}",
            "",
            "[whisper-local]",
            "# Local whisper.cpp runtime and model locations.",
            f"whisper_bin_dir = {_toml_string(whisper_local.get('whisper_bin_dir') or '/opt/homebrew/bin')}",
            f"model_path = {_toml_string(whisper_local.get('model_path') or '~/.airtype/models/ggml-large-v3-turbo-q5_0.bin')}",
            "",
        ]
    )
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(text, encoding="utf-8")


def set_config_value(section: str, key: str, value: str) -> None:
    config = read_user_config()
    section_values = dict(config.get(section) or {})
    section_values[key] = value
    config[section] = section_values
    write_user_config(config)


def backend_endpoint() -> str:
    env_endpoint = os.getenv("AIRTYPE_BACKEND_ENDPOINT")
    if env_endpoint:
        return env_endpoint.rstrip("/")

    backend = read_user_config().get("backend", {})
    mode = str(backend.get("mode") or "local").strip().lower()
    if mode == "remote":
        endpoint = str(backend.get("remote_endpoint") or "").strip()
        if endpoint:
            return endpoint.rstrip("/")

    return str(backend.get("local_endpoint") or DEFAULT_BACKEND_ENDPOINT).rstrip("/")


def output_language() -> str:
    config = read_user_config()
    output = config.get("chinese-mode") or config.get("output") or {}
    language = str(output.get("mode") or output.get("language") or "zh-tw").strip().lower()
    aliases = {
        "traditional_chinese": "zh-tw",
        "traditional": "zh-tw",
        "tw": "zh-tw",
        "zh_tw": "zh-tw",
        "simple_chinese": "zh-cn",
        "simplified_chinese": "zh-cn",
        "simplified": "zh-cn",
        "cn": "zh-cn",
        "zh_cn": "zh-cn",
    }
    language = aliases.get(language, language)
    if language not in {"zh-tw", "zh-cn"}:
        return "zh-tw"
    return language


def set_output_language(language: str) -> None:
    set_config_value("chinese-mode", "mode", output_language_value(language))


def output_language_value(language: str) -> str:
    language = str(language).strip().lower()
    return language if language in {"zh-tw", "zh-cn"} else "zh-tw"


def microphone_device() -> str:
    microphone = read_user_config().get("microphone", {})
    return str(microphone.get("selected_order") or microphone.get("device") or "").strip()


def set_microphone_device(selected_order: str) -> None:
    set_config_value("microphone", "selected_order", str(selected_order).strip())


def _ratio(value: object, default: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    return min(1.0, max(0.0, number))


def floating_dialog_position() -> tuple[float, float]:
    floating_dialog = read_user_config().get("floating-dialog", {})
    return (
        _ratio(floating_dialog.get("position_x_ratio"), 0.5),
        _ratio(floating_dialog.get("position_y_ratio"), 0.62),
    )


def set_floating_dialog_position(x_ratio: float, y_ratio: float) -> None:
    config = read_user_config()
    section_values = dict(config.get("floating-dialog") or {})
    section_values["position_x_ratio"] = _ratio(x_ratio, 0.5)
    section_values["position_y_ratio"] = _ratio(y_ratio, 0.62)
    config["floating-dialog"] = section_values
    write_user_config(config)


def floating_dialog_move_locked() -> bool:
    floating_dialog = read_user_config().get("floating-dialog", {})
    return _bool(floating_dialog.get("move_lock"), True)


def set_floating_dialog_move_locked(locked: bool) -> None:
    set_config_value("floating-dialog", "move_lock", "true" if locked else "false")


def backend_health_url(endpoint: str) -> str:
    return endpoint.rstrip("/") + "/api/health"


def is_local_backend_endpoint(endpoint: str) -> bool:
    parsed = urllib.parse.urlparse(endpoint)
    return (parsed.hostname or "").lower() in {"localhost", "127.0.0.1", "::1"}


def backend_is_ready(endpoint: str, timeout: float = 0.35) -> bool:
    try:
        with urllib.request.urlopen(backend_health_url(endpoint), timeout=timeout) as response:
            return 200 <= response.status < 300
    except (OSError, urllib.error.URLError):
        return False


def wait_for_backend(endpoint: str, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if backend_is_ready(endpoint):
            return True
        time.sleep(0.2)
    return backend_is_ready(endpoint)


def start_backend_if_needed() -> subprocess.Popen | None:
    endpoint = backend_endpoint()
    if not is_local_backend_endpoint(endpoint):
        print(f"[AirType] Using remote backend endpoint: {endpoint}", flush=True)
        return None

    if backend_is_ready(endpoint):
        print(f"[AirType] Backend already running: {endpoint}", flush=True)
        return None

    parsed = urllib.parse.urlparse(endpoint)
    port = parsed.port or 8003
    repo_root = Path(__file__).resolve().parents[1]
    backend_dir = repo_root / "backend"
    python_bin = repo_root / ".venv" / "bin" / "python"
    if not python_bin.exists():
        python_bin = Path(sys.executable)

    command = [
        str(python_bin),
        "-m",
        "uvicorn",
        "app.main:app",
        "--host",
        "localhost",
        "--port",
        str(port),
        "--reload",
    ]
    print(f"[AirType] Starting backend: {' '.join(command)}", flush=True)
    process = subprocess.Popen(command, cwd=backend_dir)
    if wait_for_backend(endpoint, BACKEND_STARTUP_TIMEOUT_SECONDS):
        print(f"[AirType] Backend ready: {endpoint}", flush=True)
    elif process.poll() is not None:
        print(f"[AirType] Backend startup failed with exit code {process.returncode}.", flush=True)
        return None
    else:
        print(f"[AirType] Backend still starting: {endpoint}", flush=True)
    return process


def main() -> None:
    ensure_user_config()
    backend_process = start_backend_if_needed()
    if platform.system() == "Darwin":
        os.environ.setdefault("QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM", "1")

    app = QApplication(sys.argv)
    hide_dock_icon()
    QTimer.singleShot(0, hide_dock_icon)
    app.setApplicationName("AirType Tray")
    app.setStyle("Fusion")

    # --- System tray ---
    tray = create_tray(
        language_provider=output_language,
        on_language_selected=set_output_language,
        microphone_provider=microphone_device,
        on_microphone_selected=set_microphone_device,
        move_lock_provider=floating_dialog_move_locked,
        on_move_lock_selected=set_floating_dialog_move_locked,
    )
    tray.show()
    paste_target = {"app": {}}

    def on_transcription(text: str) -> None:
        paste_text_at_cursor(text, paste_target["app"])

    def on_recording_changed(recording: bool) -> None:
        set_tray_recording(tray, recording)

    # --- Floating dialog (hidden initially) ---
    dialog = FloatingDialog(
        on_transcription=on_transcription,
        on_recording_changed=on_recording_changed,
        language_provider=output_language,
        microphone_provider=microphone_device,
        backend_endpoint_provider=backend_endpoint,
        position_provider=floating_dialog_position,
        on_position_changed=set_floating_dialog_position,
        move_lock_provider=floating_dialog_move_locked,
    )
    dialog.hide()

    # --- Global key listener: right Ctrl double-press ---
    def on_double_equals() -> None:
        print("[AirType] 收到了：hotkey double-press", flush=True)
        if dialog.isVisible():
            dialog.hide()
        else:
            paste_target["app"] = frontmost_app()
            print(f"[AirType] paste target: {paste_target['app']}", flush=True)
            dialog.prepare_to_show()
            dialog.show()
            dialog.raise_()

    listener = DoubleEqualsListener(on_double_equals)
    listener.start()

    cleanup_started = {"value": False}

    def cleanup() -> None:
        if cleanup_started["value"]:
            return
        cleanup_started["value"] = True
        listener.stop()
        dialog.hide()
        if backend_process is not None and backend_process.poll() is None:
            backend_process.terminate()
            try:
                backend_process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                backend_process.kill()
                backend_process.wait(timeout=3)

    app.aboutToQuit.connect(cleanup)

    # --- macOS: Accessibility permission reminder ---
    if platform.system() == "Darwin":
        import sys as _sys
        _sys.stderr.write(
            "\n[INFO] macOS requires Accessibility permission for global keyboard monitoring.\n"
            "  If double-pressing = doesn't work:\n"
            "  1. System Settings > Privacy & Security > Accessibility\n"
            "  2. Add your Terminal or Python app\n"
            "  3. Restart the app\n\n"
        )
        _sys.stderr.flush()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
