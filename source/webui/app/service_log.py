from __future__ import annotations

import io
import logging
import os
import sys
import threading
from pathlib import Path

WEBUI_LOG_PATH = Path("~/.airtype/airtype-webui.log").expanduser()
_LOG_LOCK = threading.Lock()


def append_service_log(service: str, message: str) -> None:
    try:
        WEBUI_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with _LOG_LOCK:
            with WEBUI_LOG_PATH.open("a", encoding="utf-8") as log_file:
                log_file.write(f"[{service}] {message}\n")
    except OSError as exc:
        print(f"[AirType] webui log write failed: {exc}", file=sys.__stderr__, flush=True)


class _ServiceLogStream(io.TextIOBase):
    def __init__(self, service: str) -> None:
        self._service = service
        self._buffer = ""

    @property
    def encoding(self) -> str:
        return "utf-8"

    def writable(self) -> bool:
        return True

    def write(self, text: str) -> int:
        if not text:
            return 0
        self._buffer += text
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            append_service_log(self._service, line.rstrip("\r"))
        return len(text)

    def flush(self) -> None:
        if self._buffer:
            append_service_log(self._service, self._buffer.rstrip("\r"))
            self._buffer = ""


class _ServiceLogHandler(logging.Handler):
    def __init__(self, service: str) -> None:
        super().__init__()
        self._service = service
        self.setFormatter(logging.Formatter("%(levelname)s: %(message)s"))

    def emit(self, record: logging.LogRecord) -> None:
        try:
            append_service_log(self._service, self.format(record))
        except Exception:
            self.handleError(record)


def _install_logger_handler(logger_name: str) -> None:
    logger = logging.getLogger(logger_name)
    if any(getattr(handler, "_airtype_service_log", False) for handler in logger.handlers):
        return

    handler = _ServiceLogHandler("webui")
    handler._airtype_service_log = True
    logger.addHandler(handler)


def install_webui_logging() -> None:
    if getattr(install_webui_logging, "_installed", False):
        return
    install_webui_logging._installed = True

    sys.stdout = _ServiceLogStream("webui")
    sys.stderr = _ServiceLogStream("webui")
    if os.environ.get("AIRTYPE_WEBUI_CAPTURE_UVICORN_LOGS") != "0":
        for logger_name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
            _install_logger_handler(logger_name)
