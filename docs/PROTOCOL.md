# Anthropic `voice_stream` protocol — notes

Claude Code's `/voice` mode opens a WebSocket to
`wss://api.anthropic.com/api/ws/speech_to_text/voice_stream`
(or whatever `VOICE_STREAM_BASE_URL` is set to). The wire protocol decoded
below is what `cc-voice-proxy` implements.

This is **not Deepgram's native protocol** — Anthropic wraps it in their own
simpler JSON shape. If you implement the standard Deepgram-Live message
types (`Metadata`, `SpeechStarted`, `Results`, `UtteranceEnd`), Claude Code
will silently ignore them and render "no speech detected".

## URL parameters

```
?encoding=linear16
&sample_rate=16000
&channels=1
&endpointing_ms=300
&utterance_end_ms=1000
&language=en
[ &use_conversation_engine=true  &stt_provider=deepgram-nova3 ]
[ &keyterms=…&keyterms=… ]
```

Bearer auth header is the user's Claude.ai OAuth access token; the proxy
in this repo accepts and ignores it.

## Server → client messages

```jsonc
// Interim or partial transcript. May be sent multiple times. Claude Code
// tracks the most recent one as "lastTranscriptText" until an Endpoint
// arrives, at which point it commits as the final transcript for the turn.
{ "type": "TranscriptText", "data": "your speech so far" }

// End-of-utterance marker. Triggers Claude Code to emit the last
// TranscriptText as final.
{ "type": "TranscriptEndpoint" }

// Recoverable error.
{ "type": "TranscriptError",
  "error_code": "...",
  "description": "..." }
```

That's the complete server-side surface used by the client at the time
of writing (Claude Code 2.1.x).

## Client → server messages

```jsonc
// Sent immediately on open and every ~8 s thereafter.
{ "type": "KeepAlive" }

// Sent when the user releases the push-to-talk key.
{ "type": "CloseStream" }
```

Plus binary frames containing 16-bit signed little-endian PCM at 16 kHz mono
(`linear16`).

## Client behavior

1. Open WebSocket.
2. Send `{"type":"KeepAlive"}` immediately.
3. On every audio buffer from the OS recorder, send a binary frame.
4. On every `TranscriptText`, update the live preview in the UI.
5. On `TranscriptEndpoint`, commit `lastTranscriptText` as the final transcript.
6. On user release / keybinding lift, send `{"type":"CloseStream"}` and wait
   up to ~1.5 s (`noData`) for any flushed `TranscriptEndpoint`. Else fall
   through to ~5 s (`safety`) timeout.
7. If `lastTranscriptText` is empty when the finalize promise resolves, show
   the **"no speech detected"** toast.

## "No speech detected" trigger

Three paths can produce this UI message:

1. The server never sent any `TranscriptText` with non-empty `data`.
2. The server sent `TranscriptText` events but with empty strings.
3. The connection closed before any `TranscriptEndpoint` and the safety
   timeout elapsed without intermediate transcript.

The proxy in this repo always emits a `TranscriptEndpoint` after every turn
(and a non-empty `TranscriptText` if transcription succeeded), so this
toast only appears if the audio truly was silent or the transcription
backend returned empty for the entire turn.

## Reference

The decoded handler lives at
[`src/services/voiceStreamSTT.ts`](https://github.com/ComeOnOliver/claude-code-analysis/blob/main/src/services/voiceStreamSTT.ts)
in the publicly available reverse-engineered Claude Code source.
