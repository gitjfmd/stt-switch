"""STT backend abstraction for stt-switch.

Used by the cc-voice-proxy WebSocket server and the stt-bench CLI. Each
backend implements ``warmup()`` and ``transcribe(audio_f32)``.

Selection (in priority order):
    1. CC_STT_PROFILE              named profile from ``PROFILES`` below
    2. CC_STT_BACKEND + per-backend env vars (custom configuration)

See the project README for the full profile catalog and measured latencies.

Remote profiles read their endpoint URL from env vars so the public defaults
do NOT bake in any private hostname. To enable a remote profile, set its
URL env var, then it becomes selectable via stt-switch.
"""

from __future__ import annotations

import io
import json
import logging
import mimetypes
import os
import ssl
import time
import urllib.error
import urllib.request
import uuid
from typing import Optional

import numpy as np

log = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────
# Base
# ─────────────────────────────────────────────────────────────────────


class STTBackend:
    """Synchronous STT interface. Run inside ``asyncio.to_thread`` from async code."""

    name: str = "stt-backend"
    sample_rate: int = 16000

    def warmup(self) -> None:
        """Optional: load model + run a tiny inference. Safe to no-op."""

    def transcribe(self, audio_f32: np.ndarray) -> str:
        """audio_f32: float32 1-D array @ self.sample_rate. Returns transcribed text."""
        raise NotImplementedError


# ─────────────────────────────────────────────────────────────────────
# moonshine-onnx — useful-moonshine-onnx (CPU on Mac, fastest by far)
# ─────────────────────────────────────────────────────────────────────


class MoonshineOnnxBackend(STTBackend):
    def __init__(self, model_name: str = "moonshine/base", use_coreml: bool = False):
        self.model_name = model_name
        self.use_coreml = use_coreml
        self.name = f"moonshine-onnx[{model_name}{',coreml' if use_coreml else ''}]"
        self._model = None
        self._tokenizer = None

    def warmup(self) -> None:
        import moonshine_onnx
        import onnxruntime

        log.info("[%s] loading...", self.name)
        t0 = time.monotonic()
        self._model = moonshine_onnx.MoonshineOnnxModel(model_name=self.model_name)

        if self.use_coreml and "CoreMLExecutionProvider" in onnxruntime.get_available_providers():
            enc_path = getattr(self._model.encoder, "_model_path", None)
            dec_path = getattr(self._model.decoder, "_model_path", None)
            if enc_path and dec_path:
                providers = [("CoreMLExecutionProvider", {"ModelFormat": "MLProgram"}), "CPUExecutionProvider"]
                self._model.encoder = onnxruntime.InferenceSession(enc_path, providers=providers)
                self._model.decoder = onnxruntime.InferenceSession(dec_path, providers=providers)

        self._tokenizer = moonshine_onnx.load_tokenizer()
        # Run a 1 s silence to JIT/compile
        try:
            self._model.generate(np.zeros(16000, dtype=np.float32)[None, :])
        except Exception:
            pass
        log.info("[%s] ready in %.1fs", self.name, time.monotonic() - t0)

    def transcribe(self, audio_f32: np.ndarray) -> str:
        out = self._model.generate(audio_f32[None, :])
        ids = out[0].tolist() if hasattr(out[0], "tolist") else out[0]
        try:
            return (self._tokenizer.decode_batch([ids])[0] or "").strip()
        except Exception:
            return (self._tokenizer.decode(ids) or "").strip()


# ─────────────────────────────────────────────────────────────────────
# moonshine-hf — HF transformers; the only path that loads streaming-* arch
# ─────────────────────────────────────────────────────────────────────


