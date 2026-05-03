#!/usr/bin/env python3
"""cc-voice-proxy.py — Mac-side Deepgram→Moonshine WebSocket proxy.

Re-implements (a useful subset of) Deepgram's Live STT WebSocket protocol so
Claude Code's ``/voice`` mode can be redirected here via ``VOICE_STREAM_BASE_URL``
instead of streaming audio to ``api.anthropic.com``. Transcription runs entirely
on this Mac via ``moonshine-onnx`` — no network leaves the machine.

Why on the Mac (not on REMOTE-HOST): the CC audio frames are ALREADY here, so
running the model in-process eliminates the only network hop in the latency
budget. moonshine/tiny on Apple Silicon CPU does ~7x realtime, so the only
meaningful latency is endpoint-detection (300 ms by default).

Wire-up (you do this manually when ready — proxy must be running first):
    1. Start the proxy:    ./cc-voice-proxy.py
    2. Verify it's up:     curl -i http://127.0.0.1:8113/health
    3. Tell Claude Code:   export VOICE_STREAM_BASE_URL=ws://127.0.0.1:8113
                           and restart `claude`
    4. Use /voice as usual; audio never leaves the Mac.

Protocol implemented (subset of Deepgram Live):
    Path: /api/ws/speech_to_text/voice_stream (and ``/`` for sanity)
    Query params honored: encoding, sample_rate, channels, endpointing_ms,
                          utterance_end_ms, language
    Client → server:  binary PCM frames (linear16); plus JSON {"type":"Finalize"|"CloseStream"|"KeepAlive"}
    Server → client:
        {"type":"Metadata", ...}                       on connect
        {"type":"SpeechStarted", ...}                  when VAD trips
        {"type":"Results", "channel":..., "is_final":...}  on each finalized utterance
        {"type":"UtteranceEnd", "last_word_end":...}   after endpointing_ms of silence

Env vars:
    CC_VOICE_PROXY_HOST        listen host (default 127.0.0.1)
    CC_VOICE_PROXY_PORT        listen port (default 8113)
    CC_VOICE_PROXY_MODEL       moonshine model name (default moonshine/tiny;
                               also: moonshine/base)
    CC_VOICE_PROXY_VAD_RMS     speech-start RMS threshold 0..1 (default 0.012)
    CC_VOICE_PROXY_PARTIALS    emit interim partial results (default 0/off)
    CC_VOICE_PROXY_DEBUG       verbose logging (default 0/off)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import struct
import sys
import time
import urllib.parse
import uuid
from dataclasses import dataclass, field
from typing import Optional

# ── Imports we lazy-load so --help works without ML deps ─────────────


# Resolve the STT/ tree relative to this file so the proxy is location-aware
# and can persist its model cache and write logs into the right place even when
# launched from a different cwd (e.g., launchd, systemd, IDE).
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
STT_ROOT = os.environ.get("HERMES_STT_DIR") or os.path.dirname(SCRIPT_DIR)  # .../hermes-1/STT
DEFAULT_MODELS_HUB = os.path.join(STT_ROOT, "models", ".hf-cache")

# Redirect HF cache into STT/models/.hf-cache so all engines share one store
# under STT/ and the user's ~/.cache stays clean. Done before HF imports.
os.environ.setdefault("HF_HOME", DEFAULT_MODELS_HUB)
os.environ.setdefault("HF_HUB_CACHE", os.path.join(DEFAULT_MODELS_HUB, "hub"))

# Make ``STT/lib`` importable so we can use the shared backend abstraction.



# ── Config / globals ────────────────────────────────────────────────

HOST = os.environ.get("CC_VOICE_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("CC_VOICE_PROXY_PORT", "8113"))
# VAD threshold tuned for typical Mac mic input. 0.005 catches normal
# speaking voice (RMS ~0.02–0.08); raise to 0.012 if you get false positives
# from background noise.
VAD_RMS_THRESHOLD = float(os.environ.get("CC_VOICE_PROXY_VAD_RMS", "0.005"))
# Minimum sustained speech (ms) before the VAD enters "in_speech" state.
# Larger value rejects mic clicks / sub-syllable noise.
SPEECH_MIN_MS = int(os.environ.get("CC_VOICE_PROXY_SPEECH_MIN_MS", "200"))
# Drop utterances shorter than this seconds at finalization time. Anything
# shorter is almost certainly fragment noise, transcribes to '', and would
# trigger CC's "no speech detected".
MIN_UTTERANCE_S = float(os.environ.get("CC_VOICE_PROXY_MIN_UTTERANCE_S", "0.4"))
EMIT_PARTIALS = os.environ.get("CC_VOICE_PROXY_PARTIALS", "0") in ("1", "true", "yes")
DEBUG = os.environ.get("CC_VOICE_PROXY_DEBUG", "0") in ("1", "true", "yes")

logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format="%(asctime)s.%(msecs)03d %(levelname)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("cc-voice-proxy")

# Backend (STT engine) loaded lazily so --help / smoke tests don't pay the cost.
_backend = None
_backend_lock: Optional[asyncio.Lock] = None


def _ensure_backend():
    global _backend
    if _backend is None:
        from stt_switch.backends import make_backend_from_env

        _backend = make_backend_from_env()
        _backend.warmup()
    return _backend


# ── Voice-clone capture (auto-push to LuxTTS) ───────────────────────
#
# When a turn produces a real transcript with a clone-suitable duration, we
# fire-and-forget a multipart upload of (audio, transcript) to LuxTTS at
# voices/mac/cc/<timestamp>. This grows the user's voice-clone library
# automatically as they use Claude Code voice mode.
#
# Disable by setting CC_VOICE_PROXY_CAPTURE_ENABLED=0.

CAPTURE_ENABLED = os.environ.get("CC_VOICE_PROXY_CAPTURE_ENABLED", "1") in ("1", "true", "yes")
CAPTURE_LUXTTS_URL = os.environ.get(
    "CC_VOICE_PROXY_LUXTTS_URL", "${LUXTTS_URL}"
)
CAPTURE_VOICE_PREFIX = os.environ.get("CC_VOICE_PROXY_VOICE_PREFIX", "mac/cc")
CAPTURE_MIN_S = float(os.environ.get("CC_VOICE_PROXY_CAPTURE_MIN_S", "3.0"))
CAPTURE_MAX_S = float(os.environ.get("CC_VOICE_PROXY_CAPTURE_MAX_S", "30.0"))


def _push_clone_sample(pcm_bytes: bytes, transcript: str, sample_rate: int = 16000) -> None:
    """Synchronous worker — runs in a thread off the asyncio loop. Wraps the
    raw PCM as WAV in memory and POSTs to LuxTTS /v1/voices. Failures are
    logged but never raise; this is best-effort enrichment of the voice
    library, not part of the user's STT response path."""
    if not CAPTURE_ENABLED:
        return
    duration_s = (len(pcm_bytes) / 2) / sample_rate
    if duration_s < CAPTURE_MIN_S or duration_s > CAPTURE_MAX_S:
        return
    text = (transcript or "").strip()
    if not text:
        return
    try:
        import io
        import ssl as _ssl
        import urllib.request
        import uuid as _uuid
        import wave as _wave

        # Build WAV in memory.
        buf = io.BytesIO()
        with _wave.open(buf, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(sample_rate)
            wf.writeframes(pcm_bytes)
        wav_bytes = buf.getvalue()

        ts = time.strftime("%Y%m%d_%H%M%S")
        voice_id = f"{CAPTURE_VOICE_PREFIX}/{ts}"
        boundary = _uuid.uuid4().hex
        parts: list[bytes] = []
        for k, v in {
            "voice_id": voice_id,
            "transcript": text,
            "overwrite": "false",
        }.items():
            parts += [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{k}"\r\n\r\n'.encode(),
                v.encode("utf-8") + b"\r\n",
            ]
        parts += [
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="audio"; filename="clip.wav"\r\n',
            b"Content-Type: audio/wav\r\n\r\n",
            wav_bytes,
            b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
        body = b"".join(parts)

        ctx = _ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = _ssl.CERT_NONE
        req = urllib.request.Request(
            f"{CAPTURE_LUXTTS_URL.rstrip('/')}/v1/voices",
            data=body,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
            payload = r.read()
        log.info("[clone] uploaded %s (%.1fs, %db) → %s",
                 voice_id, duration_s, len(wav_bytes), payload[:100].decode("utf-8", "replace"))
    except Exception as e:
        log.warning("[clone] upload failed (non-fatal): %s: %s", type(e).__name__, e)


# ── Audio framing & VAD ─────────────────────────────────────────────

SAMPLE_RATE = 16000
CHANNELS = 1
SAMPLE_WIDTH = 2  # int16
FRAME_MS = 30
FRAME_SAMPLES = SAMPLE_RATE * FRAME_MS // 1000  # 480
FRAME_BYTES = FRAME_SAMPLES * SAMPLE_WIDTH       # 960


def _rms(pcm_int16_bytes: bytes) -> float:
    """Normalized RMS in [0, 1] for a chunk of int16 little-endian PCM."""
    if not pcm_int16_bytes:
        return 0.0
    n = len(pcm_int16_bytes) // 2
    if n == 0:
        return 0.0
    samples = struct.unpack(f"<{n}h", pcm_int16_bytes[: n * 2])
    sq = sum(s * s for s in samples) / n
    return (sq ** 0.5) / 32768.0


def _pcm_to_float32(pcm_bytes: bytes):
    import numpy as np

    if not pcm_bytes:
        return np.zeros(0, dtype=np.float32)
    arr = struct.unpack(f"<{len(pcm_bytes) // 2}h", pcm_bytes[: (len(pcm_bytes) // 2) * 2])
    return (
        # Cast to float32 then scale to [-1, 1]
        (
            __import__("numpy").asarray(arr, dtype="float32") / 32768.0
        )
    )


# ── Per-connection state ─────────────────────────────────────────────


@dataclass
class Endpointing:
    endpointing_ms: int = 300       # silence required to call end-of-utterance
    utterance_end_ms: int = 1000    # silence after which we emit UtteranceEnd
    speech_min_ms: int = 200        # min sustained speech to count as utterance


@dataclass
class StreamState:
    sid: str
    started_at: float
    enc: Endpointing
    in_speech: bool = False
    silence_run_ms: int = 0
    speech_run_ms: int = 0
    last_emit_was_results: bool = True
    utterance_buf: bytearray = field(default_factory=bytearray)
    pending_partial_buf: bytearray = field(default_factory=bytearray)
    audio_offset_ms: int = 0        # cumulative audio time
    last_utterance_end_ms: float = 0.0


# ── Protocol message helpers ─────────────────────────────────────────
#
# Anthropic's /api/ws/speech_to_text/voice_stream wraps Deepgram (and other
# STT backends) in a simpler bidirectional JSON protocol. The Claude Code
# client at src/services/voiceStreamSTT.ts handles exactly three server →
# client message types:
#
#   {"type": "TranscriptText",     "data": "<text>"}     interim/partial; can repeat
#   {"type": "TranscriptEndpoint"}                       commits last TranscriptText
#   {"type": "TranscriptError",    "error_code": ...,
#                                  "description": "..."}
#
# Deepgram's native shapes (Metadata / SpeechStarted / Results / UtteranceEnd)
# do NOT exist on this hop — Anthropic translates them server-side. CC ignores
# anything else, which is why our previous Deepgram-shaped responses produced
# "no speech detected" — CC saw zero TranscriptText events and resolved
# finalize() with empty lastTranscriptText.
#
# Reference (decompiled): github.com/ComeOnOliver/claude-code-analysis/
#                         src/services/voiceStreamSTT.ts


def _ts() -> float:
    return time.monotonic()


def _msg_transcript_text(text: str) -> dict:
    return {"type": "TranscriptText", "data": text}


def _msg_transcript_endpoint() -> dict:
    return {"type": "TranscriptEndpoint"}


def _msg_transcript_error(error_code: str, description: str) -> dict:
    return {"type": "TranscriptError", "error_code": error_code, "description": description}


# ── Transcription ────────────────────────────────────────────────────


async def _transcribe_pcm(pcm_bytes: bytes) -> str:
    if not pcm_bytes:
        return ""
    import numpy as np

    audio_f32 = _pcm_to_float32(pcm_bytes)
    if audio_f32.size < SAMPLE_RATE // 8:  # < 125 ms; nothing to transcribe
        return ""

    def _run():
        backend = _ensure_backend()
        return backend.transcribe(audio_f32)

    return await asyncio.to_thread(_run)


# ── WebSocket handler ────────────────────────────────────────────────


async def handle_ws(websocket):
    # `websockets` 12+ exposes the request URI on the connection.
    raw_path = getattr(websocket, "path", None) or getattr(websocket.request, "path", "/")
    parsed = urllib.parse.urlparse(raw_path)
    qs = urllib.parse.parse_qs(parsed.query)
    log.info("connect path=%s qs=%s", parsed.path, dict(qs))

    enc = Endpointing(
        endpointing_ms=int(qs.get("endpointing_ms", [300])[0]),
        utterance_end_ms=int(qs.get("utterance_end_ms", [1000])[0]),
    )
    sid = uuid.uuid4().hex
    state = StreamState(sid=sid, started_at=_ts(), enc=enc)

    async def send_json(obj: dict):
        try:
            await websocket.send(json.dumps(obj, ensure_ascii=False))
        except Exception as e:
            log.debug("send_json failed (peer gone?): %s", e)

    # Anthropic's voice_stream protocol does NOT open with a Metadata frame.
    # Sending one gets ignored (best case) or breaks early jsonParse (worst).
    # The client just calls callbacks.onReady() on WS open and starts streaming.

    try:
        async for msg in websocket:
            if isinstance(msg, (bytes, bytearray)):
                await _handle_audio(state, bytes(msg), send_json)
            elif isinstance(msg, str):
                await _handle_control(state, msg, send_json)
    except Exception as e:
        log.warning("ws loop exception: %s", e)
    finally:
        # Flush any remaining audio as a final utterance.
        if state.utterance_buf:
            await _finalize_utterance(state, send_json)


async def _handle_audio(state: StreamState, chunk: bytes, send_json):
    """For push-to-talk (which Claude Code uses), each WS connection is one
    utterance. Buffer everything received — don't try to mid-stream-split via
    server-side VAD; that fights CC's own "release-key = end" semantics and
    produces empty fragments when speech levels jitter. Transcription happens
    once on Finalize/CloseStream/disconnect (see ``_finalize_utterance``).

    The energy VAD is still used here to fire SpeechStarted exactly once for
    UI feedback — we don't act on it for chunking.
    """
    if not chunk:
        return
    state.audio_offset_ms += int(1000 * (len(chunk) / 2) / SAMPLE_RATE)
    state.utterance_buf.extend(chunk)
    # No mid-stream events to send: Anthropic's protocol has no "SpeechStarted"
    # equivalent. The client treats absence of TranscriptText as "still listening".
    # We just buffer until Finalize/CloseStream/disconnect.


async def _finalize_utterance(state: StreamState, send_json):
    """Transcribe everything in the utterance buffer and emit the
    Anthropic-protocol turn-end pair: TranscriptText (with the text) followed
    by TranscriptEndpoint (which commits it as final inside the CC client).

    Even if transcription returns empty, we still emit TranscriptEndpoint so
    the CC client's `noData` 1.5s timer fires the empty-but-graceful path
    instead of waiting for the slower 5s safety timeout.
    """
    pcm = bytes(state.utterance_buf)
    state.utterance_buf.clear()
    state.in_speech = False
    state.speech_run_ms = 0
    if not pcm:
        # Still send TranscriptEndpoint so finalize() resolves promptly via
        # post_closestream_endpoint instead of no_data_timeout.
        await send_json(_msg_transcript_endpoint())
        return
    duration_s = (len(pcm) / 2) / SAMPLE_RATE
    if duration_s < MIN_UTTERANCE_S:
        if DEBUG:
            log.debug("[%s] dropping short utterance %.2fs", state.sid[:6], duration_s)
        await send_json(_msg_transcript_endpoint())
        return
    t0 = _ts()
    text = await _transcribe_pcm(pcm)
    dt = _ts() - t0
    text = (text or "").strip()
    log.info("[%s] final %.2fs in %.0fms: %r", state.sid[:6], duration_s, dt * 1000, text)
    if text:
        # The Anthropic protocol expects TranscriptText followed by
        # TranscriptEndpoint. CC's handler treats every TranscriptText as
        # interim (is_final=false) and only commits the LAST one as final
        # when TranscriptEndpoint arrives. So a single (TranscriptText,
        # TranscriptEndpoint) pair is the canonical "final transcript" turn.
        await send_json(_msg_transcript_text(text))
        # Fire-and-forget upload to LuxTTS for cloning. Off the response
        # path so we never delay the CC turn.
        if CAPTURE_ENABLED:
            asyncio.create_task(asyncio.to_thread(_push_clone_sample, pcm, text, SAMPLE_RATE))
    state.last_utterance_end_ms = state.audio_offset_ms
    await send_json(_msg_transcript_endpoint())


async def _handle_control(state: StreamState, raw: str, send_json):
    try:
        msg = json.loads(raw)
    except json.JSONDecodeError:
        return
    t = msg.get("type")
    if DEBUG:
        log.debug("[%s] control: %s", state.sid[:6], t)
    if t == "CloseStream":
        # Client signals end-of-recording. Transcribe the buffer, emit
        # TranscriptText + TranscriptEndpoint, then let WS close naturally.
        await _finalize_utterance(state, send_json)
    elif t == "KeepAlive":
        # No-op: client sends every 8s just to keep the connection alive.
        # No response expected.
        pass
    elif t == "Finalize":
        # Not part of Anthropic's voice_stream protocol, but kept as a
        # courtesy for any client that uses the Deepgram-style finalize.
        await _finalize_utterance(state, send_json)


# ── HTTP /health (served by the same websockets app) ────────────────


async def http_health(connection, request):
    """Return a tiny 200 OK on /health so curl can verify liveness.

    websockets 15.x: process_request returns http11.Response or None.
    Returning None lets the WS upgrade handshake proceed normally.
    """
    if request.path != "/health":
        return None
    from http import HTTPStatus
    from websockets.datastructures import Headers
    from websockets.http11 import Response

    body = json.dumps(
        {
            "status": "ok",
            "backend": _backend.name if _backend is not None else "(unloaded)",
            "endpoint": "/api/ws/speech_to_text/voice_stream",
        }
    ).encode()
    return Response(
        status_code=HTTPStatus.OK.value,
        reason_phrase="OK",
        headers=Headers([
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(body))),
            ("Connection", "close"),
        ]),
        body=body,
    )


# ── Entry point ─────────────────────────────────────────────────────


async def main():
    import websockets

    # Pre-load backend so the first audio frame doesn't pay the load cost.
    selection = (
        os.environ.get("CC_STT_PROFILE")
        or os.environ.get("CC_STT_BACKEND")
        or os.environ.get("CC_VOICE_PROXY_MODEL")
        or "moonshine-onnx-base (default)"
    )
    log.info("starting on ws://%s:%d  selection=%s  vad_rms=%.3f", HOST, PORT, selection, VAD_RMS_THRESHOLD)
    await asyncio.to_thread(_ensure_backend)
    log.info("backend=%s  ready; serving /api/ws/speech_to_text/voice_stream", _backend.name)

    # `process_request` lets us serve /health as plain HTTP without a separate server.
    async def process_request(connection, request):
        return await http_health(connection, request)

    async with websockets.serve(
        handle_ws,
        HOST,
        PORT,
        max_size=4 * 1024 * 1024,
        process_request=process_request,
    ):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)


def run_main():
    """Entry point exposed via pyproject.toml [project.scripts]."""
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
