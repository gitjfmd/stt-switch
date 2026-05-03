#!/bin/bash
# wire-cc-voice.sh — point Claude Code's voice mode at the local proxy.
#
# What this does (in order, all reversible by unwire-cc-voice.sh):
#   1. Copy the launchd plist into ~/Library/LaunchAgents/
#   2. launchctl load → starts cc-voice-proxy.py and keeps it alive
#   3. Wait for the proxy /health endpoint to return 200
#   4. Append `export VOICE_STREAM_BASE_URL=ws://127.0.0.1:8113` to ~/.zshrc
#      (idempotent: skipped if already present)
#   5. Print the final manual step: restart your claude session
#
# Nothing in ~/.claude/ is modified. The CC binary just reads the env var on
# startup; restart `claude` for the change to apply.
#
# Run: bash STT/bin/wire-cc-voice.sh
# Undo: bash STT/bin/unwire-cc-voice.sh

set -euo pipefail

STT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST_SRC="$STT_ROOT/etc/com.local.cc-voice-proxy.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.local.cc-voice-proxy.plist"
ZSHRC="$HOME/.zshrc"
EXPORT_LINE='export VOICE_STREAM_BASE_URL=ws://127.0.0.1:8113'
EXPORT_TAG='# >>> cc-voice-proxy (Claude Code → local STT) >>>'
EXPORT_END='# <<< cc-voice-proxy <<<'

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }

step() { printf '\n\033[1;36m▸\033[0m %s\n' "$*"; }

[ -f "$PLIST_SRC" ] || { red "missing $PLIST_SRC"; exit 1; }

step "1/5  Install launchd plist → $PLIST_DST"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
dim "(template stays at $PLIST_SRC; edit there + rerun wire script to change settings)"

step "2/5  launchctl load (starts the proxy now and on every login)"
# If a previous load is in place, unload first to pick up any plist changes.
launchctl unload -w "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"
launchctl list | grep -F com.local.cc-voice-proxy || true

step "3/5  Wait for /health to return 200"
ok=0
for i in {1..40}; do
  code=$(curl -s -o /dev/null -m 1 -w "%{http_code}" "http://127.0.0.1:8113/health" || true)
  if [ "$code" = "200" ]; then
    ok=1
    health=$(curl -s -m 2 "http://127.0.0.1:8113/health")
    green "  /health → $health"
    break
  fi
  sleep 0.5
done
if [ "$ok" != "1" ]; then
  red "  proxy never became healthy. Check /tmp/cc-voice-proxy.log:"
  tail -20 /tmp/cc-voice-proxy.log 2>/dev/null || true
  exit 2
fi

step "4/5  Add VOICE_STREAM_BASE_URL to $ZSHRC"
touch "$ZSHRC"
if grep -qF "$EXPORT_TAG" "$ZSHRC"; then
  yellow "  already wired in $ZSHRC (skipping)"
else
  cp "$ZSHRC" "$ZSHRC.bak.cc-voice-$(date +%Y%m%d_%H%M%S)"
  {
    printf '\n%s\n' "$EXPORT_TAG"
    printf '%s\n' "$EXPORT_LINE"
    printf '%s\n' "$EXPORT_END"
  } >> "$ZSHRC"
  green "  appended $EXPORT_LINE"
  dim "  backup at $ZSHRC.bak.cc-voice-*"
fi

step "5/5  Final step is yours"
cat <<'EOF'

  Open a new terminal (or `source ~/.zshrc`), then start Claude Code:

      source ~/.zshrc && claude

  In the claude session, hit /voice and speak.
  Watch the proxy log to confirm CC connected here, not Anthropic:

      tail -f /tmp/cc-voice-proxy.log

  Expected log lines on a /voice push:
      INFO [cc-voice-proxy] connect path=/api/ws/speech_to_text/voice_stream qs=...
      INFO [cc-voice-proxy] [<sid>] final 1.5s in 30ms: 'your spoken words'

  To revert:  bash STT/bin/unwire-cc-voice.sh

EOF

green "wired."
