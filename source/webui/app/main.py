from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Any, Callable, Dict, Optional
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
import functools
import base64
import os
import re
import mimetypes
import secrets
import shutil
import subprocess
import sys
import threading
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
import json
import time

from .service_log import append_service_log, install_webui_logging

install_webui_logging()

from .config_schema import (
    DEFAULT_APP_SETTINGS,
    ensure_config_exists,
    normalize_app_settings,
    read_config,
    read_webui_data_dir,
    read_webui_settings,
    remove_webui_sections,
    render_webui_settings_toml,
    split_whisper_model_settings,
    whisper_model_path_from_settings,
)
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
    config_path = ensure_config_exists(
        Path("~/.airtype/config.toml"),
        generator_name="webui startup",
    )
    return str(config_path)


TRANSCRIPT_RECORD_TYPE = "transcript"
IME_RECORD_TYPE = "ime"
CONFIG_PATH = _find_config_path()
WEBUI_DATA_DIR = read_webui_data_dir(CONFIG_PATH)
RECORDS_DIR = os.path.join(WEBUI_DATA_DIR, "records")
RECORD_ID_PATTERN = re.compile(r"\d{8}-\d{6}")


def _webui_auth_settings() -> Dict[str, Any]:
    settings = read_webui_settings(CONFIG_PATH)
    auth = settings.get("auth", {}) if isinstance(settings.get("auth"), dict) else {}
    return auth


def _webui_auth_enabled(auth: Dict[str, Any]) -> bool:
    return bool(auth.get("enabled")) and bool(str(auth.get("username") or "")) and bool(str(auth.get("password") or ""))


def _unauthorized_response(request: Request) -> JSONResponse:
    headers = {"WWW-Authenticate": 'Basic realm="AirType"'}
    if request.url.path.startswith("/api/"):
        return JSONResponse({"detail": "Authentication required"}, status_code=401, headers=headers)
    return JSONResponse({"detail": "Authentication required"}, status_code=401, headers=headers)


def _basic_auth_ok(authorization: str, auth: Dict[str, Any]) -> bool:
    prefix = "Basic "
    if not authorization.startswith(prefix):
        return False
    try:
        decoded = base64.b64decode(authorization[len(prefix):], validate=True).decode("utf-8")
    except Exception:
        return False
    username, separator, password = decoded.partition(":")
    if not separator:
        return False
    return secrets.compare_digest(username, str(auth.get("username") or "")) and secrets.compare_digest(
        password,
        str(auth.get("password") or ""),
    )


@app.middleware("http")
async def require_webui_basic_auth(request: Request, call_next: Callable):
    if request.method == "OPTIONS" or request.url.path == "/api/health":
        return await call_next(request)
    auth = _webui_auth_settings()
    if not _webui_auth_enabled(auth):
        return await call_next(request)
    if _basic_auth_ok(request.headers.get("authorization", ""), auth):
        return await call_next(request)
    return _unauthorized_response(request)


# Mount static files at /app route (must be before @app.get routes)
app.mount("/app", StaticFiles(directory=STATIC_DIR, html=True), name="app_static")

# In-memory storage for configuration
configurations = []
transcription_jobs: Dict[str, Dict[str, Any]] = {}
executor = ThreadPoolExecutor(max_workers=1)


@app.on_event("startup")
def startup_managed_processes() -> None:
    """Start the managed whisper.cpp server on WebUI startup if local mode is configured."""
    settings = _read_app_settings()
    raw_config = read_config(CONFIG_PATH)
    raw_webui = raw_config.get("webui", {}) if isinstance(raw_config, dict) else {}
    raw_whisper = raw_webui.get("whisper-server", {}) if isinstance(raw_webui, dict) else {}
    whisper_settings = settings.get("whisper", {})
    llm = settings.get("llm", {})
    llm_servers = settings.get("llm_servers", [])
    append_service_log(
        "webui",
        f"loaded config path={CONFIG_PATH} data_dir={WEBUI_DATA_DIR} records_dir={RECORDS_DIR}",
    )
    if isinstance(raw_whisper, dict) and "endpoint" in raw_whisper:
        append_service_log(
            "webui",
            "config webui.whisper-server contains legacy key endpoint; ignored. Use remote_endpoint instead.",
        )
    append_service_log(
        "webui",
        "config webui.whisper-server: "
        f"model_dir={whisper_settings.get('model_dir', '')} "
        f"model_filename={whisper_settings.get('model_filename', '')} "
        f"server_bin={whisper_settings.get('server_bin', '')} "
        f"remote_endpoint={whisper_settings.get('remote_endpoint', '')} "
        f"server_args={whisper_settings.get('server_args', '')} "
        f"language={whisper_settings.get('language', '')} "
        f"beam={whisper_settings.get('beam', '')} "
        f"temperature={whisper_settings.get('temperature', '')}",
    )
    append_service_log(
        "webui",
        "config webui.llm-server: "
        f"default={settings.get('default_llm_server_name', '')} "
        f"active_name={llm.get('name', '')} "
        f"provider={llm.get('provider', '')} "
        f"endpoint={llm.get('endpoint', '')} "
        f"selected_model={llm.get('selected_model') or llm.get('model', '')} "
        f"server_count={len(llm_servers) if isinstance(llm_servers, list) else 0}",
    )
    append_service_log("webui", "startup checking managed whisper-server")

    # Only start local server if no remote endpoint is configured
    remote_endpoint = str(whisper_settings.get("remote_endpoint", "")).strip()
    if remote_endpoint:
        append_service_log(
            "webui",
            f"decision: use remote whisper-server endpoint={remote_endpoint}; skip managed local whisper-server",
        )
        return

    # Check if we have model and server binary configured
    model_path = _whisper_model_path_from_settings(whisper_settings)
    append_service_log("webui", f"resolved whisper model path={model_path or 'not configured'}")
    if not model_path:
        append_service_log(
            "webui",
            "decision: skip managed local whisper-server because model_dir/model_filename are not configured",
        )
        return

    configured_server_bin = str(whisper_settings.get("server_bin", "")).strip()
    server_bin = os.path.expanduser(configured_server_bin) if configured_server_bin else transcriber.server_binary
    append_service_log(
        "webui",
        f"resolved whisper-server binary={server_bin or 'not configured'} source={'config' if configured_server_bin else 'PATH'}",
    )
    if not server_bin or not os.path.exists(server_bin):
        append_service_log(
            "webui",
            f"decision: skip managed local whisper-server because server_bin was not found ({server_bin or 'not configured'})",
        )
        return

    if not os.path.exists(model_path):
        append_service_log(
            "webui",
            f"decision: skip managed local whisper-server because model was not found ({model_path})",
        )
        return

    # Start the local whisper server
    try:
        server_args = str(whisper_settings.get("server_args", ""))
        append_service_log(
            "webui",
            f"decision: start managed local whisper-server model={model_path} server_bin={server_bin} args={server_args}",
        )
        transcriber._ensure_local_server(model_path, server_args, None)
        status = transcriber.status()
        print(f"[AirType] Local whisper-server started at {status['endpoint']}", flush=True)
    except Exception as e:
        # Log but don't fail startup
        print(f"[AirType] Could not start local whisper-server: {e}", flush=True)


@app.on_event("shutdown")
def shutdown_managed_processes() -> None:
    transcriber.shutdown()
    executor.shutdown(wait=False, cancel_futures=True)


class TranscribeRequest(BaseModel):
    model: Optional[str] = None
    whisper_endpoint: Optional[str] = None
    language: Optional[str] = None
    temperature: Optional[float] = None
    beam_size: Optional[int] = None
    record_type: Optional[str] = None


class UrlTranscribeRequest(TranscribeRequest):
    url: str


class RecordUpdateRequest(BaseModel):
    title: str


class ArticleRequest(BaseModel):
    force: bool = False


class LocalModelsRequest(BaseModel):
    provider: str = "llama.cpp"
    endpoint: str = "http://127.0.0.1:8080"
    api_key: Optional[str] = None


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
    return JSONResponse(
        {"settings": _read_app_settings()},
        headers={"Cache-Control": "no-store"},
    )


@app.put("/api/settings")
async def update_app_settings(request: AppSettingsRequest):
    settings = _write_app_settings(_settings_request_to_nested(request.settings))
    return {"settings": settings}


