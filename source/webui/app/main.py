from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Any, Dict, Optional
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import os
import re
import shutil
import subprocess
import threading
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import json
import time
import tomllib

from .whisper import WhisperCppNotConfigured, transcriber

app = FastAPI(title="AirType API", description="Aircraft Cabin Configuration & Speech Recognition API")

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Get the static directory path
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
APP_DIR = os.path.dirname(os.path.abspath(__file__))


def _find_config_path() -> str:
    configured = os.getenv("AIRTYPE_CONFIG_PATH")
    if configured:
        return os.path.abspath(os.path.expanduser(configured))

    current = os.path.abspath(APP_DIR)
    while True:
        candidate = os.path.join(current, "config.toml")
        if os.path.exists(candidate):
            return candidate

        parent = os.path.dirname(current)
        if parent == current:
            return os.path.abspath(os.path.join(APP_DIR, "..", "..", "..", "config.toml"))
        current = parent


RECORDS_DIR = os.path.abspath(os.path.join(APP_DIR, "..", "records"))
TRANSCRIPT_RECORD_TYPE = "transcript"
IME_RECORD_TYPE = "ime"
SETTINGS_PATH = os.path.abspath(os.path.join(APP_DIR, "..", "settings.json"))
CONFIG_PATH = _find_config_path()
RECORD_ID_PATTERN = re.compile(r"\d{8}-\d{6}")

DEFAULT_APP_SETTINGS: Dict[str, Any] = {
    "whisper": {
        "model_dir": "",
        "model_filename": "",
        "server_bin": "",
        "endpoint": "",
        "language": "zh-tw",
        "beam": 5,
        "temperature": 0,
    },
    "llm": {
        "provider": "llama.cpp",
        "endpoint": "http://127.0.0.1:8080",
        "model": "",
        "contextLength": 8192,
        "temperature": 0.4,
        "system": "Summarize and answer questions using the transcript as the source of truth.",
    },
}

# Mount static files at /app route (must be before @app.get routes)
app.mount("/app", StaticFiles(directory=STATIC_DIR, html=True), name="app_static")

# In-memory storage for configuration
configurations = []
transcription_jobs: Dict[str, Dict[str, Any]] = {}
executor = ThreadPoolExecutor(max_workers=1)


@app.on_event("shutdown")
def shutdown_managed_processes() -> None:
    transcriber.shutdown()
    executor.shutdown(wait=False, cancel_futures=True)


class TranscribeRequest(BaseModel):
    model: Optional[str] = None
    whisper_endpoint: Optional[str] = None
    whisper_server_args: Optional[str] = None
    language: Optional[str] = None
    temperature: Optional[float] = None
    beam_size: Optional[int] = None
    response_format: Optional[str] = None
    record_type: Optional[str] = None


class UrlTranscribeRequest(TranscribeRequest):
    url: str


class RecordUpdateRequest(BaseModel):
    title: str


class LocalModelsRequest(BaseModel):
    provider: str = "llama.cpp"
    endpoint: str = "http://127.0.0.1:8080"


class LocalChatRequest(LocalModelsRequest):
    model: str
    prompt: str
    system: Optional[str] = None
    temperature: float = 0.4
    context_length: Optional[int] = None
    context: Optional[int] = None


class AppSettingsRequest(BaseModel):
    settings: Dict[str, Any]


@app.get("/api/health")
async def health_check():
    return {"status": "healthy"}


def _elapsed_ms(started_at: float) -> int:
    return round((time.monotonic() - started_at) * 1000)


def _print_timing(label: str, timing: Dict[str, Any]) -> None:
    parts = [f"{name}={value} ms" for name, value in timing.items()]
    print(f"[AirType] {label}: {', '.join(parts)}", flush=True)


@app.get("/api/settings")
async def get_app_settings():
    settings = _read_app_settings()
    whisper_settings = settings.get("whisper", {})
    # Flatten for backward compatibility
    flattened = {
        "whisperEndpoint": settings.get("whisper", {}).get("endpoint", ""),
        "whisperModel": _whisper_model_path_from_settings(whisper_settings) or "",
        "whisperLanguage": settings.get("whisper", {}).get("language", "zh-tw"),
        "whisperBeam": settings.get("whisper", {}).get("beam", 5),
        "whisperTemperature": settings.get("whisper", {}).get("temperature", 0),
        "llmProvider": settings.get("llm", {}).get("provider", "llama.cpp"),
        "llmEndpoint": settings.get("llm", {}).get("endpoint", "http://127.0.0.1:8080"),
        "llmModel": settings.get("llm", {}).get("model", ""),
        "llmContextLength": settings.get("llm", {}).get("contextLength", 8192),
        "llmTemperature": settings.get("llm", {}).get("temperature", 0.4),
        "llmSystem": settings.get("llm", {}).get("system", "")
    }
    return {"settings": flattened}


@app.put("/api/settings")
async def update_app_settings(request: AppSettingsRequest):
    # Accept both flat and nested formats from frontend
    flat = request.settings
    existing_whisper = _read_app_settings().get("whisper", {})
    if "whisper" in flat and isinstance(flat["whisper"], dict):
        # Already nested format (current frontend)
        whisper_input = flat["whisper"]
        model_dir, model_filename = _split_whisper_model_settings(
            whisper_input,
            existing_whisper,
        )
        nested = {
            "whisper": {
                "endpoint": whisper_input.get("endpoint", ""),
                "model_dir": model_dir,
                "model_filename": model_filename,
                "server_bin": whisper_input.get("server_bin", existing_whisper.get("server_bin", "")),
                "language": whisper_input.get("language", "zh-tw"),
                "beam": whisper_input.get("beam", 5),
                "temperature": whisper_input.get("temperature", 0),
            },
            "llm": {
                "provider": flat.get("llm", {}).get("provider", "llama.cpp"),
                "endpoint": flat.get("llm", {}).get("endpoint", "http://127.0.0.1:8080"),
                "model": flat.get("llm", {}).get("model", ""),
                "contextLength": flat.get("llm", {}).get("contextLength", 8192),
                "temperature": flat.get("llm", {}).get("temperature", 0.4),
                "system": flat.get("llm", {}).get("system", ""),
            },
        }
    else:
        # Legacy flat format
        model_dir, model_filename = _split_whisper_model_settings(
            {"model": flat.get("whisperModel", "")},
            existing_whisper,
        )
        nested = {
            "whisper": {
                "endpoint": flat.get("whisperEndpoint", ""),
                "model_dir": model_dir,
                "model_filename": model_filename,
                "server_bin": existing_whisper.get("server_bin", ""),
                "language": flat.get("whisperLanguage", "zh-tw"),
                "beam": flat.get("whisperBeam", 5),
                "temperature": flat.get("whisperTemperature", 0),
            },
            "llm": {
                "provider": flat.get("llmProvider", "llama.cpp"),
                "endpoint": flat.get("llmEndpoint", "http://127.0.0.1:8080"),
                "model": flat.get("llmModel", ""),
                "contextLength": flat.get("llmContextLength", 8192),
                "temperature": flat.get("llmTemperature", 0.4),
                "system": flat.get("llmSystem", "")
            }
        }
    settings = _write_app_settings(nested)
    return {"settings": nested}