class MoonshineHfBackend(STTBackend):
    def __init__(
        self,
        model_name: str = "UsefulSensors/moonshine-base",
        device: str = "cpu",
        dtype: str = "float32",
    ):
        self.model_name = model_name
        self.device = device
        self.dtype = dtype
        self.name = f"moonshine-hf[{model_name},{device},{dtype}]"
        self._pipe = None

    def warmup(self) -> None:
        import torch
        from transformers import pipeline

        log.info("[%s] loading...", self.name)
        t0 = time.monotonic()
        torch_dtype = getattr(torch, self.dtype, torch.float32)
        self._pipe = pipeline(
            "automatic-speech-recognition",
            model=self.model_name,
            device=self.device,
            dtype=torch_dtype,
        )
        # Warm
        try:
            self._pipe({"array": np.zeros(self.sample_rate, dtype=np.float32), "sampling_rate": self.sample_rate})
        except Exception:
            pass
        log.info("[%s] ready in %.1fs", self.name, time.monotonic() - t0)

    def transcribe(self, audio_f32: np.ndarray) -> str:
        r = self._pipe({"array": audio_f32, "sampling_rate": self.sample_rate})
        return (r.get("text") or "").strip()


# ─────────────────────────────────────────────────────────────────────
# whisper-faster — faster-whisper (CTranslate2; CPU on Mac)
# ─────────────────────────────────────────────────────────────────────


class FasterWhisperBackend(STTBackend):
    def __init__(
        self,
        model: str = "base",
        device: str = "cpu",
        compute_type: str = "int8",
        language: Optional[str] = "en",
    ):
        self.model = model
        self.device = device
        self.compute_type = compute_type
        self.language = language
        self.name = f"whisper-faster[{model},{device},{compute_type}]"
        self._wm = None

    def warmup(self) -> None:
        from faster_whisper import WhisperModel

        log.info("[%s] loading...", self.name)
        t0 = time.monotonic()
        self._wm = WhisperModel(self.model, device=self.device, compute_type=self.compute_type)
        # Warm with 1 s of silence (pre-loaded model, just to compile any kernels)
        try:
            list(self._wm.transcribe(np.zeros(self.sample_rate, dtype=np.float32), language=self.language)[0])
        except Exception:
            pass
        log.info("[%s] ready in %.1fs", self.name, time.monotonic() - t0)

    def transcribe(self, audio_f32: np.ndarray) -> str:
        segments, _ = self._wm.transcribe(
            audio_f32,
            language=self.language,
            vad_filter=False,  # We already VAD upstream.
            beam_size=1,       # Greedy for latency. Bump to 5 for accuracy.
        )
        return " ".join(s.text for s in segments).strip()


# ─────────────────────────────────────────────────────────────────────
# remote-openai — POST to any OpenAI-compatible /v1/audio/transcriptions
# Used for: any compatible URL.
# ─────────────────────────────────────────────────────────────────────


class RemoteOpenAIBackend(STTBackend):
    def __init__(
        self,
        url: str,
        model_name: str = "",
        api_key: str = "",
        language: str = "en",
        timeout: float = 30.0,
    ):
        self.url = url
        self.model_name = model_name
        self.api_key = api_key
        self.language = language
        self.timeout = timeout
        self.name = f"remote-openai[{url} model={model_name or '(default)'}]"

    def warmup(self) -> None:
        # No model load locally; optionally probe the endpoint.
        try:
            req = urllib.request.Request(self.url.rsplit("/v1/", 1)[0] + "/health", method="GET")
            urllib.request.urlopen(req, timeout=3, context=_lax_ssl()).read()
            log.info("[%s] reachable", self.name)
        except Exception as e:
            log.warning("[%s] /health probe failed (%s); request will still attempt", self.name, e)

    def transcribe(self, audio_f32: np.ndarray) -> str:
        # Encode as 16 kHz int16 WAV in memory (smallest universally accepted format).
        import soundfile as sf

        buf = io.BytesIO()
        sf.write(buf, audio_f32, self.sample_rate, format="WAV", subtype="PCM_16")
        wav_bytes = buf.getvalue()

        # Build multipart manually so we don't pull in `requests`.
        boundary = uuid.uuid4().hex
        parts: list[bytes] = []
        if self.model_name:
            parts += [
                f"--{boundary}\r\n".encode(),
                b'Content-Disposition: form-data; name="model"\r\n\r\n',
                self.model_name.encode() + b"\r\n",
            ]
        if self.language:
            parts += [
                f"--{boundary}\r\n".encode(),
                b'Content-Disposition: form-data; name="language"\r\n\r\n',
                self.language.encode() + b"\r\n",
            ]
        parts += [
            f"--{boundary}\r\n".encode(),
            b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n',
            b"Content-Type: audio/wav\r\n\r\n",
            wav_bytes,
            b"\r\n",
            f"--{boundary}--\r\n".encode(),
        ]
        body = b"".join(parts)
        headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        req = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout, context=_lax_ssl()) as r:
                payload = r.read()
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"remote STT HTTP {e.code}: {e.read()[:200]!r}") from None
        try:
            d = json.loads(payload)
        except json.JSONDecodeError:
            return payload.decode("utf-8", "replace").strip()
        return (d.get("text") or d.get("transcript") or "").strip()