def _settings_request_to_nested(incoming: Dict[str, Any]) -> Dict[str, Any]:
    whisper_input = incoming.get("whisper", {}) if isinstance(incoming.get("whisper"), dict) else {}
    llm_input = incoming.get("llm", {}) if isinstance(incoming.get("llm"), dict) else {}
    ytdlp_input = incoming.get("ytdlp", {}) if isinstance(incoming.get("ytdlp"), dict) else {}
    auth_input = incoming.get("auth", {}) if isinstance(incoming.get("auth"), dict) else {}
    current_settings = _read_backend_config_settings()
    current_whisper = current_settings.get("whisper", {})
    current_whisper = current_whisper if isinstance(current_whisper, dict) else {}
    current_ytdlp = current_settings.get("ytdlp", {})
    current_ytdlp = current_ytdlp if isinstance(current_ytdlp, dict) else {}
    current_auth = current_settings.get("auth", {})
    current_auth = current_auth if isinstance(current_auth, dict) else {}
    model_dir, model_filename = _split_whisper_model_settings(whisper_input)
    return {
        "whisper": {
            "remote_endpoint": whisper_input.get("remote_endpoint", ""),
            "model_dir": model_dir,
            "model_filename": model_filename,
            "server_bin": whisper_input.get("server_bin", ""),
            "language": whisper_input.get("language", "zh-tw"),
            "server_args": whisper_input.get("server_args", current_whisper.get("server_args", "")),
            "beam": current_whisper.get("beam", 5),
            "temperature": current_whisper.get("temperature", 0),
        },
        "llm": {
            "name": llm_input.get("name", "default"),
            "provider": llm_input.get("provider", "llama.cpp"),
            "endpoint": llm_input.get("endpoint", "http://127.0.0.1:8080"),
            "api_key": llm_input.get("api_key") or llm_input.get("api-key") or "",
            "model": llm_input.get("model", ""),
            "models": llm_input.get("models", []),
            "selected_model": llm_input.get("selected_model") or llm_input.get("selected-model") or llm_input.get("model", ""),
            "contextLength": llm_input.get("contextLength", 8192),
            "temperature": llm_input.get("temperature", 0.4),
            "system": llm_input.get("system", ""),
        },
        "ytdlp": {
            "cookies": ytdlp_input.get("cookies", current_ytdlp.get("cookies", "")),
            "cookies_from_browser": ytdlp_input.get(
                "cookies_from_browser",
                ytdlp_input.get("cookies-from-browser", current_ytdlp.get("cookies_from_browser", "")),
            ),
        },
        "auth": {
            "enabled": bool(auth_input.get("enabled", current_auth.get("enabled", False))),
            "username": auth_input.get("username", current_auth.get("username", "airtype")),
            "password": auth_input.get("password", current_auth.get("password", "")),
        },
        "llm_servers": incoming.get("llm_servers", []),
        "default_llm_server_name": incoming.get("default_llm_server_name") or llm_input.get("name", "default"),
    }


def _settings_for_whisper_action(incoming: Dict[str, Any]) -> Dict[str, Any]:
    current = _read_app_settings()
    current_whisper = current.get("whisper", {})
    current_whisper = current_whisper if isinstance(current_whisper, dict) else {}
    requested = normalize_app_settings(_settings_request_to_nested(incoming or {}))
    requested_whisper = requested.get("whisper", {})
    requested_whisper = requested_whisper if isinstance(requested_whisper, dict) else {}

    merged_whisper = dict(current_whisper)
    for key, value in requested_whisper.items():
        if value not in ("", None):
            merged_whisper[key] = value

    requested["whisper"] = normalize_app_settings({"whisper": merged_whisper})["whisper"]
    return requested


@app.get("/api/whisper-server/status")
async def whisper_server_status():
    return {"ok": True, **transcriber.status()}


@app.post("/api/whisper-server/restart")
async def restart_whisper_server(request: AppSettingsRequest):
    nested = _settings_request_to_nested(request.settings or {})
    proposed_settings = _settings_for_whisper_action(request.settings or {})
    whisper_settings = proposed_settings.get("whisper", {})
    remote_endpoint = str(whisper_settings.get("remote_endpoint") or "").strip()

    if remote_endpoint:
        settings = _write_app_settings(nested)
        transcriber.shutdown()
        return {
            "ok": True,
            "mode": "remote",
            "running": False,
            "endpoint": remote_endpoint,
            "settings": settings,
            "message": "Saved settings. External whisper-server endpoint will be used on the next transcription.",
        }

    model_path = _whisper_model_path_from_settings(whisper_settings)
    if not model_path:
        raise HTTPException(
            status_code=400,
            detail="Set model_dir and model_filename before restarting a local whisper-server.",
        )
    if not os.path.exists(model_path):
        raise HTTPException(status_code=400, detail=f"Whisper model not found: {model_path}")

    configured_server_bin = str(whisper_settings.get("server_bin") or "").strip()
    server_bin = os.path.expanduser(configured_server_bin) if configured_server_bin else transcriber.server_binary
    if not server_bin:
        raise HTTPException(
            status_code=400,
            detail="whisper-server executable not found. Set server_bin in [webui.whisper-server].",
        )
    if not os.path.exists(server_bin):
        raise HTTPException(status_code=400, detail=f"whisper-server executable not found: {server_bin}")

    settings = _write_app_settings(nested)
    transcriber.shutdown()

    try:
        ready_endpoint = transcriber._ensure_local_server(
            model_path,
            str(whisper_settings.get("server_args") or ""),
            None,
        )
    except WhisperCppNotConfigured as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Could not restart whisper-server: {exc}") from exc

    return {
        "ok": True,
        "mode": "local",
        "running": True,
        "endpoint": ready_endpoint,
        "model": model_path,
        "server_bin": server_bin,
        "settings": settings,
        "message": f"Restarted local whisper-server at {ready_endpoint}.",
    }


@app.post("/api/whisper-server/test")
async def test_whisper_server(request: AppSettingsRequest):
    settings = _settings_for_whisper_action(request.settings or {})
    whisper_settings = settings.get("whisper", {})
    model_path = _whisper_model_path_from_settings(whisper_settings)
    remote_endpoint = str(whisper_settings.get("remote_endpoint") or "").strip()

    if remote_endpoint:
        test_url = remote_endpoint.rstrip("/")
        try:
            with urllib.request.urlopen(test_url, timeout=3) as response:
                return {
                    "ok": True,
                    "mode": "remote",
                    "endpoint": remote_endpoint,
                    "status": response.status,
                    "message": f"Connected to whisper-server at {remote_endpoint}.",
                }
        except urllib.error.HTTPError as exc:
            if exc.code < 500:
                return {
                    "ok": True,
                    "mode": "remote",
                    "endpoint": remote_endpoint,
                    "status": exc.code,
                    "message": f"Connected to whisper-server at {remote_endpoint}.",
                }
            raise HTTPException(status_code=502, detail=f"whisper-server returned HTTP {exc.code}") from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Could not connect to whisper-server: {exc}") from exc

    if not model_path:
        raise HTTPException(
            status_code=400,
            detail="Set model_dir and model_filename before testing a local whisper-server.",
        )
    if not os.path.exists(model_path):
        raise HTTPException(status_code=400, detail=f"Whisper model not found: {model_path}")

    server_bin = transcriber.server_binary
    if not server_bin:
        raise HTTPException(
            status_code=400,
            detail="whisper-server executable not found. Set server_bin in [webui.whisper-server].",
        )
    if not os.path.exists(server_bin):
        raise HTTPException(status_code=400, detail=f"whisper-server executable not found: {server_bin}")

    try:
        ready_endpoint = transcriber._ensure_local_server(
            model_path,
            str(whisper_settings.get("server_args") or ""),
            None,
        )
    except WhisperCppNotConfigured as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Could not start whisper-server: {exc}") from exc

    return {
        "ok": True,
        "mode": "local",
        "endpoint": ready_endpoint,
        "model_path": model_path,
        "server_bin": server_bin,
        "message": f"Local whisper-server is running at {ready_endpoint}.",
    }


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
    language: Optional[str] = Form(None),
    temperature: Optional[float] = Form(None),
    beam_size: Optional[int] = Form(None),
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
            language,
            temperature,
            beam_size,
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
    language: Optional[str] = Form(None),
    temperature: Optional[float] = Form(None),
    beam_size: Optional[int] = Form(None),
):
    return await transcribe_audio(
        file=file,
        model=model,
        whisper_endpoint=whisper_endpoint,
        language=language,
        temperature=temperature,
        beam_size=beam_size,
        record_type=IME_RECORD_TYPE,
    )