@app.get("/api/configurations")
async def list_configurations():
    return {"configurations": configurations}


@app.post("/api/configurations")
async def create_configuration(name: str):
    config = {
        "id": len(configurations) + 1,
        "name": name,
        "created_at": "2026-05-31"
    }
    configurations.append(config)
    return {"configuration": config}


@app.post("/api/transcribe")
async def transcribe_audio(
    file: UploadFile = File(None),
    model: Optional[str] = Form(None),
    whisper_endpoint: Optional[str] = Form(None),
    whisper_server_args: Optional[str] = Form(None),
    language: Optional[str] = Form(None),
    temperature: Optional[float] = Form(None),
    beam_size: Optional[int] = Form(None),
    response_format: Optional[str] = Form(None),
    record_type: Optional[str] = Form(None)
):
    """
    Transcribe audio file using Whisper
    """
    endpoint_started_at = time.monotonic()
    if not file:
        raise HTTPException(status_code=400, detail="No audio file provided")

    selected_record_type = _select_direct_record_type(
        record_type,
        file.filename,
        file.content_type,
        beam_size,
        response_format,
    )

    if not _is_supported_media(file.content_type, file.filename):
        raise HTTPException(
            status_code=400,
            detail="Invalid file type. Please upload an audio or video file."
        )

    # Save uploaded file temporarily
    read_started_at = time.monotonic()
    content = await file.read()
    read_upload_ms = _elapsed_ms(read_started_at)
    write_started_at = time.monotonic()
    with tempfile.NamedTemporaryFile(delete=False, suffix=os.path.splitext(file.filename)[1]) as temp_file:
        temp_file.write(content)
        temp_path = temp_file.name
    write_temp_ms = _elapsed_ms(write_started_at)

    try:
        settings_started_at = time.monotonic()
        options = _settings_transcribe_options(
            model,
            whisper_endpoint,
            whisper_server_args,
            language,
            temperature,
            beam_size,
            response_format,
        )
        settings_ms = _elapsed_ms(settings_started_at)
        transcribe_started_at = time.monotonic()
        result = transcriber.transcribe(
            source_path=temp_path,
            **options,
        )
        transcribe_ms = _elapsed_ms(transcribe_started_at)
        timing = result.setdefault("debug", {}).setdefault("timing_ms", {})
        timing.update(
            {
                "endpoint_read_upload": read_upload_ms,
                "endpoint_write_temp": write_temp_ms,
                "endpoint_settings": settings_ms,
                "endpoint_transcriber": transcribe_ms,
                "endpoint_total": _elapsed_ms(endpoint_started_at),
            }
        )
        _print_timing("/api/transcribe timing", timing)
        _write_direct_transcription_record(
            record_type=selected_record_type,
            source_name=file.filename or "uploaded media",
            source_type=file.content_type or "unknown",
            source_bytes=content,
            request_info=_settings_request_info(
                {
                    "kind": "upload",
                    "record_type": selected_record_type,
                    "filename": file.filename or "uploaded media",
                    "content_type": file.content_type or "unknown",
                },
                options,
            ),
            result={"success": True, **result},
        )

        return {"success": True, **result}

    except WhisperCppNotConfigured as e:
        raise HTTPException(status_code=503, detail=str(e))

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {str(e)}")

    finally:
        # Clean up temp file
        if os.path.exists(temp_path):
            os.unlink(temp_path)


@app.post("/api/transcribe/ime")
async def transcribe_ime_audio(
    file: UploadFile = File(None),
    model: Optional[str] = Form(None),
    whisper_endpoint: Optional[str] = Form(None),
    whisper_server_args: Optional[str] = Form(None),
    language: Optional[str] = Form(None),
    temperature: Optional[float] = Form(None),
    beam_size: Optional[int] = Form(None),
    response_format: Optional[str] = Form(None),
):
    return await transcribe_audio(
        file=file,
        model=model,
        whisper_endpoint=whisper_endpoint,
        whisper_server_args=whisper_server_args,
        language=language,
        temperature=temperature,
        beam_size=beam_size,
        response_format=response_format,
        record_type=IME_RECORD_TYPE,
    )


@app.post("/api/transcribe/jobs")
async def create_transcription_job(
    file: UploadFile = File(None),
    model: Optional[str] = Form(None),
    whisper_endpoint: Optional[str] = Form(None),
    whisper_server_args: Optional[str] = Form(None),
    language: Optional[str] = Form(None),
    temperature: Optional[float] = Form(None),
    beam_size: Optional[int] = Form(None),
    response_format: Optional[str] = Form(None)
):
    if not file:
        raise HTTPException(status_code=400, detail="No audio or video file provided")

    if not _is_supported_media(file.content_type, file.filename):
        raise HTTPException(
            status_code=400,
            detail="Invalid file type. Please upload an audio or video file."
        )

    content = await file.read()
    options = _settings_transcribe_options(
        model,
        whisper_endpoint,
        whisper_server_args,
        language,
        temperature,
        beam_size,
        response_format,
    )

    job_id = _create_job(
        file.filename or "uploaded media",
        source_size=len(content),
        source_type=file.content_type or "unknown",
        request_info=_settings_request_info({
            "kind": "upload",
            "filename": file.filename or "uploaded media",
            "content_type": file.content_type or "unknown",
        }, options),
    )
    temp_path = os.path.join(_job_dir(job_id), f"source{os.path.splitext(file.filename or '')[1] or '.media'}")
    with open(temp_path, "wb") as temp_file:
        temp_file.write(content)
    _update_job_source(job_id, temp_path)
    transcription_jobs[job_id]["progress"] = 8
    transcription_jobs[job_id]["message"] = "Upload complete. Waiting for transcription worker"
    executor.submit(
        _run_transcription_job,
        job_id,
        temp_path,
        options,
    )
    return {"job_id": job_id, **_public_job(transcription_jobs[job_id])}