def _lax_ssl():
    """Accept self-signed certs (useful for our LuxTTS + dev services)."""
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


# ─────────────────────────────────────────────────────────────────────
# mlx-whisper — Apple MLX runtime, runs on the M-series GPU + Neural Engine
# ─────────────────────────────────────────────────────────────────────


class MlxWhisperBackend(STTBackend):
    """Whisper via mlx-whisper (Apple Silicon native, GPU-accelerated).

    On M5 Max measured 2026-05-02:
        whisper-large-v3-turbo: ~164 ms warm for 3s audio (best balance)
        whisper-large-v3      : ~223 ms warm for 3s audio (full quality)

    Both massively beat the network round-trip to the remote host for
    accuracy-equivalent transcription. Zero outbound traffic.
    """

    def __init__(
        self,
        repo: str = "mlx-community/whisper-large-v3-turbo",
        language: Optional[str] = "en",
        word_timestamps: bool = False,
    ):
        self.repo = repo
        self.language = language
        self.word_timestamps = word_timestamps
        self.name = f"mlx-whisper[{repo}]"

    def warmup(self) -> None:
        import mlx_whisper

        log.info("[%s] loading + warming...", self.name)
        t0 = time.monotonic()
        # First call pulls the model (cached after) and runs JIT compilation.
        try:
            mlx_whisper.transcribe(
                np.zeros(self.sample_rate, dtype=np.float32),
                path_or_hf_repo=self.repo,
                language=self.language,
                word_timestamps=self.word_timestamps,
                fp16=True,
                verbose=False,
            )
        except TypeError:
            # Older signatures
            mlx_whisper.transcribe(
                np.zeros(self.sample_rate, dtype=np.float32),
                path_or_hf_repo=self.repo,
            )
        log.info("[%s] ready in %.1fs", self.name, time.monotonic() - t0)

    def transcribe(self, audio_f32: np.ndarray) -> str:
        import mlx_whisper

        try:
            r = mlx_whisper.transcribe(
                audio_f32,
                path_or_hf_repo=self.repo,
                language=self.language,
                word_timestamps=self.word_timestamps,
                fp16=True,
                verbose=False,
            )
        except TypeError:
            r = mlx_whisper.transcribe(audio_f32, path_or_hf_repo=self.repo)
        return (r.get("text") or "").strip()


# ─────────────────────────────────────────────────────────────────────
# fallback — try primary; on empty/error, transcribe again with fallback
# ─────────────────────────────────────────────────────────────────────


class FallbackBackend(STTBackend):
    """Cascade two backends. Useful when primary is fast-but-flaky and
    fallback is slow-but-reliable. Latency on the fast path = primary;
    on the empty/error path = primary_timeout + fallback."""

    def __init__(self, primary: STTBackend, fallback: STTBackend):
        self.primary = primary
        self.fallback = fallback
        self.name = f"chain[{primary.name} → {fallback.name}]"

    def warmup(self) -> None:
        try:
            self.primary.warmup()
        except Exception as e:
            log.warning("[%s] primary warmup failed: %s", self.name, e)
        try:
            self.fallback.warmup()
        except Exception as e:
            log.warning("[%s] fallback warmup failed: %s", self.name, e)

    def transcribe(self, audio_f32: np.ndarray) -> str:
        try:
            text = self.primary.transcribe(audio_f32)
            if text and text.strip():
                return text
            log.info("[%s] primary returned empty; using fallback", self.name)
        except Exception as e:
            log.warning("[%s] primary failed (%s); using fallback", self.name, e)
        return self.fallback.transcribe(audio_f32)


