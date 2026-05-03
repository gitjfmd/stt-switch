# stt-switch

**Route Claude Code voice mode to a local speech-to-text engine of your choice.**
Apple Silicon native. Zero outbound traffic on the happy path. Drop-in replacement for `api.anthropic.com → Deepgram`.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-blue)
![Python](https://img.shields.io/badge/Python-3.10%2B-3776ab)

```
                              [ Claude Code ]
                                    │  /voice  hold Space
                                    │  16 kHz linear16 PCM
                                    ▼
        ┌──────────────────────────────────────────────────────┐
        │   ws://127.0.0.1:8113   cc-voice-proxy (this repo)   │
        │                                                      │
        │   • Speaks Anthropic's voice_stream protocol         │
        │   • Pluggable backend selected by env var            │
        │   • Optional fallback chain for accuracy             │
        └──────────────────────────────────────────────────────┘
                                    │
            ┌───────────────────────┼───────────────────────────┐
            ▼                       ▼                           ▼
   mlx-whisper (Apple GPU)   moonshine (CPU)            remote (OpenAI-compat)
       ~89 ms warm             ~30 ms warm               ~200 ms (network)
```

## Why

Claude Code's `/voice` mode streams audio over WebSocket to `api.anthropic.com/api/ws/speech_to_text/voice_stream`, which forwards it to **Deepgram**. Audio crosses the public internet and is processed by two third-parties before you see the transcript. There's no in-product opt-out.

`stt-switch` flips a single env var (`VOICE_STREAM_BASE_URL`) at the Claude Code binary so that voice traffic instead goes to a local WebSocket proxy on `127.0.0.1`. The proxy speaks the same protocol Claude Code's client expects, then transcribes locally (or via a server you control) and hands the text back. **Audio never leaves your Mac unless you explicitly route a fallback to a remote endpoint.**

## Quick start

```sh
# 1. Install (any one of: full, mlx-only, all-local, ...)
pip install "stt-switch[mlx,moonshine]"

# 2. Wire it up (writes a launchd plist + appends an export to ~/.zshrc)
stt-switch wire

# 3. Pick a backend
stt-switch mlx-whisper-large-v3-turbo

# 4. Open a NEW terminal so the env var is picked up, then:
claude

# 5. /voice as usual. Audio stays on this Mac.
```

To revert any time:
```sh
stt-switch unwire
```

## Profile catalog (measured on Apple M5 Max, 48 GB RAM, 3-second clip)

| Profile | Backend | Warm latency | Cold load | Where |
|---|---|---:|---:|---|
| `mlx-whisper-tiny-en` | MLX whisper-tiny.en | **11–22 ms** | 17 s¹ | Apple GPU |
| `mlx-whisper-base-en` | MLX whisper-base.en | **14–15 ms** | 13 s¹ | Apple GPU |
| `moonshine-onnx-tiny` | useful-moonshine-onnx tiny | 16–18 ms | 1.4 s | Mac CPU |
| `moonshine-onnx-base` | useful-moonshine-onnx base | 29–33 ms | 0.8 s | Mac CPU |
| `mlx-whisper-small-en` | MLX whisper-small.en | 39–40 ms | 35 s¹ | Apple GPU |
| `moonshine-stream-tiny` | HF transformers tiny stream | 73–74 ms | 7.7 s | Mac CPU |
| `mlx-whisper-medium-en` | MLX whisper-medium.en | 86–95 ms | 166 s¹ | Apple GPU |
| `mlx-whisper-distil-large-v3` | MLX distil-whisper-large-v3 | 88–98 ms | 153 s¹ | Apple GPU |
| **`mlx-whisper-large-v3-turbo`** | **MLX whisper-large-v3-turbo** | **88–90 ms** | **1.1 s** | Apple GPU |
| **`mlx-chain`** *(recommended)* | turbo → remote large-v3 fallback | **91–94 ms** | 1 s | Local + (remote) |
| `mlx-whisper-large-v3` | MLX whisper-large-v3 | 141–149 ms | 1.6 s | Apple GPU |
| `whisper-faster-base` | faster-whisper base int8 | ~200 ms | 18 s¹ | Mac CPU |
| `moonshine-stream-medium` | HF transformers medium stream | 278–286 ms | 5.8 s | Mac CPU |
| `whisper-faster-large-v3` | faster-whisper large-v3 int8 | ~4500 ms | 194 s¹ | Mac CPU |
| `remote-moonshine` | OpenAI-compat remote (requires env) | ~200 ms² | 0 s | network |
| `remote-speaches` | OpenAI-compat remote (requires env) | ~410 ms² | 0 s | network |
| `remote-chain` | remote-moonshine → remote-speaches | ~190 ms² | 0 s | network |

¹ First-time load includes downloading the model weights. Subsequent loads use the local cache and are sub-second.
² Depends on your remote host. Numbers shown were measured against a CUDA 12.6 + RTX 3090 server over Tailscale.

**Recommended default: `mlx-chain`.** Local MLX `whisper-large-v3-turbo` on the happy path (~89 ms, no network), automatically falls back to a remote `large-v3` if local returns empty. Best latency–accuracy–privacy balance.

## Installation

### From PyPI (when published)

```sh
pip install "stt-switch[mlx,moonshine]"      # most users
pip install "stt-switch[all]"                # every backend
pip install "stt-switch[mlx]"                # MLX only (smallest install)
```

### From source

```sh
git clone https://github.com/jfmd/stt-switch.git
cd stt-switch
pip install -e ".[all]"
```

### System dependencies

- **macOS** with Apple Silicon (M1 / M2 / M3 / M4 / M5)
- **espeak-ng** (only if using the `kokoro_tts`-related profiles): `brew install espeak-ng`
- **ffmpeg** for audio conversion: `brew install ffmpeg`

## CLI

```
stt-switch                              # interactive picker (current marked)
stt-switch list                         # show every profile
stt-switch current                      # show what's running now
stt-switch <profile>                    # set + reload
stt-switch reload                       # reload without changing profile
stt-switch bench                        # latency comparison across the catalog
stt-switch wire                         # install + start the proxy, route CC to it
stt-switch unwire                       # full revert
```

## How it works

`cc-voice-proxy` is a small WebSocket server on `127.0.0.1:8113` that implements the **Anthropic `voice_stream` protocol** Claude Code uses internally:

```
Client → Server:                    Server → Client:
  binary linear16 PCM                 {"type":"TranscriptText",  "data":"..."}
  {"type":"KeepAlive"}                {"type":"TranscriptEndpoint"}
  {"type":"CloseStream"}              {"type":"TranscriptError", "error_code":..., "description":...}
```

When `VOICE_STREAM_BASE_URL=ws://127.0.0.1:8113` is set in the shell that launches `claude`, the binary connects here instead of `wss://api.anthropic.com`. Authentication is unchanged (the proxy ignores the OAuth bearer; Claude Code still writes it).

The proxy buffers all audio for the duration of a `/voice` press, transcribes once on `CloseStream`, and emits `TranscriptText` + `TranscriptEndpoint` so Claude Code's UI commits the transcript exactly as it would from the cloud path.

See [`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the protocol notes (decoded from publicly leaked Claude Code source).

## Backends

| Engine | What | When to use |
|---|---|---|
| **MLX-Whisper** | Apple's MLX framework + Whisper | Best latency on Apple Silicon |
| **Moonshine** | UsefulSensors Moonshine ASR (ONNX or HF) | Tiny models, CPU-friendly |
| **faster-whisper** | CTranslate2-quantized Whisper | Cross-platform CPU baseline |
| **remote OpenAI-compatible** | Any server with `/v1/audio/transcriptions` | Speaches, OpenAI, your own deployment |

You can configure your own remote endpoint:

```sh
export STT_SWITCH_REMOTE_SPEACHES_URL=http://your-host:31111
export STT_SWITCH_REMOTE_MOONSHINE_URL=http://your-host:31112
stt-switch remote-chain
```

## Optional: voice-clone capture

When the proxy gets a non-empty transcript with sane duration (3–30 s by default), it can fire-and-forget the audio + transcript to a [LuxTTS](https://github.com/ysharma3501/LuxTTS) server you run, building a voice clone library automatically as you use Claude Code voice mode.

Enable by setting:
```sh
export STT_SWITCH_LUXTTS_URL=https://your-luxtts:17860
```

Disable with `export STT_SWITCH_CAPTURE_ENABLED=0`.

## Privacy posture

- **Default profiles**: zero outbound network. All transcription happens on your Mac.
- **Remote profiles**: only enabled if you set the corresponding `STT_SWITCH_REMOTE_*_URL` env var. The repo ships no IPs or hostnames.
- **Clone capture**: opt-in. Off if `STT_SWITCH_LUXTTS_URL` is not set.
- **Audio never lands on disk** unless you explicitly enable capture-to-LuxTTS, in which case it's posted to your own server.
- **The proxy binds `127.0.0.1` only.** Loopback bind keeps macOS firewall and Tailscale ACLs out of the picture.

## Caveats

- **Apple Silicon required for MLX backends.** Intel Macs can use Moonshine ONNX or faster-whisper-cpu.
- **macOS only for the launchd integration.** The proxy itself is plain Python and would run on Linux too; the wire/unwire scripts use `launchctl` and `~/Library/LaunchAgents/`. PRs for a systemd-user variant welcome.
- **First model load can be slow** (several seconds to several minutes for downloading large MLX weights). After the first load, models are cached under `~/.cache/huggingface/`.
- **Some MLX checkpoints occasionally mishear letter-acronyms** ("STT" → "ETS" / "ATS"). The chain profiles fall back to a stronger model on empty transcripts, but acronym errors aren't "empty" — they're just less accurate. Use `mlx-whisper-large-v3` or `remote-speaches` if absolute accuracy matters more than latency.
- **Claude Code voice mode is gated by feature flags in the Anthropic build.** This project doesn't change that gating; it just redirects the destination of audio that the binary was already going to send.
- **Restart `claude` after switching profiles** isn't necessary — the proxy is one process and swap takes effect immediately. Switching the *env var* (e.g., from cloud to local) does require a new `claude` process to pick it up, since CC reads `VOICE_STREAM_BASE_URL` once at startup.
- **No legal opinion offered.** Claude Code's terms of service govern your use; consult them if uncertain.

## Credits / prior art

- **Anthropic** — for shipping Claude Code with a single `VOICE_STREAM_BASE_URL` env-var override that makes this entire project possible.
- **[useful-moonshine-onnx](https://github.com/usefulsensors/moonshine)** — UsefulSensors' Moonshine ASR models in ONNX form.
- **[Speaches](https://github.com/speaches-ai/speaches)** — OpenAI-compatible STT/TTS server (used as one of the optional remote backends).
- **[mlx-whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper)** — Apple's MLX port of Whisper.
- **[faster-whisper](https://github.com/SYSTRAN/faster-whisper)** — CTranslate2-quantized Whisper.
- **Claude Code reverse-engineering community** ([1](https://github.com/ComeOnOliver/claude-code-analysis), [2](https://github.com/ruvnet/open-claude-code), [3](https://github.com/Yuyz0112/claude-code-reverse)) — for decoding the `voice_stream` protocol from the publicly distributed binary and source maps. The protocol implementation in this repo is built on their work.

## License

MIT. See [LICENSE](LICENSE).