@app.post("/api/local-llm/models")
async def list_local_models(request: LocalModelsRequest):
    try:
        if request.provider == "ollama":
            payload = _http_json("GET", _join_url(request.endpoint, "/api/tags"))
            models = []
            for model in payload.get("models", []):
                name = model.get("name", "")
                if not name:
                    continue

                model_details = _ollama_model_details(request.endpoint, name)
                models.append(
                    {
                        "name": name,
                        "size": model.get("size"),
                        "modified_at": model.get("modified_at"),
                        "context_length": _model_context_length(model_details.get("model_info", {})),
                        "context_source": "ollama model metadata",
                        "configured_context_length": _configured_context_length(model_details.get("parameters")),
                    }
                )
            return {
                "models": models
            }

        if request.provider == "llama.cpp":
            return {"models": _llamacpp_models(request.endpoint)}

        payload = _http_json("GET", _join_url(request.endpoint, "/v1/models"))
        return {"models": [{"name": model.get("id", "")} for model in payload.get("data", []) if model.get("id")]}

    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Could not load local models: {str(e)}")


@app.post("/api/local-llm/chat")
async def chat_with_local_model(request: LocalChatRequest):
    try:
        if not request.model:
            raise ValueError("Model is required.")
        if not request.prompt.strip():
            raise ValueError("Prompt is required.")

        if request.provider == "ollama":
            payload = _http_json(
                "POST",
                _join_url(request.endpoint, "/api/chat"),
                {
                    "model": request.model,
                    "stream": False,
                    "messages": _llm_messages(request.system, request.prompt),
                    "options": {
                        "temperature": request.temperature,
                        "num_ctx": _request_context_length(request),
                    },
                },
            )
            return {"response": payload.get("message", {}).get("content", "")}

        payload = _http_json(
            "POST",
            _join_url(request.endpoint, "/v1/chat/completions"),
            {
                "model": request.model,
                "messages": _llm_messages(request.system, request.prompt),
                "temperature": request.temperature,
                **({"n_ctx": _request_context_length(request)} if request.provider == "llama.cpp" else {}),
            },
        )
        choices = payload.get("choices", [])
        return {"response": choices[0].get("message", {}).get("content", "") if choices else ""}

    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Local LLM request failed: {str(e)}")


@app.post("/api/transcribe/url/jobs")
async def create_url_transcription_job(request: UrlTranscribeRequest):
    parsed = urllib.parse.urlparse(request.url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="URL must start with http:// or https://")

    options = _settings_transcribe_options(
        request.model,
        request.whisper_endpoint,
        request.whisper_server_args,
        request.language,
        request.temperature,
        request.beam_size,
        request.response_format,
    )
    job_id = _create_job(
        request.url,
        source_size=None,
        source_type="remote url",
        request_info=_settings_request_info({
            "kind": "url",
            "url": request.url,
        }, options),
    )
    temp_path = os.path.join(_job_dir(job_id), f"source{os.path.splitext(parsed.path)[1] or '.media'}")
    _update_job_source(job_id, temp_path)
    executor.submit(
        _run_url_transcription_job,
        job_id,
        request.url,
        temp_path,
        options,
    )
    return {"job_id": job_id, **_public_job(transcription_jobs[job_id])}


@app.get("/api/transcribe/jobs/{job_id}")
async def get_transcription_job(job_id: str):
    job = transcription_jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Transcription job not found")
    return {"job_id": job_id, **_public_job(job)}


@app.get("/api/transcribe/records")
async def list_transcription_records(record_type: Optional[str] = None):
    return {"records": _list_transcription_records(record_type)}


@app.get("/api/transcribe/records/{job_id}")
async def get_transcription_record(job_id: str, record_type: Optional[str] = None):
    record = _read_transcription_record(job_id, record_type)
    if not record:
        raise HTTPException(status_code=404, detail="Transcript record not found")
    return {"record": record}


@app.patch("/api/transcribe/records/{job_id}")
async def update_transcription_record(job_id: str, request: RecordUpdateRequest, record_type: Optional[str] = None):
    record = _update_transcription_record(job_id, request.title, record_type)
    if not record:
        raise HTTPException(status_code=404, detail="Transcript record not found")
    return {"record": record}


@app.delete("/api/transcribe/records/{job_id}")
async def delete_transcription_record(job_id: str, record_type: Optional[str] = None):
    if not _delete_transcription_record(job_id, record_type):
        raise HTTPException(status_code=404, detail="Transcript record not found")
    return {"deleted": True}


@app.post("/api/transcribe/jobs/{job_id}/cancel")
async def cancel_transcription_job(job_id: str):
    job = transcription_jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Transcription job not found")

    if job["status"] in {"completed", "failed", "cancelled"}:
        return {"job_id": job_id, **_public_job(job)}

    job["cancel_event"].set()
    process = job.get("process")
    if process and process.poll() is None:
        process.terminate()
    _update_job(job_id, status="cancelled", progress=100, message="Stopped by user")
    return {"job_id": job_id, **_public_job(job)}


@app.post("/api/transcribe/url")
async def transcribe_from_url(request: UrlTranscribeRequest):
    parsed = urllib.parse.urlparse(request.url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="URL must start with http:// or https://")

    suffix = os.path.splitext(parsed.path)[1] or ".media"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as temp_file:
        temp_path = temp_file.name

    try:
        options = _settings_transcribe_options(
            request.model,
            request.whisper_endpoint,
            request.whisper_server_args,
            request.language,
            request.temperature,
            request.beam_size,
        )
        _download_url(request.url, temp_path)
        result = transcriber.transcribe(
            source_path=temp_path,
            **options,
        )
        return {"success": True, **result}

    except WhisperCppNotConfigured as e:
        raise HTTPException(status_code=503, detail=str(e))

    except urllib.error.URLError as e:
        raise HTTPException(status_code=400, detail=f"Could not download URL: {e}")

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {str(e)}")

    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def _is_supported_media(content_type: Optional[str], filename: Optional[str]) -> bool:
    if content_type:
        base_type = content_type.split(";")[0].lower()
        if base_type.startswith("audio/") or base_type.startswith("video/"):
            return True

    extension = os.path.splitext(filename or "")[1].lower()
    return extension in {
        ".wav", ".mp3", ".m4a", ".mp4", ".mov", ".webm", ".ogg",
        ".flac", ".aac", ".aiff", ".avi", ".mkv", ".mpeg", ".mpg"
    }


