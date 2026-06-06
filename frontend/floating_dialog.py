"""Borderless floating timer panel with microphone transcription."""

from array import array
from collections.abc import Callable
import io
import json
import math
import os
import platform
import struct
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave

from PySide6.QtWidgets import QApplication, QDialog, QHBoxLayout, QLabel, QWidget
from PySide6.QtCore import QObject, QPoint, QRect, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QPainter
from PySide6.QtMultimedia import QAudioFormat, QAudioSource, QMediaDevices

DEFAULT_BACKEND_ENDPOINT = "http://localhost:8003"
BACKEND_TRANSCRIBE_TIMEOUT_SECONDS = 60 * 60
DEFAULT_FLOATING_TRANSCRIBE_BEAM_SIZE = 1
FLOATING_TRANSCRIBE_RESPONSE_FORMAT = "json"
FLOATING_RECORD_TYPE = "ime"
RECORDING_TIMER_DELAY_MS = 200
MIN_RECORDING_RMS = 80


class _TranscriptionSignals(QObject):
    started = Signal()
    finished = Signal(str, int)
    failed = Signal(str, int)


class WaveformWidget(QWidget):
    """Small bar waveform driven by microphone input level."""

    def __init__(self) -> None:
        super().__init__()
        self._levels = [0.08] * 24
        self.setFixedSize(70, 18)

    def set_level(self, level: float) -> None:
        level = max(0.02, min(level, 1.0))
        self._levels = self._levels[1:] + [level]
        self.update()

    def reset(self) -> None:
        self._levels = [0.08] * 24
        self.update()

    def paintEvent(self, event) -> None:
        super().paintEvent(event)
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QColor(83, 232, 154, 230))

        bar_width = 2
        gap = 1
        center_y = self.height() / 2
        max_bar_height = self.height() - 2

        for index, level in enumerate(self._levels):
            height = max(2, max_bar_height * level)
            x = index * (bar_width + gap)
            y = center_y - height / 2
            painter.drawRoundedRect(x, y, bar_width, height, 1, 1)