# ─────────────────────────────────────────────────────────────────────
# Profile registry — high-level "named" choices
# ─────────────────────────────────────────────────────────────────────


# Helpers for remote endpoints — never hardcoded; read from env at call time.
def _remote_speaches_url() -> str:
    """Speaches base URL (HTTP).

    Set ``STT_SWITCH_REMOTE_SPEACHES_URL`` to enable remote-* / *-chain
    profiles that use Speaches (faster-whisper + Kokoro).
    Example: ``STT_SWITCH_REMOTE_SPEACHES_URL=http://10.0.0.5:31111``.
    """
    base = os.environ.get("STT_SWITCH_REMOTE_SPEACHES_URL", "").rstrip("/")
    if not base:
        raise RuntimeError(
            "Set STT_SWITCH_REMOTE_SPEACHES_URL to use this profile, "
            "e.g. http://your-host:31111"
        )
    return base + "/v1/audio/transcriptions"


def _remote_moonshine_url() -> str:
    """Moonshine STT base URL (HTTP).

    Set ``STT_SWITCH_REMOTE_MOONSHINE_URL`` to enable remote-moonshine and
    remote-chain. Example: ``http://your-host:31112``.
    """
    base = os.environ.get("STT_SWITCH_REMOTE_MOONSHINE_URL", "").rstrip("/")
    if not base:
        raise RuntimeError(
            "Set STT_SWITCH_REMOTE_MOONSHINE_URL to use this profile, "
            "e.g. http://your-host:31112"
        )
    return base + "/v1/audio/transcriptions"


PROFILES: dict[str, callable] = {
    # ── Local Mac, CPU — fast path ───────────────────────────────────────
    "moonshine-onnx-base": lambda: MoonshineOnnxBackend("moonshine/base"),
    "moonshine-onnx-tiny": lambda: MoonshineOnnxBackend("moonshine/tiny"),

    # ── Local Mac, HF transformers (only path that loads streaming-*) ──
    "moonshine-stream-tiny": lambda: MoonshineHfBackend("UsefulSensors/moonshine-streaming-tiny"),
    "moonshine-stream-medium": lambda: MoonshineHfBackend("UsefulSensors/moonshine-streaming-medium"),
    "moonshine-hf-base": lambda: MoonshineHfBackend("UsefulSensors/moonshine-base"),

    # ── Local Mac, faster-whisper (CTranslate2 — CPU on Mac) ────────────
    "whisper-faster-large-v3": lambda: FasterWhisperBackend("large-v3", device="cpu", compute_type="int8"),
    "whisper-faster-base":     lambda: FasterWhisperBackend("base",     device="cpu", compute_type="int8"),

    # ── Local Mac, MLX (Apple GPU + ANE; M-series Macs only) ────────────
    "mlx-whisper-large-v3-turbo":  lambda: MlxWhisperBackend("mlx-community/whisper-large-v3-turbo"),
    "mlx-whisper-large-v3":        lambda: MlxWhisperBackend("mlx-community/whisper-large-v3-mlx"),
    "mlx-whisper-medium":          lambda: MlxWhisperBackend("mlx-community/whisper-medium-mlx"),
    "mlx-whisper-medium-en":       lambda: MlxWhisperBackend("mlx-community/whisper-medium.en-mlx"),
    "mlx-whisper-small-en":        lambda: MlxWhisperBackend("mlx-community/whisper-small.en-mlx"),
    "mlx-whisper-base-en":         lambda: MlxWhisperBackend("mlx-community/whisper-base.en-mlx"),
    "mlx-whisper-tiny-en":         lambda: MlxWhisperBackend("mlx-community/whisper-tiny.en-mlx"),
    "mlx-whisper-distil-large-v3": lambda: MlxWhisperBackend("mlx-community/distil-whisper-large-v3"),

    # ── Remote endpoints (require env vars to enable) ───────────────────
    # `remote-*` historical names are kept for backward compat with the
    # 
    # 
    "remote-speaches": lambda: RemoteOpenAIBackend(
        url=_remote_speaches_url(),
        model_name="Systran/faster-whisper-large-v3",
    ),
    "remote-moonshine": lambda: RemoteOpenAIBackend(
        url=_remote_moonshine_url(),
        model_name="moonshine-streaming-medium",
    ),

    # ── Chains ──────────────────────────────────────────────────────────
    # Remote-only cascade: Moonshine streaming-medium on a GPU-backed
    # endpoint → faster-whisper-large-v3 fallback. Both URLs come from env.
    "remote-chain": lambda: FallbackBackend(
        primary=RemoteOpenAIBackend(
            url=_remote_moonshine_url(),
            model_name="moonshine-streaming-medium",
        ),
        fallback=RemoteOpenAIBackend(
            url=_remote_speaches_url(),
            model_name="Systran/faster-whisper-large-v3",
        ),
    ),
    # Privacy-best cascade: MLX whisper-large-v3-turbo on this Mac's GPU
    # (zero outbound traffic) → on empty/error, fall back to a remote
    # large-v3 if STT_SWITCH_REMOTE_SPEACHES_URL is configured.
    "mlx-chain": lambda: FallbackBackend(
        primary=MlxWhisperBackend("mlx-community/whisper-large-v3-turbo"),
        fallback=RemoteOpenAIBackend(
            url=_remote_speaches_url(),
            model_name="Systran/faster-whisper-large-v3",
        ),
    ),
}