def _read_app_settings() -> Dict[str, Any]:
    settings = _read_backend_config_settings()
    if not settings:
        settings = _read_legacy_json_settings()

    merged = _normalize_app_settings({**DEFAULT_APP_SETTINGS, **settings})
    if not _has_backend_config_sections():
        _write_app_settings(merged)
    return merged


def _write_app_settings(settings: Dict[str, Any]) -> Dict[str, Any]:
    allowed = set(DEFAULT_APP_SETTINGS)
    merged = _normalize_app_settings(
        {
            **DEFAULT_APP_SETTINGS,
            **{key: value for key, value in settings.items() if key in allowed},
        }
    )
    _write_backend_config_settings(merged)
    return merged


def _read_backend_config_settings() -> Dict[str, Any]:
    if not os.path.exists(CONFIG_PATH):
        return {}

    try:
        with open(CONFIG_PATH, "rb") as config_file:
            config = tomllib.load(config_file)
    except (OSError, tomllib.TOMLDecodeError):
        return {}

    webui = config.get("webui", {})
    if not isinstance(webui, dict):
        return {}

    settings: Dict[str, Any] = {}
    for key, section_names in {
        "whisper": ("whisper-server", "whisper"),
        "llm": ("llm-server", "llm"),
    }.items():
        value = next(
            (
                webui.get(section_name)
                for section_name in section_names
                if isinstance(webui.get(section_name), dict)
            ),
            None,
        )
        if isinstance(value, dict):
            settings[key] = value
    return settings


def _read_legacy_json_settings() -> Dict[str, Any]:
    if not os.path.exists(SETTINGS_PATH):
        return {}

    try:
        with open(SETTINGS_PATH, "r", encoding="utf-8") as settings_file:
            loaded = json.loads(_strip_json_line_comments(settings_file.read()))
    except (OSError, json.JSONDecodeError):
        return {}

    return loaded if isinstance(loaded, dict) else {}


def _has_backend_config_sections() -> bool:
    settings = _read_backend_config_settings()
    return bool(settings.get("whisper") or settings.get("llm"))