class FloatingDialog(QDialog):
    """A borderless overlay panel showing the timer."""

    def __init__(
        self,
        on_transcription: Callable[[str], None] | None = None,
        on_recording_changed: Callable[[bool], None] | None = None,
        language_provider: Callable[[], str] | None = None,
        microphone_provider: Callable[[], str] | None = None,
        backend_endpoint_provider: Callable[[], str] | None = None,
        position_provider: Callable[[], tuple[float, float]] | None = None,
        on_position_changed: Callable[[float, float], None] | None = None,
        move_lock_provider: Callable[[], bool] | None = None,
    ) -> None:
        super().__init__()
        self._on_transcription = on_transcription
        self._on_recording_changed = on_recording_changed
        self._language_provider = language_provider
        self._microphone_provider = microphone_provider
        self._backend_endpoint_provider = backend_endpoint_provider
        self._position_provider = position_provider
        self._on_position_changed = on_position_changed
        self._move_lock_provider = move_lock_provider
        self._audio_source = None
        self._audio_io = None
        self._audio_format = None
        self._recorded_pcm_chunks: list[bytes] = []
        self._recording_sample_rate = 16000
        self._recording_active = False
        self._recording_generation = 0
        self._transcribing = False
        self._drag_offset = QPoint()
        self._dragging = False
        self._signals = _TranscriptionSignals()
        self._signals.started.connect(self._on_transcription_started)
        self._signals.finished.connect(self._on_transcription_finished)
        self._signals.failed.connect(self._on_transcription_failed)
        self._started_at = time.monotonic()
        self._timer = QTimer(self)
        self._timer.setInterval(250)
        self._timer.timeout.connect(self._update_text)
        self._audio_timer = QTimer(self)
        self._audio_timer.setInterval(50)
        self._audio_timer.timeout.connect(self._read_audio)
        self._init_ui()

    def _init_ui(self) -> None:
        # Window flags: no frame, always on top, app window
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Window
            | Qt.WindowType.WindowStaysOnTopHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, False)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
        self.setFocusPolicy(Qt.FocusPolicy.NoFocus)
        self.setWindowTitle("AirType Waveform Panel")

        self.setFixedSize(144, 32)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        panel = QWidget(self)
        panel.setObjectName("floatingPanel")
        panel.setStyleSheet(
            """
            QWidget#floatingPanel {
                background: #171c22;
                border: 1px solid #53e89a;
                border-radius: 7px;
            }
            """
        )
        panel_layout = QHBoxLayout(panel)
        panel_layout.setContentsMargins(6, 3, 6, 3)
        panel_layout.setSpacing(6)

        self._label = QLabel("00:00")
        self._label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._label.setFont(QFont("Arial", 12, QFont.Weight.Bold))
        self._label.setStyleSheet(
            """
            QLabel {
                color: #ffffff;
                background: transparent;
            }
            """
        )
        panel_layout.addWidget(self._label)

        self._waveform = WaveformWidget()
        panel_layout.addWidget(self._waveform)

        layout.addWidget(panel)

    def _update_text(self) -> None:
        elapsed_seconds = int(time.monotonic() - self._started_at)
        minutes, seconds = divmod(elapsed_seconds, 60)
        self._label.setText(f"{minutes:02d}:{seconds:02d}")

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._prepare_pending_view()
        self._recording_generation += 1
        generation = self._recording_generation
        self._recording_active = False
        self._set_recording_active(False)
        self._move_to_configured_position()
        self.setWindowOpacity(1)
        self._force_top_most()
        QTimer.singleShot(0, self._force_top_most)
        QTimer.singleShot(80, self._force_top_most)
        QTimer.singleShot(250, self._force_top_most)
        QTimer.singleShot(0, lambda: self._start_audio_for_generation(generation))

    def hideEvent(self, event) -> None:
        super().hideEvent(event)
        self._timer.stop()
        self._set_recording_active(False)
        self._recording_generation += 1
        self._stop_audio()

    def prepare_to_show(self) -> None:
        """Set the first visible frame to an empty pending state."""
        self._prepare_pending_view()

    def _force_top_most(self) -> None:
        self.raise_()
        self._set_macos_window_level()

    def _set_macos_window_level(self) -> None:
        if platform.system() != "Darwin":
            return

        try:
            from AppKit import NSApplication, NSStatusWindowLevel
        except ImportError:
            return

        try:
            for ns_window in NSApplication.sharedApplication().windows():
                title = str(ns_window.title() or "")
                if ns_window.isVisible() and title == self.windowTitle():
                    ns_window.setLevel_(NSStatusWindowLevel)
        except Exception:
            return

    def _prepare_pending_view(self) -> None:
        self._label.setText("")
        self._label.hide()
        self._waveform.reset()
        self._waveform.hide()

    def _begin_recording(self, generation: int) -> None:
        if generation != self._recording_generation or not self.isVisible() or self._audio_io is None:
            return

        self._set_recording_active(True)
        self._started_at = time.monotonic()
        self._update_text()
        self._label.show()
        self._waveform.show()
        self._timer.start()

    def _move_to_configured_position(self) -> None:
        x_ratio, y_ratio = (0.5, 0.62)
        if self._position_provider:
            x_ratio, y_ratio = self._position_provider()
        desktop = self._desktop_geometry()
        center_x = desktop.left() + round(desktop.width() * x_ratio)
        center_y = desktop.top() + round(desktop.height() * y_ratio)
        self.move(self._clamped_top_left(QPoint(center_x - self.width() // 2, center_y - self.height() // 2)))

    def _desktop_geometry(self) -> QRect:
        screens = QApplication.screens()
        if not screens:
            return self.screen().geometry()

        desktop = screens[0].geometry()
        for screen in screens[1:]:
            desktop = desktop.united(screen.geometry())
        return desktop

    def _clamped_top_left(self, top_left: QPoint) -> QPoint:
        desktop = self._desktop_geometry()
        max_x = desktop.right() - self.width() + 1
        max_y = desktop.bottom() - self.height() + 1
        x = min(max(top_left.x(), desktop.left()), max_x)
        y = min(max(top_left.y(), desktop.top()), max_y)
        return QPoint(x, y)

    def _save_position_ratio(self) -> None:
        if not self._on_position_changed:
            return

        desktop = self._desktop_geometry()
        center = self.frameGeometry().center()
        x_ratio = (center.x() - desktop.left()) / max(1, desktop.width())
        y_ratio = (center.y() - desktop.top()) / max(1, desktop.height())
        self._on_position_changed(x_ratio, y_ratio)

    def update_state(self) -> None:
        """Refresh displayed timer text."""
        self._update_text()

    def mousePressEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton:
            if self._move_locked():
                event.accept()
                return
            self._dragging = True
            self._drag_offset = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()
            return
        super().mousePressEvent(event)

    def _move_locked(self) -> bool:
        if self._move_lock_provider:
            return self._move_lock_provider()
        return True

    def mouseMoveEvent(self, event) -> None:
        if self._dragging and event.buttons() & Qt.MouseButton.LeftButton:
            self.move(self._clamped_top_left(event.globalPosition().toPoint() - self._drag_offset))
            self._save_position_ratio()
            event.accept()
            return
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event) -> None:
        if event.button() == Qt.MouseButton.LeftButton and self._dragging:
            self._dragging = False
            self._save_position_ratio()
            event.accept()
            return
        super().mouseReleaseEvent(event)

    def _start_audio_for_generation(self, generation: int) -> None:
        if generation != self._recording_generation or not self.isVisible():
            return
        self._start_audio()
        QTimer.singleShot(RECORDING_TIMER_DELAY_MS, lambda: self._begin_recording(generation))

    def _start_audio(self) -> None:
        audio_device = self._selected_audio_input()
        if audio_device.isNull():
            print("[AirType] No default microphone found.", flush=True)
            return

        audio_format = QAudioFormat()
        audio_format.setSampleRate(16000)
        audio_format.setChannelCount(1)
        audio_format.setSampleFormat(QAudioFormat.SampleFormat.Int16)

        if not audio_device.isFormatSupported(audio_format):
            audio_format = audio_device.preferredFormat()

        self._audio_format = audio_format
        self._recording_sample_rate = audio_format.sampleRate()
        self._recorded_pcm_chunks = []
        self._audio_source = QAudioSource(audio_device, audio_format, self)
        self._audio_source.setBufferSize(4096)
        self._audio_io = self._audio_source.start()
        if self._audio_io is None:
            print("[AirType] Could not start microphone input.", flush=True)
            self._set_recording_active(False)
            return

        self._audio_timer.start()

    def _selected_audio_input(self):
        selected_order = ""
        if self._microphone_provider:
            selected_order = self._microphone_provider()
        devices = QMediaDevices.audioInputs()
        if selected_order:
            try:
                index = int(selected_order) - 1
            except ValueError:
                index = -1
            if 0 <= index < len(devices):
                return devices[index]
            print(f"[AirType] Configured microphone order not found: {selected_order}", flush=True)
        return QMediaDevices.defaultAudioInput()

    def _stop_audio(self) -> None:
        self._audio_timer.stop()
        self._set_recording_active(False)
        if self._audio_source is not None:
            self._audio_source.stop()
        wav_bytes = self._recording_wav()
        self._audio_source = None
        self._audio_io = None
        self._audio_format = None
        self._recorded_pcm_chunks = []
        if wav_bytes:
            self._submit_transcription(wav_bytes)

    def _set_recording_active(self, active: bool) -> None:
        if self._recording_active == active:
            return
        self._recording_active = active
        if self._on_recording_changed:
            self._on_recording_changed(active)

    def _read_audio(self) -> None:
        if self._audio_io is None or self._audio_format is None:
            return

        data = bytes(self._audio_io.readAll())
        if not data:
            self._waveform.set_level(0.02)
            return

        if self._recording_active:
            level = self._audio_level(data)
            self._waveform.set_level(level)

        pcm = self._pcm16_mono(data)
        if pcm:
            self._recorded_pcm_chunks.append(pcm)

    def _audio_level(self, data: bytes) -> float:
        sample_format = self._audio_format.sampleFormat()

        if sample_format == QAudioFormat.SampleFormat.Int16:
            samples = array("h")
            samples.frombytes(data[: len(data) - (len(data) % 2)])
            if not samples:
                return 0.02
            rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
            return min(1.0, (rms / 32768.0) * 8)

        if sample_format == QAudioFormat.SampleFormat.Float:
            samples = array("f")
            samples.frombytes(data[: len(data) - (len(data) % 4)])
            if not samples:
                return 0.02
            rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
            return min(1.0, rms * 8)

        if sample_format == QAudioFormat.SampleFormat.UInt8:
            samples = data
            rms = math.sqrt(sum((sample - 128) * (sample - 128) for sample in samples) / len(samples))
            return min(1.0, (rms / 128.0) * 8)

        return 0.02

    def _pcm16_mono(self, data: bytes) -> bytes:
        if self._audio_format is None:
            return b""

        sample_format = self._audio_format.sampleFormat()
        channel_count = max(1, self._audio_format.channelCount())

        if sample_format == QAudioFormat.SampleFormat.Int16:
            samples = array("h")
            samples.frombytes(data[: len(data) - (len(data) % 2)])
            values = list(samples)
        elif sample_format == QAudioFormat.SampleFormat.Float:
            samples = array("f")
            samples.frombytes(data[: len(data) - (len(data) % 4)])
            values = [max(-32768, min(32767, int(sample * 32767))) for sample in samples]
        elif sample_format == QAudioFormat.SampleFormat.UInt8:
            values = [(sample - 128) * 256 for sample in data]
        else:
            return b""

        if not values:
            return b""

        mono_values = []
        usable_length = len(values) - (len(values) % channel_count)
        for index in range(0, usable_length, channel_count):
            frame = values[index : index + channel_count]
            mono_values.append(int(sum(frame) / channel_count))

        if not mono_values:
            return b""

        return struct.pack(f"<{len(mono_values)}h", *mono_values)

    def _recording_wav(self) -> bytes:
        if not self._recorded_pcm_chunks:
            return b""

        pcm = b"".join(self._recorded_pcm_chunks)
        if len(pcm) < self._recording_sample_rate:
            print("[AirType] Recording too short; skipped ASR.", flush=True)
            return b""
        rms = self._pcm_rms(pcm)
        if rms < MIN_RECORDING_RMS:
            print(f"[AirType] Recording too quiet; skipped ASR. rms={rms}", flush=True)
            return b""

        output = io.BytesIO()
        with wave.open(output, "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(self._recording_sample_rate)
            wav_file.writeframes(pcm)
        return output.getvalue()

    def _pcm_rms(self, pcm: bytes) -> int:
        samples = array("h")
        samples.frombytes(pcm[: len(pcm) - (len(pcm) % 2)])
        if not samples:
            return 0
        return round(math.sqrt(sum(sample * sample for sample in samples) / len(samples)))

    def _submit_transcription(self, wav_bytes: bytes) -> None:
        if self._transcribing:
            print("[AirType] ASR already running; skipped new recording.", flush=True)
            return

        language = self._output_language()
        thread = threading.Thread(
            target=self._transcribe_in_background,
            args=(wav_bytes, language),
            daemon=True,
        )
        thread.start()

    def _transcribe_in_background(self, wav_bytes: bytes, language: str | None) -> None:
        self._signals.started.emit()
        request_started_at = time.monotonic()
        try:
            endpoint = self._backend_endpoint()
            print(f"[AirType] Using backend endpoint: {endpoint}", flush=True)
            result, frontend_timing = self._transcribe_audio(wav_bytes, endpoint, language)
            text = str(result.get("text") or "").strip()
            if not text:
                raise RuntimeError("ASR completed without text.")
            self._print_timing("ASR frontend timing", frontend_timing)
            self._print_backend_timing(result)
            self._signals.finished.emit(text, self._elapsed_ms(request_started_at))
        except Exception as exc:
            self._signals.failed.emit(str(exc), self._elapsed_ms(request_started_at))

    def _elapsed_ms(self, started_at: float) -> int:
        return round((time.monotonic() - started_at) * 1000)

    def _output_language(self) -> str | None:
        if self._language_provider:
            language = self._language_provider()
            if language:
                return language
        return os.getenv("AIRTYPE_WHISPER_LANGUAGE") or None

    def _backend_endpoint(self) -> str:
        if self._backend_endpoint_provider:
            endpoint = self._backend_endpoint_provider()
            if endpoint:
                return endpoint
        return os.getenv("AIRTYPE_BACKEND_ENDPOINT", DEFAULT_BACKEND_ENDPOINT)

    def _floating_transcribe_beam_size(self) -> int:
        value = os.getenv("AIRTYPE_FLOATING_WHISPER_BEAM_SIZE", "").strip()
        if not value:
            return DEFAULT_FLOATING_TRANSCRIBE_BEAM_SIZE
        try:
            return max(1, int(value))
        except ValueError:
            return DEFAULT_FLOATING_TRANSCRIBE_BEAM_SIZE

    def _transcribe_audio(self, wav_bytes: bytes, endpoint: str, language: str | None) -> tuple[dict, dict[str, int]]:
        total_started_at = time.monotonic()
        url = endpoint.rstrip("/") + "/api/transcribe/ime"
        fields = [
            ("beam_size", str(self._floating_transcribe_beam_size())),
            ("response_format", FLOATING_TRANSCRIBE_RESPONSE_FORMAT),
            ("record_type", FLOATING_RECORD_TYPE),
        ]
        if language:
            fields.append(("language", language))

        multipart_started_at = time.monotonic()
        data, content_type = self._multipart_form_data(fields, wav_bytes)
        multipart_ms = self._elapsed_ms(multipart_started_at)
        request = urllib.request.Request(url, data=data, headers={"Content-Type": content_type}, method="POST")
        payload, http_timing = self._open_json(request, BACKEND_TRANSCRIBE_TIMEOUT_SECONDS)
        timing = {
            "multipart_build": multipart_ms,
            **http_timing,
            "total_request": self._elapsed_ms(total_started_at),
        }
        return payload, timing

    def _print_backend_timing(self, result: dict) -> None:
        debug = result.get("debug") or {}
        timing = debug.get("timing_ms") or {}
        if not timing:
            return

        conversion_mode = debug.get("conversion_mode")
        if conversion_mode:
            print(f"[AirType] ASR backend conversion: {conversion_mode}", flush=True)
        request_fields = debug.get("request_fields") or {}
        if request_fields:
            fields = ", ".join(f"{name}={value}" for name, value in request_fields.items())
            print(f"[AirType] ASR whisper request: {fields}", flush=True)
        self._print_timing("ASR backend timing", timing)

    def _print_timing(self, label: str, timing: dict) -> None:
        parts = [f"{name}={value} ms" for name, value in timing.items()]
        print(f"[AirType] {label}: {', '.join(parts)}", flush=True)

    def _open_json(self, request: urllib.request.Request, timeout: int) -> tuple[dict, dict[str, int]]:
        try:
            http_started_at = time.monotonic()
            with urllib.request.urlopen(request, timeout=timeout) as response:
                headers_ms = self._elapsed_ms(http_started_at)
                response_started_at = time.monotonic()
                body = response.read()
            read_ms = self._elapsed_ms(response_started_at)
            parse_started_at = time.monotonic()
            payload = json.loads(body.decode("utf-8"))
            parse_ms = self._elapsed_ms(parse_started_at)
            return payload, {
                "backend_http_headers": headers_ms,
                "response_read": read_ms,
                "response_parse": parse_ms,
                "backend_http_total": self._elapsed_ms(http_started_at),
            }
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Backend request failed: {detail}") from exc

    def _multipart_form_data(self, fields: list[tuple[str, str]], wav_bytes: bytes) -> tuple[bytes, str]:
        boundary = f"----AirType{uuid.uuid4().hex}"
        body = bytearray()
        for name, value in fields:
            body.extend(f"--{boundary}\r\n".encode())
            body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            body.extend(str(value).encode())
            body.extend(b"\r\n")

        body.extend(f"--{boundary}\r\n".encode())
        body.extend(b'Content-Disposition: form-data; name="file"; filename="recording.wav"\r\n')
        body.extend(b"Content-Type: audio/wav\r\n\r\n")
        body.extend(wav_bytes)
        body.extend(b"\r\n")
        body.extend(f"--{boundary}--\r\n".encode())
        return bytes(body), f"multipart/form-data; boundary={boundary}"

    def _on_transcription_started(self) -> None:
        self._transcribing = True
        print("[AirType] Uploading microphone audio to backend transcription...", flush=True)

    def _on_transcription_finished(self, text: str, elapsed_ms: int) -> None:
        self._transcribing = False
        print(f"[AirType] ASR ({elapsed_ms} ms): {text}", flush=True)
        if self._on_transcription:
            self._on_transcription(text)

    def _on_transcription_failed(self, message: str, elapsed_ms: int) -> None:
        self._transcribing = False
        if "HTTP Error" in message:
            print(f"[AirType] backend transcription request failed ({elapsed_ms} ms): {message}", flush=True)
        else:
            print(f"[AirType] ASR failed ({elapsed_ms} ms): {message}", flush=True)