def make_backend_from_env() -> STTBackend:
    """Resolve the configured backend from environment variables.

    Priority:
        CC_STT_PROFILE       (named profile in PROFILES)  -- recommended
        CC_STT_BACKEND       (raw backend type) + per-backend env
        legacy: CC_VOICE_PROXY_MODEL=moonshine/* → moonshine-onnx[...] for back-compat.
    """
    profile = os.environ.get("CC_STT_PROFILE", "").strip()
    if profile:
        if profile not in PROFILES:
            raise ValueError(f"Unknown CC_STT_PROFILE={profile!r}. Known: {sorted(PROFILES)}")
        return PROFILES[profile]()

    backend = os.environ.get("CC_STT_BACKEND", "").strip()
    if not backend:
        # Back-compat: honor the original CC_VOICE_PROXY_MODEL env if set.
        legacy = os.environ.get("CC_VOICE_PROXY_MODEL", "").strip()
        if legacy.startswith("moonshine/"):
            return MoonshineOnnxBackend(legacy)
        # Default
        return PROFILES["moonshine-onnx-base"]()

    if backend == "moonshine-onnx":
        return MoonshineOnnxBackend(
            model_name=os.environ.get("CC_STT_MOONSHINE_ONNX_MODEL", "moonshine/base"),
            use_coreml=os.environ.get("CC_STT_MOONSHINE_ONNX_COREML", "0") in ("1", "true"),
        )
    if backend == "moonshine-hf":
        return MoonshineHfBackend(
            model_name=os.environ.get("CC_STT_MOONSHINE_HF_MODEL", "UsefulSensors/moonshine-base"),
            device=os.environ.get("CC_STT_MOONSHINE_HF_DEVICE", "cpu"),
            dtype=os.environ.get("CC_STT_MOONSHINE_HF_DTYPE", "float32"),
        )
    if backend == "whisper-faster":
        return FasterWhisperBackend(
            model=os.environ.get("CC_STT_WHISPER_MODEL", "base"),
            device=os.environ.get("CC_STT_WHISPER_DEVICE", "cpu"),
            compute_type=os.environ.get("CC_STT_WHISPER_COMPUTE", "int8"),
            language=os.environ.get("CC_STT_WHISPER_LANG", "en"),
        )
    if backend == "remote-openai":
        url = os.environ.get("CC_STT_REMOTE_URL", "")
        if not url:
            raise ValueError("CC_STT_BACKEND=remote-openai requires CC_STT_REMOTE_URL")
        return RemoteOpenAIBackend(
            url=url,
            model_name=os.environ.get("CC_STT_REMOTE_MODEL", ""),
            api_key=os.environ.get("CC_STT_REMOTE_API_KEY", ""),
            language=os.environ.get("CC_STT_REMOTE_LANG", "en"),
        )
    raise ValueError(f"Unknown CC_STT_BACKEND={backend!r}")
