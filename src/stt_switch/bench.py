#!/usr/bin/env python3
"""stt-bench.py — apples-to-apples STT backend benchmark.

Runs the same audio file through one or more backends defined in
``STT/lib/backends.py`` and prints cold load + warm inference latency plus
the transcribed text.

Usage:
    stt-bench.py [AUDIO_PATH] [-p PROFILE [-p PROFILE ...]] [-n N]

Examples:
    # Default: every local profile against a built-in 3 s clip
    stt-bench.py

    # Specific profiles only
    stt-bench.py -p moonshine-onnx-base -p whisper-faster-large-v3

    # Custom audio + 5 warm runs each
    stt-bench.py /path/to/your.wav -n 5

The script is read-only and never writes to /etc, ~/.claude, or anything
mutable other than the HF model cache (under STT/models/.hf-cache).
"""

from __future__ import annotations

import argparse
import os
import statistics
import sys
import time
from pathlib import Path
from typing import Optional

# Locate STT/ tree relative to this file.
SCRIPT = Path(__file__).resolve()
STT_ROOT = SCRIPT.parent.parent
os.environ.setdefault("HF_HOME", str(STT_ROOT / "models" / ".hf-cache"))
os.environ.setdefault("HF_HUB_CACHE", str(STT_ROOT / "models" / ".hf-cache" / "hub"))


import numpy as np  # noqa: E402

from stt_switch.backends import PROFILES  # noqa: E402

# Default audio: prefer /tmp clips we use during dev; else require user-supplied.
DEFAULT_AUDIO_CANDIDATES = [
    "/tmp/lux-3s-16k-loud.wav",
    "/tmp/lux-3s-16k.wav",
    "/path/to/your/stt-tree/test-audio.wav",
]

# Profile groups
LOCAL_PROFILES = [
    "moonshine-onnx-tiny",
    "moonshine-onnx-base",
    "moonshine-stream-tiny",
    "moonshine-stream-medium",
    "whisper-faster-base",
    "whisper-faster-large-v3",
]
REMOTE_PROFILES = [
    "remote-speaches",
    "remote-moonshine",
]
DEFAULT_PROFILES = ["moonshine-onnx-base", "moonshine-stream-medium", "remote-speaches"]


def _load_audio(path: str) -> tuple[np.ndarray, int]:
    import soundfile as sf

    audio, sr = sf.read(path)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    return audio.astype("float32"), sr


def _bench_one(profile: str, audio: np.ndarray, n_warm: int) -> dict:
    if profile not in PROFILES:
        return {"profile": profile, "error": f"unknown profile (known: {sorted(PROFILES)})"}
    out: dict = {"profile": profile}
    try:
        t0 = time.monotonic()
        b = PROFILES[profile]()
        b.warmup()
        out["load_s"] = time.monotonic() - t0
        out["backend"] = b.name
    except Exception as e:
        out["error"] = f"warmup: {type(e).__name__}: {e}"
        return out

    times: list[float] = []
    transcripts: list[str] = []
    for _ in range(n_warm):
        try:
            t0 = time.monotonic()
            text = b.transcribe(audio)
            times.append((time.monotonic() - t0) * 1000)
            transcripts.append(text)
        except Exception as e:
            out["error"] = f"transcribe: {type(e).__name__}: {e}"
            break
    if times:
        out["infer_min_ms"] = min(times)
        out["infer_med_ms"] = statistics.median(times)
        out["infer_max_ms"] = max(times)
        out["text"] = transcripts[-1]
    return out


def _print_table(rows: list[dict]) -> None:
    cols = ["profile", "backend", "load_s", "infer_min_ms", "infer_med_ms", "infer_max_ms", "text", "error"]
    widths = {c: len(c) for c in cols}
    for r in rows:
        for c in cols:
            v = r.get(c, "")
            if isinstance(v, float):
                s = f"{v:.1f}" if c.endswith("_s") else f"{v:.0f}"
            else:
                s = str(v) if v else ""
            widths[c] = max(widths[c], min(80, len(s)))
    sep = "  "
    print(sep.join(c.ljust(widths[c]) for c in cols))
    print(sep.join("-" * widths[c] for c in cols))
    for r in rows:
        cells = []
        for c in cols:
            v = r.get(c, "")
            if isinstance(v, float):
                s = f"{v:.1f}" if c.endswith("_s") else f"{v:.0f}"
            else:
                s = str(v) if v else ""
            cells.append(s[:widths[c]].ljust(widths[c]))
        print(sep.join(cells))


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "audio", nargs="?",
        help=f"Audio file (default: first existing of {DEFAULT_AUDIO_CANDIDATES})",
    )
    parser.add_argument(
        "-p", "--profile", action="append", default=[],
        help="Profile to bench (repeatable). Use 'all' for everything, 'local' for local-only, 'remote' for remote-only.",
    )
    parser.add_argument("-n", "--n-warm", type=int, default=3, help="Warm runs per backend (default: 3)")
    args = parser.parse_args(argv)

    # Resolve audio
    audio_path = args.audio
    if not audio_path:
        for c in DEFAULT_AUDIO_CANDIDATES:
            if Path(c).exists():
                audio_path = c
                break
    if not audio_path or not Path(audio_path).exists():
        print(
            "error: no audio file. Pass one as the first arg or create one of "
            f"{DEFAULT_AUDIO_CANDIDATES}",
            file=sys.stderr,
        )
        return 2

    # Resolve profiles
    sel = args.profile or DEFAULT_PROFILES
    expanded: list[str] = []
    for p in sel:
        if p == "all":
            expanded.extend(PROFILES.keys())
        elif p == "local":
            expanded.extend(LOCAL_PROFILES)
        elif p == "remote":
            expanded.extend(REMOTE_PROFILES)
        else:
            expanded.append(p)
    profiles = list(dict.fromkeys(expanded))  # dedupe, preserve order

    audio, sr = _load_audio(audio_path)
    print(f"audio: {audio_path}  ({len(audio)/sr:.2f}s @ {sr} Hz)")
    print(f"warm runs per backend: {args.n_warm}")
    print()

    rows = []
    for p in profiles:
        print(f"benchmarking {p} ...", flush=True)
        rows.append(_bench_one(p, audio, args.n_warm))
    print()
    _print_table(rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