def _write_backend_config_settings(settings: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
            text = config_file.read()
    except OSError:
        text = "# AirType user config\n"

    text = _remove_backend_setting_sections(text).rstrip()
    backend_text = _backend_settings_toml(settings)
    if text:
        text = f"{text}\n\n{backend_text}\n"
    else:
        text = f"{backend_text}\n"

    with open(CONFIG_PATH, "w", encoding="utf-8") as config_file:
        config_file.write(text)


def _remove_backend_setting_sections(text: str) -> str:
    pattern = re.compile(r"(?ms)^\[webui\.(?:whisper-server|llm-server|whisper|llm)\]\n.*?(?=^\[|\Z)")
    text = pattern.sub("", text)
    header_pattern = re.compile(
        r"(?m)^#=+\n# Web UI Settings\n#=+\n(?:\n|$)"
    )
    return header_pattern.sub("", text)


def _backend_settings_toml(settings: Dict[str, Any]) -> str:
    whisper = settings.get("whisper", {})
    llm = settings.get("llm", {})
    lines = [
        "#===============================================================================",
        "# Web UI Settings",
        "#===============================================================================",
        "",
        "[webui.whisper-server]",
        f"model_dir = {_toml_string(whisper.get('model_dir', ''))}",
        f"model_filename = {_toml_string(whisper.get('model_filename', ''))}",
        f"server_bin = {_toml_string(whisper.get('server_bin', ''))}",
        f"endpoint = {_toml_string(whisper.get('endpoint', ''))}",
        f"language = {_toml_string(whisper.get('language', 'zh-tw'))}",
        f"beam = {_toml_number(whisper.get('beam', 5), 5)}",
        f"temperature = {_toml_number(whisper.get('temperature', 0), 0)}",
        "",
        "[webui.llm-server]",
        f"provider = {_toml_string(llm.get('provider', 'llama.cpp'))}",
        f"endpoint = {_toml_string(llm.get('endpoint', 'http://127.0.0.1:8080'))}",
        f"model = {_toml_string(llm.get('model', ''))}",
        f"contextLength = {_toml_number(llm.get('contextLength', 8192), 8192)}",
        f"temperature = {_toml_number(llm.get('temperature', 0.4), 0.4)}",
        f"system = {_toml_string(llm.get('system', ''))}",
    ]
    return "\n".join(lines)


def _toml_string(value: Any) -> str:
    text = str(value or "")
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _toml_number(value: Any, default_value: int | float) -> str:
    try:
        number = float(value)
    except (TypeError, ValueError):
        number = float(default_value)
    if number.is_integer():
        return str(int(number))
    return f"{number:.4f}".rstrip("0").rstrip(".")


def _normalize_app_settings(settings: Dict[str, Any]) -> Dict[str, Any]:
    normalized = dict(settings)
    
    # Handle legacy flat structure
    if "whisperEndpoint" in normalized:
        legacy_model = normalized.pop("whisperModel", "")
        model_dir = ""
        model_filename = ""
        if legacy_model:
            model_path = os.path.expanduser(legacy_model)
            model_dir = os.path.dirname(model_path)
            model_filename = os.path.basename(model_path)
        normalized["whisper"] = {
            "endpoint": normalized.pop("whisperEndpoint", ""),
            "language": normalized.pop("whisperLanguage", "zh-tw"),
            "beam": normalized.pop("whisperBeam", 5),
            "temperature": normalized.pop("whisperTemperature", 0),
            "model_dir": model_dir,
            "model_filename": model_filename,
        }
    if "llmProvider" in normalized:
        normalized["llm"] = {
            "provider": normalized.pop("llmProvider", "llama.cpp"),
            "endpoint": normalized.pop("llmEndpoint", "http://127.0.0.1:8080"),
            "model": normalized.pop("llmModel", ""),
            "contextLength": normalized.pop("llmContextLength", 8192),
            "temperature": normalized.pop("llmTemperature", 0.4),
            "system": normalized.pop("llmSystem", "Summarize and answer questions using the transcript as the source of truth."),
        }
    
    # Merge with defaults
    whisper = {**DEFAULT_APP_SETTINGS["whisper"], **normalized.get("whisper", {})}
    model_dir, model_filename = _split_whisper_model_settings(whisper)
    whisper["model_dir"] = model_dir
    whisper["model_filename"] = model_filename
    whisper.pop("model", None)
    whisper.pop("model_path", None)
    llm = {**DEFAULT_APP_SETTINGS["llm"], **normalized.get("llm", {})}
    
    return {
        "whisper": whisper,
        "llm": llm,
    }


def _strip_json_line_comments(text: str) -> str:
    result: list[str] = []
    in_string = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        next_char = text[index + 1] if index + 1 < len(text) else ""
        if escaped:
            result.append(char)
            escaped = False
        elif char == "\\" and in_string:
            result.append(char)
            escaped = True
        elif char == '"':
            result.append(char)
            in_string = not in_string
        elif char == "/" and next_char == "/" and not in_string:
            while index < len(text) and text[index] not in "\r\n":
                index += 1
            continue
        else:
            result.append(char)
        index += 1
    return "".join(result)


def _whisper_model_path_from_settings(whisper_settings: Dict[str, Any]) -> Optional[str]:
    model_dir = whisper_settings.get("model_dir")
    model_filename = whisper_settings.get("model_filename")
    if (
        isinstance(model_dir, str)
        and model_dir.strip()
        and isinstance(model_filename, str)
        and model_filename.strip()
    ):
        return os.path.join(os.path.expanduser(model_dir.strip()), model_filename.strip())

    legacy_model = whisper_settings.get("model") or whisper_settings.get("model_path")
    if isinstance(legacy_model, str) and legacy_model.strip():
        return os.path.expanduser(legacy_model.strip())
    return None


def _split_whisper_model_settings(
    whisper_settings: Dict[str, Any],
    fallback_settings: Optional[Dict[str, Any]] = None,
) -> tuple[str, str]:
    model_dir = whisper_settings.get("model_dir")
    model_filename = whisper_settings.get("model_filename")
    if (
        isinstance(model_dir, str)
        and model_dir.strip()
        and isinstance(model_filename, str)
        and model_filename.strip()
    ):
        return os.path.expanduser(model_dir.strip()), model_filename.strip()

    legacy_model = whisper_settings.get("model") or whisper_settings.get("model_path")
    if isinstance(legacy_model, str) and legacy_model.strip():
        model_path = os.path.expanduser(legacy_model.strip())
        return os.path.dirname(model_path), os.path.basename(model_path)

    if fallback_settings:
        return _split_whisper_model_settings(fallback_settings)

    return "", ""


def _settings_transcribe_options(
    model: Optional[str],
    whisper_endpoint: Optional[str],
    whisper_server_args: Optional[str],
    language: Optional[str],
    temperature: Optional[float],
    beam_size: Optional[int],
    response_format: Optional[str] = None,
) -> Dict[str, Any]:
    settings = _read_app_settings()
    whisper_settings = settings.get("whisper", {})
    selected_model = model or _whisper_model_path_from_settings(whisper_settings)
    
    endpoint = whisper_endpoint if whisper_endpoint is not None else whisper_settings.get("endpoint", "")
    if not (endpoint or "").strip():
        endpoint = ""

    return {
        "model_path": selected_model,
        "server_endpoint": endpoint,
        "server_args": whisper_server_args if whisper_server_args is not None else "",
        "language": language or whisper_settings.get("language") or None,
        "temperature": temperature if temperature is not None else whisper_settings.get("temperature", 0),
        "beam_size": beam_size if beam_size is not None else whisper_settings.get("beam", 5),
        "response_format": response_format,
    }


def _settings_request_info(request_info: Dict[str, Any], options: Dict[str, Any]) -> Dict[str, Any]:
    return {
        **request_info,
        "model": options.get("model_path"),
        "whisper_endpoint": options.get("server_endpoint"),
        "whisper_server_args": options.get("server_args"),
        "language": options.get("language"),
        "temperature": options.get("temperature"),
        "beam_size": options.get("beam_size"),
        "response_format": options.get("response_format"),
    }


def _download_url(url: str, destination: str, max_bytes: int = 2 * 1024 * 1024 * 1024) -> Dict[str, Any]:
    if _should_use_media_downloader(url):
        metadata = _download_media_page(url, destination)
        if os.path.getsize(destination) > max_bytes:
            raise ValueError("Remote file is larger than 2GB.")
        return metadata

    request = urllib.request.Request(url, headers={"User-Agent": "AirType/1.0"})
    downloaded = 0
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content_type = response.headers.get("Content-Type", "")
            if content_type and not _is_supported_media(content_type, urllib.parse.urlparse(url).path):
                return _download_media_page(url, destination)

            with open(destination, "wb") as output:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    downloaded += len(chunk)
                    if downloaded > max_bytes:
                        raise ValueError("Remote file is larger than 2GB.")
                    output.write(chunk)
            return {
                "download_method": "direct",
                "title": _title_from_url_response(url, response.headers),
                "content_type": content_type or None,
                "url": url,
            }
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError):
        if os.path.exists(destination):
            os.unlink(destination)
        return _download_media_page(url, destination)


def _should_use_media_downloader(url: str) -> bool:
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc.lower()
    path = parsed.path.lower()
    return any(
        domain in host
        for domain in (
            "youtube.com",
            "youtu.be",
            "instagram.com",
            "threads.net",
            "tiktok.com",
            "bilibili.com",
            "b23.tv",
        )
    ) or "/shorts/" in path


def _download_media_page(url: str, destination: str) -> Dict[str, Any]:
    downloader = shutil.which("yt-dlp")
    if not downloader:
        raise RuntimeError("yt-dlp is required to download YouTube, Bilibili, Instagram, Threads, TikTok, or Shorts URLs.")

    with tempfile.TemporaryDirectory(prefix="airtype-url-media-") as work_dir:
        output_template = os.path.join(work_dir, "source.%(ext)s")
        command = [
            downloader,
            "--no-playlist",
            "--max-filesize",
            "2G",
            "--write-info-json",
            "-f",
            "bestaudio/best",
            "-o",
            output_template,
        ]
        command.extend(_media_downloader_site_args(url))
        command.append(url)
        process = subprocess.run(command, capture_output=True, text=True, timeout=60 * 30)
        if process.returncode != 0:
            detail = (process.stderr or process.stdout).strip()
            raise RuntimeError(f"Could not download media URL with yt-dlp: {detail}")

        downloaded_files = [
            os.path.join(work_dir, name)
            for name in os.listdir(work_dir)
            if os.path.isfile(os.path.join(work_dir, name))
            and not name.endswith(".info.json")
        ]
        if not downloaded_files:
            raise RuntimeError("yt-dlp did not produce a media file.")

        media_path = max(downloaded_files, key=os.path.getsize)
        metadata = _yt_dlp_metadata(work_dir)
        shutil.move(media_path, destination)
        return {
            "download_method": "yt-dlp",
            **metadata,
            "url": url,
        }


