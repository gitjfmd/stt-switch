# LinkedIn launch post — paste-ready

**Audience:** developers, security/privacy-minded engineers, AI tooling community
**Voice:** SECSOLS (security-first, technical, no hype)
**Length:** ~2400 chars including hashtags, fits LinkedIn post comfortably
**Author:** Junaid Farooq · `linkedin.com/in/jfmdid`

---

🔒 We just open-sourced something we built for ourselves: stt-switch.

The problem we hit: Claude Code's voice mode streams every utterance to api.anthropic.com → Deepgram. Both are great companies — but that's two third-parties hearing every command we give our coding agent. There's no in-product opt-out.

The fix turned out to be one env var. Claude Code's voice client honors VOICE_STREAM_BASE_URL — we just needed something on the other end of it.

stt-switch is that something. It's a local WebSocket proxy that:

→ Speaks Anthropic's voice_stream protocol (decoded from the publicly leaked Claude Code source — credit to the reverse-engineering community)

→ Transcribes locally via your choice of 16 backend profiles, including Whisper-large-v3-turbo on Apple Silicon GPU at 89 ms warm. That's faster than the network round-trip to Deepgram while running a state-of-the-art model.

→ Falls back gracefully (mlx-chain profile: local first, remote large-v3 fallback for tricky audio)

→ Swaps backends with one command: stt-switch mlx-whisper-large-v3-turbo

Measured on Apple M5 Max:
   moonshine-onnx-tiny           17 ms
   mlx-whisper-base-en           14 ms
   mlx-whisper-large-v3-turbo    89 ms   ← recommended
   remote (Tailscale + GPU)     ~200 ms (still beats Anthropic→Deepgram)

The repo: https://github.com/gitjfmd/stt-switch
MIT licensed. macOS / Apple Silicon. Open to PRs for Linux + GPU paths.

This is part of the SECSOLS thesis: AI infrastructure built privacy-first, not retrofitted after the fact. If you want autonomous agents in your toolchain, the audio side of the stack matters too.

#AppleSilicon #Privacy #LocalAI #ClaudeCode #MLX #OpenSource

---

## Posting checklist

- [ ] Logged into the right LinkedIn profile (`linkedin.com/in/jfmdid`)
- [ ] Set audience: **Anyone** (public)
- [ ] Pre-paste preview shows the GitHub link rendering as a card
- [ ] Optional: schedule for ~9 AM ET on a Tue/Wed/Thu (highest LinkedIn engagement window per recent reporting)
- [ ] After posting: pin to top of profile for 7 days
- [ ] After posting: cross-post to relevant LinkedIn groups (AI/ML, MCP, Apple developers)
