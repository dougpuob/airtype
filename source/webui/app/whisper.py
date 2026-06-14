"""
whisper.cpp integration for transcript generation.
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from collections import deque
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from opencc import OpenCC

from .config_schema import ensure_config_exists, read_webui_settings
from .service_log import append_service_log

LANGUAGE_ALIASES = {
    "zh-tw": "zh",
    "zh-cn": "zh",
}

OPENCC_CONFIGS = {
    "zh-tw": "s2twp",
    "zh-cn": "t2s",
}

def _find_config_path() -> Path:
    config_path = Path("~/.airtype/config.toml").expanduser().resolve()
    if not config_path.exists():
        ensure_config_exists(config_path, generator_name="webui whisper import")
        append_service_log("webui", f"config file missing; generated default config from schema path={config_path}")
    return config_path


CONFIG_PATH = _find_config_path()


class WhisperCppNotConfigured(RuntimeError):
    """Raised when whisper.cpp is not available on this machine."""


def _read_backend_settings() -> Dict[str, Any]:
    return read_webui_settings(CONFIG_PATH)


class WhisperCppTranscriber:
    """Run ffmpeg + whisper.cpp against audio or video sources."""

    def __init__(self) -> None:
        self.default_model = self._configured_model_path() or self._default_model_path()
        self._server_lock = threading.Lock()
        self._server_process: Optional[subprocess.Popen] = None
        self._server_endpoint: Optional[str] = None
        self._server_model: Optional[str] = None
        self._server_args: list[str] = []
        self._server_output_tail: deque[str] = deque(maxlen=80)
        self._opencc: Dict[str, OpenCC] = {}

    @property
    def server_binary(self) -> Optional[str]:
        configured = self._configured_server_bin()
        if configured:
            return configured

        path = shutil.which("whisper-server")
        if path:
            return path
        return None

    def _default_model_path(self) -> str:
        return "models/ggml-base.bin"

    def _configured_model_path(self) -> Optional[str]:
        settings = self._whisper_local_config()
        model_dir = settings.get("model_dir")
        model_filename = settings.get("model_filename")
        if (
            isinstance(model_dir, str)
            and model_dir.strip()
            and isinstance(model_filename, str)
            and model_filename.strip()
        ):
            return str(Path(model_dir.strip()).expanduser() / model_filename.strip())

        return None

    def _configured_server_bin(self) -> Optional[str]:
        value = self._whisper_local_config().get("server_bin")
        if isinstance(value, str) and value.strip():
            return str(Path(value.strip()).expanduser())
        return None

    def _whisper_local_config(self) -> Dict[str, Any]:
        whisper_settings = _read_backend_settings().get("whisper", {})
        return whisper_settings if isinstance(whisper_settings, dict) else {}

    def transcribe(
        self,
        source_path: str,
        model_path: Optional[str] = None,
        server_endpoint: Optional[str] = None,
        server_args: Optional[str] = None,
        language: Optional[str] = None,
        temperature: float = 0.0,
        beam_size: int = 5,
        progress_callback: Optional[Callable[[int, str], None]] = None,
        cancel_event: Optional[threading.Event] = None,
        process_callback: Optional[Callable[[subprocess.Popen], None]] = None,
        segment_callback: Optional[Callable[[Dict[str, Any]], None]] = None,
    ) -> Dict[str, Any]:
        total_started_at = time.monotonic()
        self._raise_if_cancelled(cancel_event)
        self._progress(progress_callback, 5, "Preparing whisper.cpp server")

        selected_model = model_path or self._configured_model_path() or self.default_model
        output_language = language
        whisper_language = self._whisper_language(language)
        use_local_server = not (server_endpoint or "").strip()
        append_service_log(
            "webui",
            "transcribe start "
            f"source={source_path} mode={'local' if use_local_server else 'remote'} "
            f"model={selected_model} language={language or ''} beam={beam_size} temperature={temperature}",
        )
        if use_local_server and not Path(selected_model).exists():
            raise WhisperCppNotConfigured(
                f"whisper.cpp model not found: {selected_model}. Set [webui.whisper-server].model_dir and model_filename in ~/.airtype/config.toml."
            )

        with tempfile.TemporaryDirectory(prefix="airtype-transcribe-") as work_dir:
            wav_path = os.path.join(work_dir, "input.wav")
            self._progress(progress_callback, 15, "Extracting audio with ffmpeg")
            convert_started_at = time.monotonic()
            conversion_mode = self._convert_to_wav(source_path, wav_path, cancel_event, process_callback)
            convert_ms = self._elapsed_ms(convert_started_at)
            wav_bytes = os.path.getsize(wav_path) if os.path.exists(wav_path) else 0
            append_service_log(
                "webui",
                f"audio ready mode={conversion_mode} wav_bytes={wav_bytes} elapsed_ms={convert_ms}",
            )
            self._raise_if_cancelled(cancel_event)
            endpoint = (server_endpoint or "").strip()
            server_ready_started_at = time.monotonic()
            if not endpoint:
                endpoint = self._ensure_local_server(selected_model, server_args, progress_callback)
            server_ready_ms = self._elapsed_ms(server_ready_started_at)
            append_service_log("webui", f"whisper-server ready endpoint={endpoint} elapsed_ms={server_ready_ms}")
            self._progress(progress_callback, 35, "Sending audio to whisper.cpp server")
            try:
                result = self._transcribe_with_server(
                    endpoint=endpoint,
                    wav_path=wav_path,
                    language=whisper_language,
                    output_language=output_language,
                    temperature=temperature,
                    beam_size=beam_size,
                    progress_callback=progress_callback,
                    cancel_event=cancel_event,
                    segment_callback=segment_callback,
                )
            except Exception as exc:
                append_service_log("webui", f"transcribe failed endpoint={endpoint} error={exc}")
                raise
            self._raise_if_cancelled(cancel_event)
            self._progress(progress_callback, 92, "Reading transcript")
            timing = result.setdefault("debug", {}).setdefault("timing_ms", {})
            timing.update(
                {
                    "convert_wav": convert_ms,
                    "server_ready": server_ready_ms,
                    "total_backend": self._elapsed_ms(total_started_at),
                }
            )
            result["debug"]["conversion_mode"] = conversion_mode
            append_service_log(
                "webui",
                "transcribe complete "
                f"endpoint={endpoint} chars={len(result.get('text', ''))} "
                f"segments={len(result.get('segments', []))} elapsed_ms={timing['total_backend']}",
            )
            return result

    def _convert_to_wav(
        self,
        source_path: str,
        wav_path: str,
        cancel_event: Optional[threading.Event],
        process_callback: Optional[Callable[[subprocess.Popen], None]],
    ) -> str:
        if self._copy_if_target_wav(source_path, wav_path):
            return "direct_wav_copy"

        command = [
            "ffmpeg",
            "-y",
            "-i",
            source_path,
            "-vn",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
            wav_path,
        ]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if process_callback:
            process_callback(process)
        while process.poll() is None:
            self._raise_if_cancelled(cancel_event, process)
            time.sleep(0.25)
        stdout, stderr = process.communicate()
        self._raise_if_cancelled(cancel_event)
        if process.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {(stderr or stdout).strip()}")
        return "ffmpeg"

    def _elapsed_ms(self, started_at: float) -> int:
        return round((time.monotonic() - started_at) * 1000)

    def _copy_if_target_wav(self, source_path: str, wav_path: str) -> bool:
        try:
            with wave.open(source_path, "rb") as wav_file:
                is_target_format = (
                    wav_file.getnchannels() == 1
                    and wav_file.getframerate() == 16000
                    and wav_file.getsampwidth() == 2
                    and wav_file.getcomptype() == "NONE"
                )
        except (OSError, EOFError, wave.Error):
            return False

        if not is_target_format:
            return False

        shutil.copyfile(source_path, wav_path)
        return True

    def _ensure_local_server(
        self,
        model_path: str,
        server_args: Optional[str],
        progress_callback: Optional[Callable[[int, str], None]],
    ) -> str:
        parsed_server_args = self._server_args_from_settings(server_args)

        with self._server_lock:
            if (
                self._server_process
                and self._server_process.poll() is None
                and self._server_endpoint
                and self._server_model == model_path
                and self._server_args == parsed_server_args
            ):
                append_service_log(
                    "webui",
                    f"reusing local whisper-server pid={self._server_process.pid} endpoint={self._server_endpoint}",
                )
                return self._server_endpoint

            if self._server_process and self._server_process.poll() is None:
                append_service_log("webui", f"stopping stale whisper-server pid={self._server_process.pid}")
                self._server_process.terminate()
                try:
                    self._server_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    append_service_log("webui", f"killing stale whisper-server pid={self._server_process.pid}")
                    self._server_process.kill()

            server_bin = self.server_binary
            if not server_bin:
                raise WhisperCppNotConfigured(
                    "whisper.cpp server executable not found. Set [webui.whisper-server].server_bin in ~/.airtype/config.toml."
                )

            host = "127.0.0.1"
            port = self._free_port()
            endpoint = f"http://{host}:{port}"
            command = [
                server_bin,
                "-m",
                model_path,
                "--host",
                host,
                "--port",
                str(port),
            ]
            command.extend(parsed_server_args)
            self._progress(progress_callback, 20, "Starting local whisper.cpp server")
            append_service_log(
                "webui",
                f"starting local whisper-server bin={server_bin} model={model_path} endpoint={endpoint} args={parsed_server_args}",
            )
            self._server_process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            self._server_output_tail.clear()
            self._start_server_log_reader(self._server_process)
            self._server_endpoint = endpoint
            self._server_model = model_path
            self._server_args = parsed_server_args
            self._wait_for_server(endpoint)
            append_service_log("webui", f"started local whisper-server pid={self._server_process.pid} endpoint={endpoint}")
            return endpoint

    def shutdown(self) -> None:
        """Stop the managed local whisper.cpp server, if this process started one."""
        with self._server_lock:
            process = self._server_process
            self._server_process = None
            self._server_endpoint = None
            self._server_model = None
            self._server_args = []
            self._server_output_tail.clear()

        if not process or process.poll() is not None:
            return

        append_service_log("webui", f"stopping managed whisper-server pid={process.pid}")
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            append_service_log("webui", f"killing managed whisper-server pid={process.pid}")
            process.kill()
            process.wait(timeout=5)

    def status(self) -> Dict[str, Any]:
        """Return the managed local whisper.cpp server state."""
        with self._server_lock:
            process = self._server_process
            running = bool(process and process.poll() is None)
            return {
                "running": running,
                "endpoint": self._server_endpoint if running else "",
                "model": self._server_model if running else "",
                "server_args": " ".join(self._server_args) if running else "",
                "pid": process.pid if running and process else None,
            }

    def _server_args_from_settings(self, server_args: Optional[str]) -> list[str]:
        raw_args = (server_args or "").strip()
        if not raw_args:
            return []
        try:
            return shlex.split(raw_args)
        except ValueError as exc:
            raise WhisperCppNotConfigured(f"Invalid whisper-server args: {exc}") from exc

    def _free_port(self) -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])

    def _start_server_log_reader(self, process: subprocess.Popen) -> None:
        def read_output() -> None:
            if not process.stdout:
                return
            try:
                for raw_line in process.stdout:
                    line = raw_line.rstrip("\r\n")
                    self._server_output_tail.append(line)
                    append_service_log("whisper-server", line)
            except Exception as exc:
                append_service_log("whisper-server", f"log reader stopped: {exc}")

        thread = threading.Thread(target=read_output, name="whisper-server-log-reader", daemon=True)
        thread.start()

    def _wait_for_server(self, endpoint: str) -> None:
        last_error: Optional[Exception] = None
        for _ in range(60):
            if self._server_process and self._server_process.poll() is not None:
                output = "\n".join(self._server_output_tail)
                raise WhisperCppNotConfigured(f"whisper-server exited early: {output.strip()}")
            try:
                urllib.request.urlopen(endpoint, timeout=1).close()
                return
            except urllib.error.HTTPError as exc:
                if exc.code < 500:
                    return
                last_error = exc
                time.sleep(0.5)
            except Exception as exc:
                last_error = exc
                time.sleep(0.5)
        raise WhisperCppNotConfigured(f"whisper-server did not become ready: {last_error}")

    def _transcribe_with_server(
        self,
        endpoint: str,
        wav_path: str,
        language: Optional[str],
        output_language: Optional[str],
        temperature: float,
        beam_size: int,
        progress_callback: Optional[Callable[[int, str], None]],
        cancel_event: Optional[threading.Event],
        segment_callback: Optional[Callable[[Dict[str, Any]], None]],
    ) -> Dict[str, Any]:
        self._raise_if_cancelled(cancel_event)
        total_started_at = time.monotonic()
        url = self._inference_url(endpoint)
        multipart_started_at = time.monotonic()
        fields = self._server_request_fields(url, temperature, beam_size)
        if language:
            fields.append(("language", language))

        data, content_type = self._multipart_form_data(fields, "file", wav_path)
        multipart_ms = self._elapsed_ms(multipart_started_at)
        request = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": content_type},
            method="POST",
        )
        self._progress(progress_callback, 45, "Transcribing with whisper.cpp server")
        append_service_log(
            "webui",
            f"whisper inference request url={url} bytes={len(data)} language={language or ''} "
            f"beam={beam_size} temperature={temperature}",
        )
        try:
            request_started_at = time.monotonic()
            with urllib.request.urlopen(request, timeout=60 * 60) as response:
                status = getattr(response, "status", None)
                payload_bytes = response.read()
                payload = json.loads(payload_bytes.decode("utf-8"))
            whisper_http_ms = self._elapsed_ms(request_started_at)
            append_service_log(
                "webui",
                f"whisper inference response url={url} status={status} bytes={len(payload_bytes)} elapsed_ms={whisper_http_ms}",
            )
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            append_service_log("webui", f"whisper inference http_error url={url} status={exc.code} detail={detail}")
            raise RuntimeError(f"whisper.cpp server failed: {detail}") from exc
        except Exception as exc:
            append_service_log("webui", f"whisper inference error url={url} error={exc}")
            raise

        self._raise_if_cancelled(cancel_event)
        parse_started_at = time.monotonic()
        segments = self._normalize_segments(payload)
        debug = self._server_debug(url, fields, payload, len(segments))
        if not segments and payload.get("text"):
            segments = self._text_segments_without_timestamps(payload.get("text", ""))
            debug["fallback"] = "split text by line because server returned no timestamp segments"
        else:
            debug["fallback"] = None
        debug["final_segment_count"] = len(segments)
        segments = [self._convert_segment_language(segment, output_language) for segment in segments]
        for segment in segments:
            if segment_callback:
                segment_callback(segment)
        text = " ".join(segment["text"].strip() for segment in segments).strip()
        if not text:
            text = self._convert_text_language(payload.get("text", ""), output_language)
        duration = segments[-1]["end"] if segments else 0
        parse_ms = self._elapsed_ms(parse_started_at)
        append_service_log(
            "webui",
            f"whisper inference parsed url={url} raw_segments={debug['raw_segment_count']} "
            f"final_segments={len(segments)} chars={len(text)} elapsed_ms={parse_ms}",
        )
        debug["timing_ms"] = {
            "multipart": multipart_ms,
            "whisper_http": whisper_http_ms,
            "parse": parse_ms,
            "transcribe_with_server": self._elapsed_ms(total_started_at),
        }
        return {
            "text": text,
            "language": output_language or payload.get("params", {}).get("language", language or "unknown"),
            "duration": duration,
            "segments": segments,
            "debug": debug,
        }

    def _inference_url(self, endpoint: str) -> str:
        endpoint = endpoint.rstrip("/")
        if endpoint.endswith("/inference") or endpoint.endswith("/v1/audio/transcriptions"):
            return endpoint
        return endpoint + "/inference"

    def _server_request_fields(
        self,
        url: str,
        temperature: float,
        beam_size: int,
    ) -> list[tuple[str, str]]:
        if url.endswith("/v1/audio/transcriptions"):
            return [
                ("temperature", str(temperature)),
                ("response_format", "verbose_json"),
                ("timestamp_granularities[]", "segment"),
            ]
        return [
            ("temperature", str(temperature)),
            ("response_format", "verbose_json"),
            ("beam_size", str(beam_size)),
        ]

    def _server_debug(
        self,
        url: str,
        fields: list[tuple[str, str]],
        payload: Dict[str, Any],
        raw_segment_count: int,
    ) -> Dict[str, Any]:
        return {
            "url": url,
            "request_fields": {name: value for name, value in fields},
            "payload_keys": sorted(payload.keys()),
            "has_transcription": isinstance(payload.get("transcription"), list),
            "has_segments": isinstance(payload.get("segments"), list),
            "raw_segment_count": raw_segment_count,
            "text_length": len(payload.get("text", "")) if isinstance(payload.get("text"), str) else None,
        }

    def _multipart_form_data(self, fields: list[tuple[str, str]], file_field: str, file_path: str) -> tuple[bytes, str]:
        boundary = f"----AirTypeWhisper{int(time.time() * 1000)}"
        body = bytearray()
        for name, value in fields:
            body.extend(f"--{boundary}\r\n".encode("utf-8"))
            body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
            body.extend(str(value).encode("utf-8"))
            body.extend(b"\r\n")

        filename = os.path.basename(file_path)
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(
            f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'.encode("utf-8")
        )
        body.extend(b"Content-Type: audio/wav\r\n\r\n")
        with open(file_path, "rb") as file:
            body.extend(file.read())
        body.extend(b"\r\n")
        body.extend(f"--{boundary}--\r\n".encode("utf-8"))
        return bytes(body), f"multipart/form-data; boundary={boundary}"

    def _normalize_segments(self, payload: Dict[str, Any]) -> List[Dict[str, Any]]:
        raw_segments = payload.get("transcription") or payload.get("segments") or []
        normalized = []
        for index, segment in enumerate(raw_segments):
            offsets = segment.get("offsets", {})
            if offsets:
                start = self._milliseconds_to_seconds(offsets.get("from", 0))
                end = self._milliseconds_to_seconds(offsets.get("to", 0))
            else:
                start = self._to_seconds(segment.get("start", 0))
                end = self._to_seconds(segment.get("end", 0))
            normalized.append(self._segment_payload(index, start, end, segment.get("text", "")))
        return normalized

    def _text_segments_without_timestamps(self, text: str) -> List[Dict[str, Any]]:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if not lines and text.strip():
            lines = [text.strip()]
        return [
            self._segment_payload(index, None, None, line, has_timestamps=False)
            for index, line in enumerate(lines)
        ]

    def _whisper_language(self, language: Optional[str]) -> Optional[str]:
        if not language:
            return None
        return LANGUAGE_ALIASES.get(language, language)

    def _convert_segment_language(self, segment: Dict[str, Any], language: Optional[str]) -> Dict[str, Any]:
        converted_text = self._convert_text_language(segment.get("text", ""), language)
        if converted_text == segment.get("text"):
            return segment
        return {
            **segment,
            "text": converted_text,
            "text_length": len(converted_text),
        }

    def _convert_text_language(self, text: str, language: Optional[str]) -> str:
        config = OPENCC_CONFIGS.get(language or "")
        if not config or not text:
            return text
        converter = self._opencc.get(config)
        if not converter:
            converter = OpenCC(config)
            self._opencc[config] = converter
        return converter.convert(text)

    def _segment_payload(
        self,
        index: int,
        start: Optional[float],
        end: Optional[float],
        text: str,
        has_timestamps: bool = True,
    ) -> Dict[str, Any]:
        normalized_text = text.strip()
        duration = max(0, (end or 0) - (start or 0)) if has_timestamps else None
        return {
            "id": index,
            "start": start,
            "end": end,
            "duration": duration,
            "duration_text": f"{duration:.1f}s" if duration is not None else "time unavailable",
            "time": f"{self._format_time(start or 0)} -> {self._format_time(end or 0)}" if has_timestamps else "time unavailable",
            "text": normalized_text,
            "text_length": len(normalized_text),
            "has_timestamps": has_timestamps,
        }

    def _to_seconds(self, value: Any) -> float:
        try:
            number = float(value)
        except (TypeError, ValueError):
            return 0.0
        return number / 1000 if number > 10000 else number

    def _milliseconds_to_seconds(self, value: Any) -> float:
        try:
            return float(value) / 1000
        except (TypeError, ValueError):
            return 0.0

    def _format_time(self, seconds: float) -> str:
        total = max(0, int(seconds))
        hours = total // 3600
        minutes = (total % 3600) // 60
        secs = total % 60
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"

    def _progress(
        self,
        progress_callback: Optional[Callable[[int, str], None]],
        percent: int,
        message: str,
    ) -> None:
        if progress_callback:
            progress_callback(percent, message)

    def _raise_if_cancelled(
        self,
        cancel_event: Optional[threading.Event],
        process: Optional[subprocess.Popen] = None,
    ) -> None:
        if cancel_event and cancel_event.is_set():
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
            raise RuntimeError("Transcription cancelled")


transcriber = WhisperCppTranscriber()