def _media_downloader_site_args(url: str) -> list[str]:
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc.lower()
    if "bilibili.com" in host or "b23.tv" in host:
        return [
            "--referer",
            "https://www.bilibili.com/",
            "--user-agent",
            (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/125.0.0.0 Safari/537.36"
            ),
        ]
    return []


def _title_from_url_response(url: str, headers: Any) -> str:
    disposition = headers.get("Content-Disposition", "")
    filename_match = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', disposition, re.IGNORECASE)
    if filename_match:
        return urllib.parse.unquote(filename_match.group(1)).strip()

    parsed = urllib.parse.urlparse(url)
    basename = os.path.basename(parsed.path.rstrip("/"))
    return urllib.parse.unquote(basename) or parsed.netloc


def _yt_dlp_metadata(work_dir: str) -> Dict[str, Any]:
    info_paths = [
        os.path.join(work_dir, name)
        for name in os.listdir(work_dir)
        if name.endswith(".info.json") and os.path.isfile(os.path.join(work_dir, name))
    ]
    if not info_paths:
        return {}

    try:
        with open(max(info_paths, key=os.path.getmtime), "r", encoding="utf-8") as info_file:
            info = json.load(info_file)
    except (OSError, json.JSONDecodeError):
        return {}

    return {
        key: info.get(key)
        for key in (
            "id",
            "title",
            "fulltitle",
            "description",
            "duration",
            "uploader",
            "channel",
            "webpage_url",
            "original_url",
            "extractor",
            "extractor_key",
            "upload_date",
            "timestamp",
        )
        if info.get(key) is not None
    }


def _join_url(endpoint: str, path: str) -> str:
    return endpoint.rstrip("/") + path


def _http_json(method: str, url: str, payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read().decode("utf-8"))


def _llm_messages(system: Optional[str], prompt: str) -> list[Dict[str, str]]:
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    return messages


def _request_context_length(request: LocalChatRequest) -> int:
    return request.context_length or request.context or 8192


def _ollama_model_details(endpoint: str, model: str) -> Dict[str, Any]:
    try:
        return _http_json("POST", _join_url(endpoint, "/api/show"), {"model": model})
    except Exception:
        return {}


def _llamacpp_models(endpoint: str) -> list[Dict[str, Any]]:
    payload = _llamacpp_models_payload(endpoint)
    props = {}
    if payload is None:
        props = _llamacpp_props(endpoint)
        if not props:
            raise ValueError("Could not read llama.cpp /models or /props.")
        payload = {"data": []}

    models = []
    for item in payload.get("data", []):
        name = item.get("id", "")
        if not name:
            continue

        props = _llamacpp_props(endpoint, name)
        models.append(
            {
                "name": name,
                "path": item.get("path") or props.get("model_path"),
                "status": item.get("status", {}).get("value") if isinstance(item.get("status"), dict) else item.get("status"),
                "context_length": _llamacpp_context_length(props) or _model_context_length(props),
                "context_source": "llama.cpp runtime n_ctx",
            }
        )

    if models:
        return models

    props = props or _llamacpp_props(endpoint)
    if not props:
        return []

    model_name = os.path.basename(props.get("model_path", "")) or "loaded-model"
    return [
        {
            "name": model_name,
            "path": props.get("model_path"),
            "status": "loaded",
            "context_length": _llamacpp_context_length(props) or _model_context_length(props),
            "context_source": "llama.cpp runtime n_ctx",
        }
    ]


def _llamacpp_models_payload(endpoint: str) -> Optional[Dict[str, Any]]:
    for path in ("/models?reload=1", "/models", "/v1/models"):
        try:
            return _http_json("GET", _join_url(endpoint, path))
        except Exception:
            continue
    return None


def _llamacpp_props(endpoint: str, model: Optional[str] = None) -> Dict[str, Any]:
    paths = ["/props"]
    if model:
        quoted_model = urllib.parse.quote(model, safe="")
        paths.insert(0, f"/props?model={quoted_model}&autoload=false")

    for path in paths:
        try:
            return _http_json("GET", _join_url(endpoint, path))
        except Exception:
            continue
    return {}


def _llamacpp_context_length(props: Dict[str, Any]) -> Optional[int]:
    default_generation_settings = props.get("default_generation_settings", {})
    for value in (
        default_generation_settings.get("n_ctx"),
        props.get("n_ctx"),
    ):
        try:
            if value:
                return int(value)
        except (TypeError, ValueError):
            continue
    return None


def _model_context_length(model_info: Dict[str, Any]) -> Optional[int]:
    for key, value in model_info.items():
        if key.endswith(".context_length") or key == "context_length":
            try:
                return int(value)
            except (TypeError, ValueError):
                return None
    return None


def _configured_context_length(parameters: Optional[str]) -> Optional[int]:
    if not parameters:
        return None

    for line in parameters.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "num_ctx":
            try:
                return int(parts[1])
            except ValueError:
                return None
    return None