@app.post("/api/transcribe/jobs")
async def create_transcription_job(
    file: UploadFile = File(None),
    model: Optional[str] = Form(None),
    whisper_endpoint: Optional[str] = Form(None),
    language: Optional[str] = Form(None),
    temperature: Optional[float] = Form(None),
    beam_size: Optional[int] = Form(None)
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
        language,
        temperature,
        beam_size,
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
            payload = _http_json("GET", _join_url(request.endpoint, "/api/tags"), api_key=request.api_key)
            models = []
            for model in payload.get("models", []):
                name = model.get("name", "")
                if not name:
                    continue

                model_details = _ollama_model_details(request.endpoint, name, request.api_key)
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
            _patch_config_llm_models_for_endpoint(request.provider, request.endpoint, [model["name"] for model in models])
            return {
                "models": models
            }

        if request.provider == "llama.cpp":
            models = _llamacpp_models(request.endpoint, request.api_key)
            _patch_config_llm_models_for_endpoint(request.provider, request.endpoint, [model["name"] for model in models])
            return {"models": models}

        models_url = request.endpoint.rstrip("/") if request.endpoint.rstrip("/").endswith("/v1/models") else _join_url(request.endpoint, "/v1/models")
        payload = _http_json("GET", models_url, api_key=request.api_key)
        models = [{"name": model.get("id", "")} for model in payload.get("data", []) if model.get("id")]
        _patch_config_llm_models_for_endpoint(request.provider, request.endpoint, [model["name"] for model in models])
        return {"models": models}

    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Could not load local models: {str(e)}")


@app.post("/api/local-llm/health")
async def local_llm_health(request: LocalModelsRequest):
    try:
        _check_local_llm_health(request.provider, request.endpoint, request.api_key)
        return {"ok": True}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Local LLM health check failed: {str(e)}")


@app.post("/api/local-llm/all-models")
async def list_all_local_models():
    try:
        config = read_config(CONFIG_PATH)
        webui = config.get("webui", {})
        servers = webui.get("llm-server", [])
        if not isinstance(servers, list):
            return {"models": []}

        all_models: list[dict] = []
        seen: set[tuple[str, str]] = set()
        models_by_server: dict[str, list[str]] = {}
        for server in servers:
            if not isinstance(server, dict):
                continue
            server_name = str(server.get("name", "") or "")
            provider = server.get("provider", "")
            endpoint = server.get("endpoint", "")
            api_key = server.get("api_key") or server.get("api-key") or None
            if not provider or not endpoint:
                continue
            try:
                payload = await list_local_models(LocalModelsRequest(provider=provider, endpoint=endpoint, api_key=api_key))
                for m in payload.get("models", []):
                    name = m.get("name", "")
                    key = (server_name, name)
                    if name and key not in seen:
                        seen.add(key)
                        models_by_server.setdefault(server_name, []).append(name)
                        all_models.append({**m, "server": server_name})
            except Exception:
                continue
        _patch_config_llm_models(models_by_server)
        return {"models": all_models}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Could not load all models: {str(e)}")


def _patch_config_llm_models(models_by_server: dict[str, list[str]]) -> None:
    if not models_by_server:
        return
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
            lines = config_file.read().splitlines()
    except OSError:
        return

    output: list[str] = []
    block: list[str] = []
    in_llm_server = False

    def flush_block() -> None:
        nonlocal block, in_llm_server
        if not in_llm_server:
            return
        table = _toml_block_values(block)
        server_name = table.get("name", "")
        model_names = models_by_server.get(server_name)
        if model_names is None:
            output.extend(block)
        else:
            patched = _replace_or_append_toml_value(block, "models", _toml_string_array(model_names))
            selected_model = table.get("selected-model") or table.get("default_model") or table.get("model") or ""
            if not selected_model or selected_model not in model_names:
                patched = _replace_or_append_toml_value(patched, "selected-model", _toml_string(model_names[0] if model_names else ""))
            patched = _remove_toml_keys(patched, {"model", "default_model"})
            output.extend(patched)
        block = []
        in_llm_server = False

    for line in lines:
        trimmed = _strip_toml_comment(line).strip()
        if trimmed.startswith("[[") or trimmed.startswith("["):
            flush_block()
            if trimmed == "[[webui.llm-server]]":
                in_llm_server = True
                block = [line]
            else:
                output.append(line)
        elif in_llm_server:
            block.append(line)
        else:
            output.append(line)
    flush_block()

    with open(CONFIG_PATH, "w", encoding="utf-8") as config_file:
        config_file.write("\n".join(output) + "\n")


def _patch_config_llm_models_for_endpoint(provider: str, endpoint: str, model_names: list[str]) -> None:
    config = read_config(CONFIG_PATH)
    webui = config.get("webui", {})
    servers = webui.get("llm-server", []) if isinstance(webui, dict) else []
    if not isinstance(servers, list):
        return

    requested_endpoint = _llm_base_endpoint(endpoint)
    models_by_server: dict[str, list[str]] = {}
    for server in servers:
        if not isinstance(server, dict):
            continue
        if server.get("provider") != provider:
            continue
        if _llm_base_endpoint(str(server.get("endpoint", ""))) != requested_endpoint:
            continue
        server_name = str(server.get("name", "") or "")
        if server_name:
            models_by_server[server_name] = model_names
    _patch_config_llm_models(models_by_server)


def _toml_block_values(lines: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in lines:
        trimmed = _strip_toml_comment(line).strip()
        if "=" not in trimmed:
            continue
        key, value = trimmed.split("=", 1)
        values[key.strip()] = _parse_toml_scalar(value.strip())
    return values


def _replace_or_append_toml_value(lines: list[str], key: str, value: str) -> list[str]:
    replacement = f"{key} = {value}"
    for index, line in enumerate(lines):
        trimmed = _strip_toml_comment(line).strip()
        if "=" not in trimmed:
            continue
        current_key = trimmed.split("=", 1)[0].strip()
        if current_key == key:
            return [*lines[:index], replacement, *lines[index + 1:]]
    return [*lines, replacement]


def _remove_toml_keys(lines: list[str], keys: set[str]) -> list[str]:
    kept: list[str] = []
    for line in lines:
        trimmed = _strip_toml_comment(line).strip()
        if "=" in trimmed and trimmed.split("=", 1)[0].strip() in keys:
            continue
        kept.append(line)
    return kept


def _strip_toml_comment(line: str) -> str:
    result = []
    in_string = False
    escaped = False
    for char in line:
        if escaped:
            result.append(char)
            escaped = False
        elif char == "\\" and in_string:
            result.append(char)
            escaped = True
        elif char == '"':
            result.append(char)
            in_string = not in_string
        elif char == "#" and not in_string:
            break
        else:
            result.append(char)
    return "".join(result)


def _parse_toml_scalar(value: str) -> str:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return value
    return parsed if isinstance(parsed, str) else value


def _toml_string(value: str) -> str:
    return json.dumps(str(value))


def _toml_string_array(values: list[str]) -> str:
    return "[" + ", ".join(_toml_string(value) for value in values) + "]"


@app.post("/api/local-llm/chat")
async def chat_with_local_model(request: LocalChatRequest):
    try:
        if not request.model:
            raise ValueError("Model is required.")
        if not request.prompt.strip():
            raise ValueError("Prompt is required.")
        return {"response": _local_chat_response(request)}

    except Exception as e:
        append_service_log(
            "webui",
            "local LLM request failed: "
            f"provider={request.provider} "
            f"endpoint={_llm_base_endpoint(request.endpoint)} "
            f"model={request.model or ''} "
            f"error={e}",
        )
        raise HTTPException(status_code=502, detail=f"Local LLM request failed: {str(e)}")


@app.post("/api/transcribe/url/jobs")
async def create_url_transcription_job(request: UrlTranscribeRequest):
    parsed = urllib.parse.urlparse(request.url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(status_code=400, detail="URL must start with http:// or https://")

    options = _settings_transcribe_options(
        request.model,
        request.whisper_endpoint,
        request.language,
        request.temperature,
        request.beam_size,
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


@app.post("/api/transcribe/records/{job_id}/article")
async def create_transcription_article(job_id: str, request: ArticleRequest, record_type: Optional[str] = None):
    record = _read_transcription_record(job_id, record_type)
    if not record:
        raise HTTPException(status_code=404, detail="Transcript record not found")

    existing = record.get("article") if isinstance(record.get("article"), dict) else {}
    existing_text = str(existing.get("text") or "").strip()
    if existing_text and not request.force:
        return {"article": existing}

    transcript_text = _record_transcript_text(record)
    if not transcript_text:
        raise HTTPException(status_code=400, detail="Transcript text is empty")

    try:
        article = _generate_transcription_article(record, existing, transcript_text)
    except ValueError as e:
        append_service_log("webui", f"Local LLM article generation skipped: {e}")
        raise HTTPException(status_code=400, detail=str(e)) from e
    except Exception as e:
        append_service_log("webui", f"Local LLM article generation failed: {e}")
        raise HTTPException(status_code=502, detail=f"Local LLM article generation failed: {str(e)}")

    record["article"] = article
    record["updated_at"] = article["updated_at"]
    _save_transcription_record(job_id, record, record_type)
    return {"article": article}


@app.get("/api/transcribe/records/{job_id}/media")
async def get_transcription_record_media(request: Request, job_id: str, record_type: Optional[str] = None):
    if not _is_valid_record_id(job_id):
        raise HTTPException(status_code=404, detail="Transcript media not found")

    record = _read_transcription_record(job_id, record_type)
    source = record.get("source") if record else None
    source_path = source.get("path") if source else None
    if (
        not source_path
        or not os.path.exists(source_path)
        or not _is_job_stored_source(job_id, source_path)
    ):
        raise HTTPException(status_code=404, detail="Transcript media not found")

    media_type = _record_source_media_type(source, source_path)
    return _media_file_response(source_path, media_type, request.headers.get("range"))


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
    merged = normalize_app_settings({**DEFAULT_APP_SETTINGS, **settings})
    llm_servers, default_llm_server_name = _read_backend_llm_servers()
    if llm_servers:
        selected = _select_llm_server(llm_servers, default_llm_server_name)
        if selected:
            merged["llm"] = normalize_app_settings({"llm": selected})["llm"]
        merged["llm_servers"] = llm_servers
        merged["default_llm_server_name"] = default_llm_server_name or merged["llm"].get("name", "default")
    return merged


def _write_app_settings(settings: Dict[str, Any]) -> Dict[str, Any]:
    allowed = set(DEFAULT_APP_SETTINGS)
    merged = normalize_app_settings(
        {
            **DEFAULT_APP_SETTINGS,
            **{key: value for key, value in settings.items() if key in allowed},
        }
    )
    llm_servers = _normalized_llm_servers_from_settings(settings, merged["llm"])
    default_llm_server_name = str(settings.get("default_llm_server_name") or merged["llm"].get("name") or "default")
    selected = _select_llm_server(llm_servers, default_llm_server_name)
    if selected:
        merged["llm"] = normalize_app_settings({"llm": selected})["llm"]
    merged["llm_servers"] = llm_servers
    merged["default_llm_server_name"] = default_llm_server_name
    _write_backend_config_settings(merged)
    return merged


def _read_backend_config_settings() -> Dict[str, Any]:
    return read_webui_settings(CONFIG_PATH)


def _read_backend_llm_servers() -> tuple[list[Dict[str, Any]], str]:
    config = read_config(CONFIG_PATH)
    webui = config.get("webui", {})
    if not isinstance(webui, dict):
        return [], ""
    servers = webui.get("llm-server", [])
    if isinstance(servers, dict):
        servers = [servers]
    if not isinstance(servers, list):
        return [], ""
    normalized_servers = [
        _normalize_llm_server(server)
        for server in servers
        if isinstance(server, dict)
    ]
    normalized_servers = [server for server in normalized_servers if server.get("name")]
    return normalized_servers, str(webui.get("default-llm-server-name") or "")


def _normalize_llm_server(server: Dict[str, Any]) -> Dict[str, Any]:
    normalized = normalize_app_settings({"llm": server})["llm"]
    normalized["name"] = str(server.get("name") or normalized.get("name") or "default")
    normalized["provider"] = str(normalized.get("provider") or "llama.cpp")
    normalized["endpoint"] = str(normalized.get("endpoint") or "http://127.0.0.1:8080")
    normalized["api_key"] = str(normalized.get("api_key") or server.get("api-key") or "")
    normalized["selected_model"] = (
        normalized.get("selected_model")
        or server.get("selected-model")
        or server.get("default_model")
        or server.get("model")
        or ""
    )
    normalized["model"] = normalized["selected_model"]
    return normalized


def _select_llm_server(servers: list[Dict[str, Any]], default_name: str) -> Optional[Dict[str, Any]]:
    if default_name:
        for server in servers:
            if server.get("name") == default_name:
                return server
    return servers[0] if servers else None


def _normalized_llm_servers_from_settings(settings: Dict[str, Any], selected_llm: Dict[str, Any]) -> list[Dict[str, Any]]:
    raw_servers = settings.get("llm_servers") or settings.get("llmServers") or []
    servers = [
        _normalize_llm_server(server)
        for server in raw_servers
        if isinstance(server, dict)
    ] if isinstance(raw_servers, list) else []

    selected = _normalize_llm_server(selected_llm)
    selected_name = selected.get("name") or "default"
    if not servers:
        return [selected]

    replaced = False
    for index, server in enumerate(servers):
        if server.get("name") == selected_name:
            servers[index] = selected
            replaced = True
            break
    if not replaced:
        servers.append(selected)
    return servers


def _write_backend_config_settings(settings: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(CONFIG_PATH), exist_ok=True)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
            text = config_file.read()
    except OSError:
        text = "# AirType user config\n"

    text = remove_webui_sections(text).rstrip()
    backend_text = _render_backend_config_settings(settings)
    if text:
        text = f"{text}\n\n{backend_text}\n"
    else:
        text = f"{backend_text}\n"

    with open(CONFIG_PATH, "w", encoding="utf-8") as config_file:
        config_file.write(text)


def _render_backend_config_settings(settings: Dict[str, Any]) -> str:
    llm_servers = settings.get("llm_servers")
    if not isinstance(llm_servers, list) or not llm_servers:
        return render_webui_settings_toml(settings)

    normalized = normalize_app_settings(settings)
    whisper = normalized["whisper"]
    ytdlp = normalized["ytdlp"]
    auth = normalized["auth"]
    selected_llm = normalized["llm"]
    default_name = str(settings.get("default_llm_server_name") or selected_llm.get("name") or "default")
    lines = [
        "#===============================================================================",
        "# Web UI Settings",
        "#===============================================================================",
        "",
        "[webui.whisper-server]",
        f"model_dir = {_toml_string(whisper.get('model_dir', ''))}",
        f"model_filename = {_toml_string(whisper.get('model_filename', ''))}",
        f"server_bin = {_toml_string(whisper.get('server_bin', ''))}",
        f"remote_endpoint = {_toml_string(whisper.get('remote_endpoint', ''))}",
        f"server_args = {_toml_string(whisper.get('server_args', ''))}",
        f"language = {_toml_string(whisper.get('language', 'zh-tw'))}",
        f"beam = {whisper.get('beam', 5)}",
        f"temperature = {whisper.get('temperature', 0)}",
        "",
        "[webui.yt-dlp]",
        f"cookies = {_toml_string(ytdlp.get('cookies', ''))}",
        f"cookies_from_browser = {_toml_string(ytdlp.get('cookies_from_browser', ''))}",
        "",
        "[webui.auth]",
        f"enabled = {'true' if auth.get('enabled') else 'false'}",
        f"username = {_toml_string(auth.get('username', 'airtype'))}",
        f"password = {_toml_string(auth.get('password', ''))}",
        "",
    ]

    for raw_server in llm_servers:
        if not isinstance(raw_server, dict):
            continue
        server = _normalize_llm_server(raw_server)
        lines.extend(
            [
                "[[webui.llm-server]]",
                f"name = {_toml_string(server.get('name', 'default'))}",
                f"provider = {_toml_string(server.get('provider', 'llama.cpp'))}",
                f"endpoint = {_toml_string(server.get('endpoint', 'http://127.0.0.1:8080'))}",
                f"api_key = {_toml_string(server.get('api_key', ''))}",
                f"models = {_toml_string_array(server.get('models', []))}",
                f"selected-model = {_toml_string(server.get('selected_model', server.get('model', '')))}",
                f"contextLength = {server.get('contextLength', 8192)}",
                f"temperature = {server.get('temperature', 0.4)}",
                f"system = {_toml_string(server.get('system', ''))}",
                "",
            ]
        )

    lines.extend(
        [
            "[webui]",
            f"default-llm-server-name = {_toml_string(default_name)}",
        ]
    )
    return "\n".join(lines)


def _whisper_model_path_from_settings(whisper_settings: Dict[str, Any]) -> Optional[str]:
    return whisper_model_path_from_settings(whisper_settings)


def _split_whisper_model_settings(
    whisper_settings: Dict[str, Any],
) -> tuple[str, str]:
    return split_whisper_model_settings(whisper_settings)


def _settings_transcribe_options(
    model: Optional[str],
    whisper_endpoint: Optional[str],
    language: Optional[str],
    temperature: Optional[float],
    beam_size: Optional[int],
) -> Dict[str, Any]:
    settings = _read_app_settings()
    whisper_settings = settings.get("whisper", {})
    selected_model = model or _whisper_model_path_from_settings(whisper_settings)

    remote_endpoint = whisper_endpoint if whisper_endpoint is not None else whisper_settings.get("remote_endpoint", "")
    if not (remote_endpoint or "").strip():
        remote_endpoint = ""

    return {
        "model_path": selected_model,
        "server_endpoint": remote_endpoint,
        "server_args": whisper_settings.get("server_args", ""),
        "language": language or whisper_settings.get("language") or None,
        "temperature": temperature if temperature is not None else whisper_settings.get("temperature", 0),
        "beam_size": beam_size if beam_size is not None else whisper_settings.get("beam", 5),
    }


def _settings_request_info(request_info: Dict[str, Any], options: Dict[str, Any]) -> Dict[str, Any]:
    return {
        **request_info,
        "model": options.get("model_path"),
        "whisper_endpoint": options.get("server_endpoint"),
        "language": options.get("language"),
        "temperature": options.get("temperature"),
        "beam_size": options.get("beam_size"),
    }


def _download_url(
    url: str,
    destination: str,
    max_bytes: int = 2 * 1024 * 1024 * 1024,
    progress_callback: Optional[Callable[[int, Optional[int]], None]] = None,
) -> Dict[str, Any]:
    if _should_use_media_downloader(url):
        metadata = _download_media_page(url, destination)
        downloaded_path = metadata.get("downloaded_path") if isinstance(metadata.get("downloaded_path"), str) else destination
        if os.path.getsize(downloaded_path) > max_bytes:
            raise ValueError("Remote file is larger than 2GB.")
        return metadata

    request = urllib.request.Request(url, headers={"User-Agent": "AirType/1.0"})
    downloaded = 0
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            content_type = response.headers.get("Content-Type", "")
            if content_type and not _is_supported_media(content_type, urllib.parse.urlparse(url).path):
                return _download_media_page(url, destination)
            total_bytes = _header_content_length(response.headers.get("Content-Length"))

            with open(destination, "wb") as output:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    downloaded += len(chunk)
                    if downloaded > max_bytes:
                        raise ValueError("Remote file is larger than 2GB.")
                    output.write(chunk)
                    if progress_callback:
                        progress_callback(downloaded, total_bytes)
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


def _header_content_length(value: Optional[str]) -> Optional[int]:
    try:
        parsed = int(value or "")
    except (TypeError, ValueError):
        return None
    return parsed if parsed >= 0 else None


def _preview_url_metadata(url: str) -> Dict[str, Any]:
    if not _should_use_media_downloader(url):
        return {}

    downloader_command = _media_downloader_command()
    if not downloader_command:
        return {}

    original_url = url
    url = _resolve_media_url(url)
    command = downloader_command + [
        "--no-playlist",
        "--skip-download",
        "--dump-json",
    ]
    command.extend(_media_downloader_site_args(url))
    command.extend(_media_downloader_browser_args(tuple(downloader_command), url))
    command.extend(_media_downloader_cookie_args())
    command.append(url)
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired):
        return {}

    if process.returncode != 0:
        return {}

    for line in reversed((process.stdout or "").splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            metadata = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(metadata, dict):
            return {
                "download_method": "yt-dlp-preview",
                "url": original_url,
                **({"resolved_url": url} if url != original_url else {}),
                **metadata,
            }
    return {}


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
    downloader_command = _media_downloader_command()
    if not downloader_command:
        raise RuntimeError(
            "yt-dlp is required to download YouTube, Bilibili, Instagram, Threads, TikTok, or Shorts URLs. "
            "Install WebUI Python dependencies into .venv with ./scripts/setup.sh."
        )

    original_url = url
    url = _resolve_media_url(url)
    with tempfile.TemporaryDirectory(prefix="airtype-url-media-") as work_dir:
        process = _run_media_downloader(
            downloader_command,
            work_dir,
            url,
            "bestaudio/best",
        )
        if process.returncode != 0:
            detail = (process.stderr or process.stdout).strip()
            hint = _media_downloader_failure_hint(original_url, detail)
            raise RuntimeError(f"Could not download media URL with yt-dlp: {detail}{hint}")

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
        destination = _destination_with_media_extension(destination, media_path)
        shutil.move(media_path, destination)
        return {
            "download_method": "yt-dlp-audio",
            **metadata,
            "url": original_url,
            **({"resolved_url": url} if url != original_url else {}),
            "downloaded_path": destination,
        }


def _destination_with_media_extension(destination: str, media_path: str) -> str:
    media_ext = os.path.splitext(media_path)[1]
    if not media_ext:
        return destination

    destination_ext = os.path.splitext(destination)[1]
    if destination_ext == media_ext:
        return destination

    return os.path.splitext(destination)[0] + media_ext


def _media_downloader_command() -> list[str]:
    try:
        import yt_dlp  # noqa: F401
    except ImportError:
        downloader = shutil.which("yt-dlp")
        return [downloader] if downloader else []
    return [sys.executable, "-m", "yt_dlp"]


def _run_media_downloader(
    downloader_command: list[str],
    work_dir: str,
    url: str,
    format_selector: str,
) -> subprocess.CompletedProcess[str]:
    output_template = os.path.join(work_dir, "source.%(ext)s")
    is_bilibili = _is_bilibili_url(url)
    command = downloader_command + [
        "--no-playlist",
        "--max-filesize",
        "2G",
        "--retries",
        "20" if is_bilibili else "3",
        "--fragment-retries",
        "20" if is_bilibili else "3",
        "--write-info-json",
        "-f",
        format_selector,
        "-o",
        output_template,
    ]
    if is_bilibili:
        command.extend(["--continue", "--http-chunk-size", "512K", "--sleep-requests", "1"])
    command.extend(_media_downloader_site_args(url))
    command.extend(_media_downloader_browser_args(tuple(downloader_command), url))
    command.extend(_media_downloader_cookie_args())
    command.append(url)
    return subprocess.run(command, capture_output=True, text=True, timeout=60 * 30)


def _is_bilibili_url(url: str) -> bool:
    host = urllib.parse.urlparse(url).netloc.lower()
    return "bilibili.com" in host or "b23.tv" in host


def _resolve_media_url(url: str) -> str:
    if not _is_b23_url(url):
        return url

    resolved_url = _resolve_b23_with_urllib(url) or _resolve_b23_with_curl(url)
    return resolved_url if resolved_url and _is_bilibili_url(resolved_url) else url


def _resolve_b23_with_urllib(url: str) -> str:
    headers = _bilibili_browser_headers()
    for method in ("HEAD", "GET"):
        request = urllib.request.Request(url, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.geturl()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError):
            continue
    return ""


def _resolve_b23_with_curl(url: str) -> str:
    curl = shutil.which("curl")
    if not curl:
        return ""

    try:
        process = subprocess.run(
            [
                curl,
                "-L",
                "-sS",
                "-o",
                os.devnull,
                "-w",
                "%{url_effective}",
                "-A",
                _bilibili_user_agent(),
                "-H",
                "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "-H",
                "Accept-Language: zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
                url,
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""

    if process.returncode != 0:
        return ""
    return (process.stdout or "").strip()


def _bilibili_browser_headers() -> Dict[str, str]:
    return {
        "User-Agent": _bilibili_user_agent(),
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
    }


def _bilibili_user_agent() -> str:
    return (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/125.0.0.0 Safari/537.36"
    )


def _is_b23_url(url: str) -> bool:
    return "b23.tv" in urllib.parse.urlparse(url).netloc.lower()


def _media_downloader_site_args(url: str) -> list[str]:
    if _is_bilibili_url(url):
        referer = _bilibili_referer(url)
        return [
            "--referer",
            referer,
            "--add-header",
            f"Referer:{referer}",
            "--add-header",
            "Origin:https://www.bilibili.com",
            "--add-header",
            "Accept:application/json, text/plain, */*",
            "--add-header",
            "Accept-Language:zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
            "--add-header",
            "Sec-Fetch-Dest:empty",
            "--add-header",
            "Sec-Fetch-Mode:cors",
            "--add-header",
            "Sec-Fetch-Site:same-site",
        ]
    return []


def _bilibili_referer(url: str) -> str:
    match = re.search(r"/video/([^/?#]+)", url, re.IGNORECASE)
    if match:
        return f"https://www.bilibili.com/video/{match.group(1)}/"
    return "https://www.bilibili.com/"


def _media_downloader_browser_args(downloader_command: tuple[str, ...], url: str) -> list[str]:
    if not _is_bilibili_url(url):
        return []

    impersonate_target = _best_impersonate_target(downloader_command)
    if impersonate_target:
        return ["--impersonate", impersonate_target]

    return [
        "--user-agent",
        _bilibili_user_agent(),
    ]


@functools.lru_cache(maxsize=8)
def _best_impersonate_target(downloader_command: tuple[str, ...]) -> str:
    try:
        process = subprocess.run(
            [*downloader_command, "--list-impersonate-targets"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""

    if process.returncode != 0:
        return ""

    target_output = process.stdout or ""
    candidates = [
        ("chrome-136:macos-15", "Chrome-136", "Macos-15"),
        ("chrome-133:macos-15", "Chrome-133", "Macos-15"),
        ("chrome-131:macos-14", "Chrome-131", "Macos-14"),
        ("chrome-124:macos-14", "Chrome-124", "Macos-14"),
    ]
    for target, client, os_name in candidates:
        if client in target_output and os_name in target_output:
            return target

    return "chrome" if "Chrome-" in target_output and "unavailable" not in target_output else ""


def _media_downloader_cookie_args() -> list[str]:
    ytdlp_settings = _read_backend_config_settings().get("ytdlp", {})
    cookies_path = str(ytdlp_settings.get("cookies") or "").strip()
    if cookies_path:
        return ["--cookies", os.path.expanduser(cookies_path)]

    cookies_browser = str(ytdlp_settings.get("cookies_from_browser") or "").strip()
    if cookies_browser:
        return ["--cookies-from-browser", cookies_browser]

    return []


def _media_downloader_failure_hint(url: str, detail: str) -> str:
    parsed = urllib.parse.urlparse(url)
    host = parsed.netloc.lower()
    if ("bilibili.com" in host or "b23.tv" in host) and "HTTP Error 412" in detail:
        return (
            " BiliBili rejected the metadata request. AirType sends BiliBili browser-style headers "
            "and uses yt-dlp --impersonate when available. If this still fails, update yt-dlp, install "
            "a compatible curl_cffi package for impersonation, or provide logged-in cookies in "
            "[webui.yt-dlp] with cookies = \"/path/to/cookies.txt\" or cookies_from_browser = \"chrome\"."
        )
    return ""


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
            "ext",
            "format",
            "format_id",
            "resolution",
            "upload_date",
            "timestamp",
        )
        if info.get(key) is not None
    }


def _join_url(endpoint: str, path: str) -> str:
    return endpoint.rstrip("/") + path


def _llm_base_endpoint(endpoint: str) -> str:
    endpoint = endpoint.rstrip("/")
    for suffix in ("/v1/models", "/models"):
        if endpoint.endswith(suffix):
            return endpoint[: -len(suffix)] or endpoint
    return endpoint


def _http_json(
    method: str,
    url: str,
    payload: Optional[Dict[str, Any]] = None,
    api_key: Optional[str] = None,
) -> Dict[str, Any]:
    data = None
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": "AirType/1.0",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace").strip()
        detail = f"HTTP {error.code} from {url}"
        if body:
            detail += f": {body[:1000]}"
        raise ValueError(detail) from error


def _http_json_with_timeout(
    method: str,
    url: str,
    timeout: float,
    payload: Optional[Dict[str, Any]] = None,
    api_key: Optional[str] = None,
) -> Dict[str, Any]:
    data = None
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": "AirType/1.0",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as error:
        raise ValueError(f"HTTP {error.code} from {url}") from error
    except urllib.error.URLError as error:
        raise ValueError(str(error.reason)) from error


def _check_local_llm_health(provider: str, endpoint: str, api_key: Optional[str] = None) -> None:
    provider = (provider or "").strip()
    endpoint = (endpoint or "").strip()
    if not endpoint:
        raise ValueError("No Local LLM endpoint configured.")

    base_endpoint = _llm_base_endpoint(endpoint)
    if provider == "ollama":
        _http_json_with_timeout("GET", _join_url(base_endpoint, "/api/tags"), 2, api_key=api_key)
        return

    if provider == "llama.cpp":
        for path in ("/health", "/props", "/v1/models", "/models"):
            try:
                _http_json_with_timeout("GET", _join_url(base_endpoint, path), 2, api_key=api_key)
                return
            except Exception:
                continue
        raise ValueError("Could not reach llama.cpp health, props, or models endpoints.")

    models_url = endpoint.rstrip("/") if endpoint.rstrip("/").endswith("/v1/models") else _join_url(base_endpoint, "/v1/models")
    _http_json_with_timeout("GET", models_url, 2, api_key=api_key)


def _llm_messages(system: Optional[str], prompt: str) -> list[Dict[str, str]]:
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})
    return messages


def _local_chat_response(request: LocalChatRequest) -> str:
    if request.provider == "ollama":
        payload = _http_json(
            "POST",
            _join_url(_llm_base_endpoint(request.endpoint), "/api/chat"),
            {
                "model": request.model,
                "stream": False,
                "messages": _llm_messages(request.system, request.prompt),
                "options": {
                    "temperature": request.temperature,
                    "num_ctx": _request_context_length(request),
                },
            },
            api_key=request.api_key,
        )
        return payload.get("message", {}).get("content", "")

    payload = _http_json(
        "POST",
        _join_url(_llm_base_endpoint(request.endpoint), "/v1/chat/completions"),
        {
            "model": request.model,
            "messages": _llm_messages(request.system, request.prompt),
            "temperature": request.temperature,
            **({"n_ctx": _request_context_length(request)} if request.provider == "llama.cpp" else {}),
        },
        api_key=request.api_key,
    )
    choices = payload.get("choices", [])
    return choices[0].get("message", {}).get("content", "") if choices else ""


def _request_context_length(request: LocalChatRequest) -> int:
    return request.context_length or request.context or 8192


def _ollama_model_details(endpoint: str, model: str, api_key: Optional[str] = None) -> Dict[str, Any]:
    try:
        return _http_json("POST", _join_url(endpoint, "/api/show"), {"model": model}, api_key=api_key)
    except Exception:
        return {}


def _llamacpp_models(endpoint: str, api_key: Optional[str] = None) -> list[Dict[str, Any]]:
    payload = _llamacpp_models_payload(endpoint, api_key)
    props = {}
    if payload is None:
        props = _llamacpp_props(endpoint, api_key=api_key)
        if not props:
            raise ValueError("Could not read llama.cpp /models or /props.")
        payload = {"data": []}

    models = []
    for item in payload.get("data", []):
        name = item.get("id", "")
        if not name:
            continue

        props = item.get("meta") if isinstance(item.get("meta"), dict) else {}
        if not props:
            props = _llamacpp_props(endpoint, name, api_key=api_key)
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

    props = props or _llamacpp_props(endpoint, api_key=api_key)
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


def _llamacpp_models_payload(endpoint: str, api_key: Optional[str] = None) -> Optional[Dict[str, Any]]:
    endpoint = endpoint.rstrip("/")
    if endpoint.endswith("/v1/models") or endpoint.endswith("/models"):
        try:
            return _http_json("GET", endpoint, api_key=api_key)
        except Exception:
            return None

    base_endpoint = _llm_base_endpoint(endpoint)
    for path in ("/v1/models", "/models", "/models?reload=1"):
        try:
            return _http_json("GET", _join_url(base_endpoint, path), api_key=api_key)
        except Exception:
            continue
    return None


def _llamacpp_props(
    endpoint: str,
    model: Optional[str] = None,
    api_key: Optional[str] = None,
) -> Dict[str, Any]:
    endpoint = _llm_base_endpoint(endpoint)
    paths = ["/props"]
    if model:
        quoted_model = urllib.parse.quote(model, safe="")
        paths.insert(0, f"/props?model={quoted_model}&autoload=false")

    for path in paths:
        try:
            return _http_json("GET", _join_url(endpoint, path), api_key=api_key)
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
        "details": {},
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
        "title": job.get("title"),
        "source_name": job["source_name"],
        "source_size": job["source_size"],
        "source_type": job["source_type"],
        "source_url": _source_url(job),
        "source_metadata": job.get("source_metadata"),
        "details": job.get("details") or {},
        "partial_segments": job["partial_segments"],
        "result": job["result"],
        "error": job["error"],
        "article_error": job.get("article_error"),
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
    }


def _update_job(job_id: str, **updates: Any) -> None:
    job = transcription_jobs[job_id]
    job.update(updates)
    job["updated_at"] = datetime.now(timezone.utc).isoformat()
    _write_job_record(job_id)


def _update_job_details(job_id: str, **updates: Any) -> None:
    job = transcription_jobs[job_id]
    details = dict(job.get("details") or {})
    details.update({key: value for key, value in updates.items() if value is not None})
    _update_job(job_id, details=details)


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
    source_url = _source_url(job)
    record = {
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
            "url": source_url,
            "path": source_path,
            "relative_path": os.path.relpath(source_path, job_dir) if source_path else None,
            "metadata": job.get("source_metadata"),
        },
        "request": job.get("request") or {},
        "details": job.get("details") or {},
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
        "article_error": job.get("article_error"),
        "created_at": job.get("created_at"),
        "updated_at": job.get("updated_at"),
    }
    if isinstance(job.get("article"), dict):
        record["article"] = job["article"]
    return record


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


def _source_url(job: Dict[str, Any]) -> Optional[str]:
    request_info = job.get("request") if isinstance(job.get("request"), dict) else {}
    request_url = request_info.get("url")
    if isinstance(request_url, str) and request_url.strip():
        return request_url.strip()

    metadata = job.get("source_metadata") if isinstance(job.get("source_metadata"), dict) else {}
    for key in ("webpage_url", "url", "original_url", "resolved_url"):
        value = metadata.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _metadata_file_size(metadata: Optional[Dict[str, Any]]) -> Optional[int]:
    if not metadata:
        return None

    for key in ("filesize", "filesize_approx", "content_length"):
        value = metadata.get(key)
        if isinstance(value, (int, float)) and value > 0:
            return int(value)
        if isinstance(value, str) and value.isdigit():
            return int(value)
    return None


def _metadata_duration(metadata: Optional[Dict[str, Any]]) -> Optional[float]:
    if not metadata:
        return None

    value = metadata.get("duration")
    if isinstance(value, (int, float)) and value > 0:
        return float(value)
    if isinstance(value, str):
        try:
            parsed = float(value)
        except ValueError:
            return None
        return parsed if parsed > 0 else None
    return None


def _probe_media_duration(source_path: str) -> Optional[float]:
    if not source_path or not os.path.exists(source_path):
        return None

    try:
        process = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                source_path,
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if process.returncode != 0:
        return None
    try:
        duration = float((process.stdout or "").strip())
    except ValueError:
        return None
    return duration if duration > 0 else None


def format_bytes(value: int) -> str:
    size = float(max(0, value))
    units = ("B", "KB", "MB", "GB")
    unit_index = 0
    while size >= 1024 and unit_index < len(units) - 1:
        size /= 1024
        unit_index += 1
    precision = 0 if size >= 10 or unit_index == 0 else 1
    return f"{size:.{precision}f} {units[unit_index]}"


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


def _save_transcription_record(job_id: str, record: Dict[str, Any], record_type: Optional[str] = None) -> None:
    os.makedirs(_job_dir(job_id, record_type), exist_ok=True)
    with open(_record_path(job_id, record_type), "w", encoding="utf-8") as record_file:
        json.dump(record, record_file, ensure_ascii=False, indent=2)


def _record_transcript_text(record: Dict[str, Any]) -> str:
    transcript = record.get("transcript") if isinstance(record.get("transcript"), dict) else {}
    text = str(transcript.get("text") or "").strip()
    if text:
        return text
    segments = transcript.get("segments") if isinstance(transcript, dict) else []
    if isinstance(segments, list):
        return "\n".join(
            str(segment.get("text") or "").strip()
            for segment in segments
            if isinstance(segment, dict) and str(segment.get("text") or "").strip()
        )
    return ""


def _article_system_prompt() -> str:
    return "不需要說明、列出細節，只需要整理逐字稿，包括釘正錯字、潤飾語句，串接逐字稿成一篇文章。"


def _article_user_prompt(record: Dict[str, Any], transcript_text: str) -> str:
    source = record.get("source") if isinstance(record.get("source"), dict) else {}
    title = record.get("title") or source.get("name") or "Untitled transcript"
    return (
        f"Title: {title}\n\n"
        "請整理以下逐字稿，修正明顯錯字並潤飾成一篇連貫文章。只輸出文章內容。\n\n"
        "逐字稿：\n"
        f"{transcript_text}"
    )


def _article_request_payload(record: Dict[str, Any], transcript_text: str) -> tuple[str, str, int]:
    system_prompt = _article_system_prompt()
    user_prompt = _article_user_prompt(record, transcript_text)
    return system_prompt, user_prompt, len(system_prompt) + len(user_prompt)


def _generate_transcription_article(
    record: Dict[str, Any],
    existing: Optional[Dict[str, Any]] = None,
    transcript_text: Optional[str] = None,
) -> Dict[str, Any]:
    transcript_text = (transcript_text or _record_transcript_text(record)).strip()
    if not transcript_text:
        raise ValueError("Transcript text is empty")

    settings = _read_app_settings()
    llm = settings.get("llm", {}) if isinstance(settings.get("llm"), dict) else {}
    model = str(llm.get("model") or llm.get("selected_model") or "").strip()
    if not model:
        models = llm.get("models")
        if isinstance(models, list):
            model = next((str(candidate).strip() for candidate in models if str(candidate).strip()), "")
    if not model:
        raise ValueError("Local LLM model is not configured")

    system_prompt, user_prompt, request_chars = _article_request_payload(record, transcript_text)
    provider = str(llm.get("provider") or "llama.cpp")
    endpoint = str(llm.get("endpoint") or "http://127.0.0.1:8080")
    api_key = str(llm.get("api_key") or "")
    server_name = str(llm.get("name") or settings.get("default_llm_server_name") or "default")
    append_service_log(
        "webui",
        "requesting Local LLM article: "
        f"server={server_name} provider={provider} "
        f"endpoint={_llm_base_endpoint(endpoint)} model={model} chars={request_chars}",
    )
    article_text = _local_chat_response(
        LocalChatRequest(
            provider=provider,
            endpoint=endpoint,
            api_key=api_key or None,
            model=model,
            system=system_prompt,
            prompt=user_prompt,
            temperature=float(llm.get("temperature", 0.4) or 0.4),
            context_length=int(llm.get("contextLength", 8192) or 8192),
        )
    ).strip()
    if not article_text:
        raise RuntimeError("Local LLM returned an empty article")

    existing = existing if isinstance(existing, dict) else {}
    now = datetime.now(timezone.utc).isoformat()
    return {
        "text": article_text,
        "model": model,
        "provider": provider,
        "server": server_name,
        "request_chars": request_chars,
        "created_at": existing.get("created_at") or now,
        "updated_at": now,
    }


def _update_transcription_record(job_id: str, title: str, record_type: Optional[str] = None) -> Optional[Dict[str, Any]]:
    clean_title = title.strip()
    if not clean_title:
        raise HTTPException(status_code=400, detail="Title cannot be empty")

    record = _read_transcription_record(job_id, record_type)
    if not record:
        return None

    record["title"] = clean_title
    record["updated_at"] = datetime.now(timezone.utc).isoformat()
    _save_transcription_record(job_id, record, record_type)

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
        _update_job(job_id, status="downloading", progress=3, message="Reading media title")
        preview_metadata = _preview_url_metadata(url)
        preview_title = _metadata_title(preview_metadata)
        if preview_metadata:
            _update_job_details(
                job_id,
                total_bytes=_metadata_file_size(preview_metadata),
                duration=_metadata_duration(preview_metadata),
            )
        if preview_title:
            _update_job(
                job_id,
                title=preview_title,
                source_name=preview_title,
                source_metadata=preview_metadata,
                message="Media title loaded",
            )
        elif preview_metadata:
            _update_job(job_id, source_metadata=preview_metadata)
        if _is_job_cancelled(job_id):
            return
        _update_job(job_id, status="downloading", progress=5, message="Downloading source URL")

        def on_download_progress(downloaded_bytes: int, total_bytes: Optional[int]) -> None:
            if _is_job_cancelled(job_id):
                return
            percent = 5
            if total_bytes and total_bytes > 0:
                percent = max(5, min(35, 5 + round((downloaded_bytes / total_bytes) * 30)))
            _update_job_details(
                job_id,
                downloaded_bytes=downloaded_bytes,
                total_bytes=total_bytes,
            )
            _update_job(
                job_id,
                status="downloading",
                progress=percent,
                message=f"Downloading {format_bytes(downloaded_bytes)}",
            )

        metadata = _download_url(url, temp_path, progress_callback=on_download_progress)
        downloaded_path = metadata.get("downloaded_path") if isinstance(metadata.get("downloaded_path"), str) else temp_path
        metadata_title = _metadata_title(metadata)
        if metadata:
            _update_job_details(
                job_id,
                total_bytes=_metadata_file_size(metadata),
                duration=_metadata_duration(metadata),
            )
        if metadata_title:
            _update_job(
                job_id,
                title=metadata_title,
                source_name=metadata_title,
                source_metadata=metadata,
            )
        elif metadata:
            _update_job(job_id, source_metadata=metadata)
        media_type = _guess_media_type(downloaded_path, metadata)
        if media_type:
            _update_job(job_id, source_type=media_type)
        _update_job_source(job_id, downloaded_path)
        _run_transcription_job(job_id, downloaded_path, options, complete_on_success=False)
        job = transcription_jobs.get(job_id)
        if not job or not job.get("result"):
            return

        record = _record_data(job_id, transcription_jobs[job_id])
        transcript_text = _record_transcript_text(record)
        _, _, article_request_chars = _article_request_payload(record, transcript_text)
        _update_job_details(job_id, article_request_chars=article_request_chars)
        _update_job(
            job_id,
            status="running",
            progress=96,
            message=f"Requesting Local LLM article ({article_request_chars} chars)",
        )
        try:
            article = _generate_transcription_article(record, transcript_text=transcript_text)
            transcription_jobs[job_id]["article"] = article
            _update_job(
                job_id,
                status="completed",
                progress=100,
                message="Transcript and article ready",
            )
        except Exception as article_error:
            append_service_log("webui", f"Local LLM article generation failed: {article_error}")
            _update_job(
                job_id,
                status="completed",
                progress=100,
                message="Transcript ready; article generation failed",
                error=None,
                article_error=str(article_error),
            )
    except Exception as e:
        if _is_job_cancelled(job_id):
            _update_job(job_id, status="cancelled", progress=100, message="Stopped by user")
        else:
            _update_job(job_id, status="failed", progress=100, message="Failed", error=str(e))


def _run_transcription_job(
    job_id: str,
    source_path: str,
    options: Dict[str, Any],
    complete_on_success: bool = True,
) -> None:
    try:
        if _is_job_cancelled(job_id):
            return
        duration = _probe_media_duration(source_path)
        if duration is not None:
            _update_job_details(job_id, duration=duration)
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
            segment_count = len(job["partial_segments"])
            end_value = segment.get("end")
            last_segment_end = float(end_value) if isinstance(end_value, (int, float)) else None
            details = dict(job.get("details") or {})
            details.update(
                {
                    "segment_count": segment_count,
                    **({"last_segment_end": last_segment_end} if last_segment_end is not None else {}),
                }
            )
            duration = details.get("duration")
            audio_progress = None
            if isinstance(duration, (int, float)) and duration > 0 and last_segment_end is not None:
                audio_progress = 45 + round(min(1, max(0, last_segment_end / duration)) * 45)
            _update_job(
                job_id,
                status="running",
                progress=max(job["progress"], min(90, audio_progress if audio_progress is not None else 45 + segment_count * 4)),
                message=f"Transcribing segment {segment_count}",
                details=details,
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
            status="completed" if complete_on_success else "running",
            progress=100 if complete_on_success else 95,
            message="Transcript ready" if complete_on_success else "Transcript ready; preparing article",
            details={
                **(transcription_jobs[job_id].get("details") or {}),
                "segment_count": len(result.get("segments") or []),
                **({"duration": result.get("duration")} if isinstance(result.get("duration"), (int, float)) else {}),
            },
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


def _record_source_media_type(source: Dict[str, Any], source_path: str) -> str:
    source_type = source.get("type")
    if isinstance(source_type, str) and "/" in source_type:
        return source_type
    return _guess_media_type(source_path, source.get("metadata")) or "application/octet-stream"


def _media_file_response(source_path: str, media_type: str, range_header: Optional[str]) -> StreamingResponse:
    file_size = os.path.getsize(source_path)
    start = 0
    end = file_size - 1
    status_code = 200

    if range_header:
        range_match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
        if not range_match:
            raise HTTPException(
                status_code=416,
                detail="Invalid range",
                headers={"Content-Range": f"bytes */{file_size}"},
            )

        start_text, end_text = range_match.groups()
        if start_text:
            start = int(start_text)
            end = int(end_text) if end_text else file_size - 1
        elif end_text:
            suffix_length = int(end_text)
            start = max(0, file_size - suffix_length)
            end = file_size - 1
        else:
            raise HTTPException(
                status_code=416,
                detail="Invalid range",
                headers={"Content-Range": f"bytes */{file_size}"},
            )

        if start >= file_size or end < start:
            raise HTTPException(
                status_code=416,
                detail="Range not satisfiable",
                headers={"Content-Range": f"bytes */{file_size}"},
            )
        end = min(end, file_size - 1)
        status_code = 206

    content_length = end - start + 1
    headers = {
        "Accept-Ranges": "bytes",
        "Content-Length": str(content_length),
        "Content-Disposition": "inline",
    }
    if status_code == 206:
        headers["Content-Range"] = f"bytes {start}-{end}/{file_size}"

    return StreamingResponse(
        _read_file_range(source_path, start, end),
        status_code=status_code,
        media_type=media_type,
        headers=headers,
    )


def _read_file_range(source_path: str, start: int, end: int):
    chunk_size = 1024 * 1024
    with open(source_path, "rb") as source_file:
        source_file.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            chunk = source_file.read(min(chunk_size, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


def _guess_media_type(source_path: str, metadata: Optional[Dict[str, Any]] = None) -> Optional[str]:
    content_type = (metadata or {}).get("content_type")
    if isinstance(content_type, str) and content_type:
        return content_type.split(";")[0].strip()

    guessed, _ = mimetypes.guess_type(source_path)
    if guessed:
        return guessed

    metadata_ext = (metadata or {}).get("ext")
    if isinstance(metadata_ext, str) and metadata_ext:
        ext = f".{metadata_ext.lstrip('.').lower()}"
    else:
        ext = os.path.splitext(source_path)[1].lower()
    if ext in {".mp4", ".mov", ".m4v", ".webm", ".mkv"}:
        return "video/mp4" if ext in {".mp4", ".m4v"} else "video/webm"
    if ext in {".mp3", ".m4a", ".wav", ".aac", ".ogg", ".opus", ".flac"}:
        return "audio/mpeg" if ext == ".mp3" else "audio/wav" if ext == ".wav" else "audio/mp4"
    sniffed = _sniff_media_type(source_path)
    if sniffed:
        return sniffed
    return None


def _sniff_media_type(source_path: str) -> Optional[str]:
    try:
        with open(source_path, "rb") as source_file:
            header = source_file.read(16)
    except OSError:
        return None

    if header.startswith(b"\x1a\x45\xdf\xa3"):
        return "audio/webm"
    if header.startswith(b"ID3"):
        return "audio/mpeg"
    if header.startswith(b"OggS"):
        return "audio/ogg"
    if header.startswith(b"RIFF") and header[8:12] == b"WAVE":
        return "audio/wav"
    if len(header) >= 12 and header[4:8] == b"ftyp":
        brand = header[8:12].lower()
        return "audio/mp4" if brand in {b"m4a ", b"m4b ", b"mp42"} else "video/mp4"
    return None


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


@app.get("/favicon.svg")
async def favicon():
    return FileResponse(os.path.join(STATIC_DIR, "favicon.svg"), media_type="image/svg+xml")


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
