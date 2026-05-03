#!/bin/bash
# unwire-cc-voice.sh — undo wire-cc-voice.sh.
#
# 1. Remove the export from ~/.zshrc
# 2. launchctl unload + delete the plist
# 3. Print final step: restart claude so it stops using $VOICE_STREAM_BASE_URL
#
# After this, Claude Code voice goes back to api.anthropic.com → Deepgram.

set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/com.local.cc-voice-proxy.plist"
ZSHRC="$HOME/.zshrc"
EXPORT_TAG='# >>> cc-voice-proxy (Claude Code → local STT) >>>'
EXPORT_END='# <<< cc-voice-proxy <<<'

green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
dim()    { printf '\033[2m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1;36m▸\033[0m %s\n' "$*"; }

step "1/3  Stop and remove launchd agent"
if [ -f "$PLIST_DST" ]; then
  launchctl unload -w "$PLIST_DST" 2>/dev/null || true
  rm -f "$PLIST_DST"
  green "  removed $PLIST_DST"
else
  yellow "  plist already gone"
fi
# Final safety: kill anything still bound to 8113.
pid=$(lsof -t -i :8113 -P -n 2>/dev/null | head -1 || true)
if [ -n "${pid:-}" ]; then
  kill "$pid" 2>/dev/null || true
  dim "  killed lingering proxy PID $pid"
fi

step "2/3  Remove VOICE_STREAM_BASE_URL block from $ZSHRC"
if [ -f "$ZSHRC" ] && grep -qF "$EXPORT_TAG" "$ZSHRC"; then
  cp "$ZSHRC" "$ZSHRC.bak.cc-voice-unwire-$(date +%Y%m%d_%H%M%S)"
  # Delete the tagged block (BSD sed: in-place with empty backup)
  sed -i '' "/$EXPORT_TAG/,/$EXPORT_END/d" "$ZSHRC"
  green "  removed export block (backup saved)"
else
  yellow "  no cc-voice-proxy block in $ZSHRC"
fi

step "3/3  Final step is yours"
cat <<'EOF'

  Open a new terminal (or `source ~/.zshrc`), then restart Claude Code:

      source ~/.zshrc && claude

  Voice mode will go back to streaming through api.anthropic.com → Deepgram.

EOF
green "unwired."
