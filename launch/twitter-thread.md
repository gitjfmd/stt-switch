# X / Twitter launch thread — paste-ready

**Audience:** AI tooling crowd, builders, devs on @x
**Voice:** SECSOLS (technical, no hype) — slightly more casual than LinkedIn
**Account:** `@jfmdid`
**Format:** 3-tweet thread (each ≤ 280 chars)

---

## TWEET 1 — hook (218 chars)

```
shipped: stt-switch — Claude Code voice mode, but local

your speech never leaves the Mac.
89 ms warm on M5 Max GPU (whisper-large-v3-turbo).
faster than the round-trip to Deepgram.
one env var to enable, one CLI to swap models.

github.com/gitjfmd/stt-switch
```

## TWEET 2 — the trick (276 chars)

```
turns out Claude Code already supports a VOICE_STREAM_BASE_URL env var. point it at a local proxy that speaks the same Anthropic voice_stream protocol (decoded from the leaked CC source) and audio stops going to api.anthropic.com → Deepgram. zero outbound on the happy path.
```

## TWEET 3 — the catalog (239 chars)

```
16 backends you can flip with one command:

stt-switch mlx-whisper-large-v3-turbo    # 89ms local GPU
stt-switch moonshine-onnx-tiny           # 17ms CPU
stt-switch mlx-chain                     # local + remote fallback

MIT, Apple Silicon. PRs welcome for Linux/CUDA.
```

---

## Optional reply tweets (only if engagement starts)

### REPLY A — for the privacy nerds

```
why do this when CC voice "just works"?

because audio is the most sensitive surface in your dev environment. every "fix the bug in auth.py", every "what's in production right now" — leaving the machine. with stt-switch the speech-to-text round-trip stays in RAM, on your Mac.
```

### REPLY B — for the latency nerds

```
89 ms is the median warm latency for whisper-large-v3-turbo via MLX on M5 Max for a 3-sec utterance. cold load is 1.1 s (one time). beat it with moonshine-onnx-tiny at 17 ms if you want raw speed and don't mind a smaller model.
```

### REPLY C — for the builders

```
i didn't have to write a Whisper port. mlx-whisper, moonshine-onnx, faster-whisper — all already exist and are great. stt-switch is the boring glue: WebSocket proxy + protocol translator + a backend registry. ~600 lines of python total.
```

---

## Posting checklist

- [ ] Logged into the right account (`@jfmdid`)
- [ ] Tweet 1 has the **GitHub link**; X will auto-attach the OG card
- [ ] Post tweets 2 + 3 as **replies in your own thread** (not stand-alone)
- [ ] Pin tweet 1 to profile
- [ ] After ~30 min, quote-tweet from a personal angle if engagement is below ~5 reposts (boosts impressions)
- [ ] Watch for early replies asking for Linux / Windows support — those are PR opportunities