def _create_job(
    source_name: str,
    source_size: Optional[int],
    source_type: str,
    request_info: Optional[Dict[str, Any]] = None,
    record_type: str = TRANSCRIPT_RECORD_TYPE,
) -> str:
    record_type = _normalize_record_type(record_type)
    job_id = _new_record_id(record_type)
    os.makedirs(_job_dir(job_id, record_type), exist_ok=True)
    transcription_jobs[job_id] = {
        "job_id": job_id,
        "record_type": record_type,
        "status": "queued",
        "progress": 1,
        "message": "Queued",
        "source_name": source_name,
        "source_size": source_size,
        "source_type": source_type,
        "source_metadata": None,
        "request": request_info or {},
        "job_dir": _job_dir(job_id, record_type),
        "source_path": None,
        "partial_segments": [],
        "result": None,
        "error": None,
        "cancel_event": threading.Event(),
        "process": None,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    _write_job_record(job_id)
    return job_id


def _public_job(job: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "status": job["status"],
        "progress": job["progress"],
        "message": job["message"],
        "source_name": job["source_name"],
        "source_size": job["source_size"],
        "source_type": job["source_type"],
        "source_metadata": job.get("source_metadata"),
        "partial_segments": job["partial_segments"],
        "result": job["result"],
        "error": job["error"],
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
    }


def _update_job(job_id: str, **updates: Any) -> None:
    job = transcription_jobs[job_id]
    job.update(updates)
    job["updated_at"] = datetime.now(timezone.utc).isoformat()
    _write_job_record(job_id)


def _update_job_source(job_id: str, source_path: str) -> None:
    size = os.path.getsize(source_path) if os.path.exists(source_path) else None
    _update_job(
        job_id,
        source_path=source_path,
        source_size=size if size is not None else transcription_jobs[job_id]["source_size"],
    )


def _normalize_record_type(record_type: Optional[str]) -> str:
    if (record_type or "").strip().lower() == IME_RECORD_TYPE:
        return IME_RECORD_TYPE
    return TRANSCRIPT_RECORD_TYPE


def _select_direct_record_type(
    record_type: Optional[str],
    filename: Optional[str],
    content_type: Optional[str],
    beam_size: Optional[int],
    response_format: Optional[str],
) -> str:
    if record_type:
        return _normalize_record_type(record_type)

    # The floating IME client sends short microphone captures as recording.wav
    # with the low-latency ASR options. This keeps older clients separated even
    # if they still post to /api/transcribe without record_type=ime.
    if (
        (filename or "").strip().lower() == "recording.wav"
        and (content_type or "").strip().lower().startswith("audio/")
        and beam_size == 1
        and (response_format or "").strip().lower() == "json"
    ):
        return IME_RECORD_TYPE

    return TRANSCRIPT_RECORD_TYPE


def _new_record_id(record_type: Optional[str]) -> str:
    while True:
        record_id = datetime.now().strftime("%Y%m%d-%H%M%S")
        if not os.path.exists(_job_dir(record_id, record_type)):
            return record_id
        time.sleep(0.2)


def _is_valid_record_id(record_id: str) -> bool:
    return bool(RECORD_ID_PATTERN.fullmatch(record_id))


def _record_type_dir(record_type: Optional[str]) -> str:
    return os.path.join(RECORDS_DIR, _normalize_record_type(record_type))


def _job_record_type(job_id: str) -> str:
    job = transcription_jobs.get(job_id)
    if job:
        return _normalize_record_type(job.get("record_type"))
    for record_type in (TRANSCRIPT_RECORD_TYPE, IME_RECORD_TYPE):
        if os.path.exists(os.path.join(_record_type_dir(record_type), job_id, "record.json")):
            return record_type
    return TRANSCRIPT_RECORD_TYPE


def _job_dir(job_id: str, record_type: Optional[str] = None) -> str:
    selected_record_type = _normalize_record_type(record_type) if record_type else _job_record_type(job_id)
    if record_type is None:
        candidate = os.path.join(_record_type_dir(selected_record_type), job_id)
        if os.path.exists(candidate):
            return candidate
    return os.path.join(_record_type_dir(selected_record_type), job_id)


def _record_path(job_id: str, record_type: Optional[str] = None) -> str:
    return os.path.join(_job_dir(job_id, record_type), "record.json")


def _write_job_record(job_id: str) -> None:
    job = transcription_jobs.get(job_id)
    if not job:
        return
    os.makedirs(_job_dir(job_id), exist_ok=True)
    with open(_record_path(job_id), "w", encoding="utf-8") as record_file:
        json.dump(_record_data(job_id, job), record_file, ensure_ascii=False, indent=2)


def _write_direct_transcription_record(
    record_type: str,
    source_name: str,
    source_type: str,
    source_bytes: bytes,
    request_info: Dict[str, Any],
    result: Dict[str, Any],
) -> str:
    record_type = _normalize_record_type(record_type)
    job_id = _new_record_id(record_type)
    job_dir = _job_dir(job_id, record_type)
    os.makedirs(job_dir, exist_ok=True)

    source_ext = os.path.splitext(source_name)[1] or ".media"
    source_path = os.path.join(job_dir, f"source{source_ext}")
    with open(source_path, "wb") as source_file:
        source_file.write(source_bytes)

    now = datetime.now(timezone.utc).isoformat()
    record = _record_data(
        job_id,
        {
            "job_id": job_id,
            "record_type": record_type,
            "status": "completed",
            "progress": 100,
            "message": "Transcript ready",
            "source_name": source_name,
            "source_size": len(source_bytes),
            "source_type": source_type,
            "source_metadata": None,
            "request": request_info,
            "source_path": source_path,
            "result": result,
            "error": None,
            "created_at": now,
            "updated_at": now,
        },
    )
    with open(_record_path(job_id, record_type), "w", encoding="utf-8") as record_file:
        json.dump(record, record_file, ensure_ascii=False, indent=2)
    return job_id


def _record_data(job_id: str, job: Dict[str, Any]) -> Dict[str, Any]:
    result = job.get("result") or {}
    segments = result.get("segments") or []
    source_path = job.get("source_path")
    record_type = _normalize_record_type(job.get("record_type"))
    job_dir = _job_dir(job_id, record_type)
    return {
        "job_id": job_id,
        "record_type": record_type,
        "title": _record_title(job),
        "status": job.get("status"),
        "progress": job.get("progress"),
        "message": job.get("message"),
        "source": {
            "name": job.get("source_name"),
            "type": job.get("source_type"),
            "size": job.get("source_size"),
            "path": source_path,
            "relative_path": os.path.relpath(source_path, job_dir) if source_path else None,
            "metadata": job.get("source_metadata"),
        },
        "request": job.get("request") or {},
        "result": {
            "language": result.get("language"),
            "duration": result.get("duration"),
            "segment_count": len(segments),
            "text_length": len(result.get("text", "") or ""),
            "debug": result.get("debug"),
        } if result else None,
        "transcript": {
            "success": result.get("success", True),
            "text": result.get("text", ""),
            "language": result.get("language"),
            "duration": result.get("duration"),
            "segments": segments,
            "debug": result.get("debug"),
        } if result else None,
        "whisper_server_debug": result.get("debug") if result else None,
        "error": job.get("error"),
        "created_at": job.get("created_at"),
        "updated_at": job.get("updated_at"),
    }


def _record_title(job: Dict[str, Any]) -> str:
    if job.get("title"):
        return job["title"]
    metadata_title = _metadata_title(job.get("source_metadata"))
    if metadata_title:
        return metadata_title
    source_name = job.get("source_name") or "Untitled transcript"
    parsed = urllib.parse.urlparse(source_name)
    if parsed.scheme and parsed.netloc:
        return parsed.path.rstrip("/").split("/")[-1] or parsed.netloc
    return os.path.basename(source_name) or source_name


def _metadata_title(metadata: Optional[Dict[str, Any]]) -> Optional[str]:
    if not metadata:
        return None

    for key in ("title", "fulltitle"):
        value = metadata.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _list_transcription_records(record_type: Optional[str] = None) -> list[Dict[str, Any]]:
    record_dir = _record_type_dir(record_type or TRANSCRIPT_RECORD_TYPE)
    if not os.path.isdir(record_dir):
        return []

    records = []
    for name in os.listdir(record_dir):
        path = os.path.join(record_dir, name, "record.json")
        if not os.path.exists(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as record_file:
                records.append(_record_summary(json.load(record_file)))
        except (OSError, json.JSONDecodeError):
            continue
    records.sort(key=lambda record: record.get("updated_at") or "", reverse=True)
    return records


def _read_transcription_record(job_id: str, record_type: Optional[str] = None) -> Optional[Dict[str, Any]]:
    if not _is_valid_record_id(job_id):
        return None

    path = _record_path(job_id, record_type)
    if not os.path.exists(path):
        return None

    try:
        with open(path, "r", encoding="utf-8") as record_file:
            return json.load(record_file)
    except (OSError, json.JSONDecodeError):
        return None


def _update_transcription_record(job_id: str, title: str, record_type: Optional[str] = None) -> Optional[Dict[str, Any]]:
    clean_title = title.strip()
    if not clean_title:
        raise HTTPException(status_code=400, detail="Title cannot be empty")

    record = _read_transcription_record(job_id, record_type)
    if not record:
        return None

    record["title"] = clean_title
    record["updated_at"] = datetime.now(timezone.utc).isoformat()
    os.makedirs(_job_dir(job_id, record_type), exist_ok=True)
    with open(_record_path(job_id, record_type), "w", encoding="utf-8") as record_file:
        json.dump(record, record_file, ensure_ascii=False, indent=2)

    if job_id in transcription_jobs:
        transcription_jobs[job_id]["title"] = clean_title
        transcription_jobs[job_id]["updated_at"] = record["updated_at"]
    return record


def _delete_transcription_record(job_id: str, record_type: Optional[str] = None) -> bool:
    if not _is_valid_record_id(job_id):
        return False

    job_dir = _job_dir(job_id, record_type)
    if not os.path.isdir(job_dir):
        return False

    shutil.rmtree(job_dir)
    transcription_jobs.pop(job_id, None)
    return True


def _record_summary(record: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "job_id": record.get("job_id"),
        "record_type": record.get("record_type"),
        "title": record.get("title"),
        "status": record.get("status"),
        "source": record.get("source"),
        "result": record.get("result"),
        "whisper_server_debug": record.get("whisper_server_debug"),
        "error": record.get("error"),
        "created_at": record.get("created_at"),
        "updated_at": record.get("updated_at"),
    }


def _run_url_transcription_job(
    job_id: str,
    url: str,
    temp_path: str,
    options: Dict[str, Any],
) -> None:
    try:
        if _is_job_cancelled(job_id):
            return
        _update_job(job_id, status="downloading", progress=5, message="Downloading source URL")
        metadata = _download_url(url, temp_path)
        metadata_title = _metadata_title(metadata)
        if metadata_title:
            _update_job(
                job_id,
                title=metadata_title,
                source_name=metadata_title,
                source_metadata=metadata,
            )
        elif metadata:
            _update_job(job_id, source_metadata=metadata)
        _update_job_source(job_id, temp_path)
        _run_transcription_job(job_id, temp_path, options)
    except Exception as e:
        if _is_job_cancelled(job_id):
            _update_job(job_id, status="cancelled", progress=100, message="Stopped by user")
        else:
            _update_job(job_id, status="failed", progress=100, message="Failed", error=str(e))


def _run_transcription_job(job_id: str, source_path: str, options: Dict[str, Any]) -> None:
    try:
        if _is_job_cancelled(job_id):
            return
        _update_job(job_id, status="running", progress=10, message="Starting transcription worker")

        def on_progress(progress: int, message: str) -> None:
            if _is_job_cancelled(job_id):
                return
            _update_job(job_id, status="running", progress=progress, message=message)

        def on_process(process: Any) -> None:
            _update_job(job_id, process=process)

        def on_segment(segment: Dict[str, Any]) -> None:
            job = transcription_jobs[job_id]
            job["partial_segments"].append(segment)
            _update_job(
                job_id,
                status="running",
                progress=max(job["progress"], min(90, 45 + len(job["partial_segments"]) * 4)),
                message=f"Transcribing segment {len(job['partial_segments'])}",
            )

        result = transcriber.transcribe(
            source_path=source_path,
            progress_callback=on_progress,
            cancel_event=transcription_jobs[job_id]["cancel_event"],
            process_callback=on_process,
            segment_callback=on_segment,
            **options,
        )
        if _is_job_cancelled(job_id):
            return
        _update_job(
            job_id,
            status="completed",
            progress=100,
            message="Transcript ready",
            result={"success": True, **result},
        )

    except Exception as e:
        if "cancelled" in str(e).lower() or _is_job_cancelled(job_id):
            _update_job(job_id, status="cancelled", progress=100, message="Stopped by user")
        else:
            _update_job(job_id, status="failed", progress=100, message="Failed", error=str(e))

    finally:
        if job_id in transcription_jobs:
            _update_job(job_id, process=None)
        if os.path.exists(source_path) and not _is_job_stored_source(job_id, source_path):
            os.unlink(source_path)


def _is_job_stored_source(job_id: str, source_path: str) -> bool:
    try:
        return os.path.commonpath([os.path.abspath(source_path), _job_dir(job_id)]) == _job_dir(job_id)
    except ValueError:
        return False


def _is_job_cancelled(job_id: str) -> bool:
    job = transcription_jobs.get(job_id)
    return bool(job and job["cancel_event"].is_set())


# Root endpoint
@app.get("/")
async def root():
    return {
        "name": "AirType API",
        "version": "1.0.0",
        "status": "running"
    }


# Fallback for any other routes - serve index.html
@app.get("/{full_path:path}")
async def serve_app(full_path: str):
    """Serve the web application for any unknown routes"""
    index_path = os.path.join(STATIC_DIR, "index.html")

    if os.path.exists(index_path):
        return FileResponse(index_path)

    return {"error": "Application not found."}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("app.main:app", host="0.0.0.0", port=8000, reload=True)
