#!/usr/bin/env bash
# test-agent-commit-identity.sh — one runnable check for scripts/agent-commit-identity.sh.
# Every path must print its identity AND exit 0; a non-zero exit here is the P0 the hook must
# never cause. Run: bash scripts/test-agent-commit-identity.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/agent-commit-identity.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# NOTE: HOME is deliberately NOT overridden — gh's credentials live under it, and moving it
# makes every lookup fail, which silently turns the whole suite into the fail-safe path.
# Only the "no gh / no network" case moves HOME, which is exactly what that case wants.
fails=0

# ident <dir> <path-prefix-for-PATH-shadow> — source the lib in a FRESH bash process and
# print "<committer>|<email>|<trailer>" (trailer may contain newlines).
#
# A fresh `bash -c` is required, not a `( ... )` subshell: the omp ancestry fallback
# resolves `ps`/`lsof`, and some harnesses provide those as shell builtins that would
# shadow a PATH stub. A new bash process resolves them from PATH like any other program.
ident() {
  local dir="$1" shadow="${2:-}"
  local p="$PATH"
  [ -n "$shadow" ] && p="$shadow:$PATH"
  PATH="$p" bash -c '
    set -uo pipefail
    . "$1" "$2" >/dev/null 2>&1
    printf "%s|%s|%s" "${AGENT_COMMITTER_NAME:-}" "${AGENT_COMMITTER_EMAIL:-}" "${AGENT_TRAILER:-}"
  ' _ "$LIB" "$dir"
}

# probe <label> <expect-who|-> <dir> [path-shadow]
probe() {
  local label="$1" expect="$2" dir="$3" shadow="${4:-}" out rc
  out="$(ident "$dir" "$shadow")"
  rc=$?
  local who="${out%%/*}"; [ "$out" = "||" ] && who="-"
  printf '%-28s rc=%d  %s\n' "$label" "$rc" "${out:-<empty>}"
  [ "$rc" -eq 0 ] || { echo "  FAIL: nonzero exit"; fails=$((fails+1)); }
  [ "$who" = "$expect" ] || { echo "  FAIL: expected who=$expect got=$who"; fails=$((fails+1)); }
}

mkrepo() { # mkrepo <dir> [remote-url]
  mkdir -p "$1"; git -C "$1" init -q 2>/dev/null
  [ -n "${2:-}" ] && git -C "$1" remote add origin "$2"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
}

# A `ps` shadow that reports NO omp ancestor. The omp ancestry fallback walks the
# real process tree, so a suite run from inside an omp session would otherwise
# resolve an omp identity for paths that must resolve none. Shadowing `ps` makes
# the "no omp ancestor" case deterministic wherever the suite runs.
NOSTUB="$TMP/nostub"; mkdir -p "$NOSTUB"
cat > "$NOSTUB/ps" <<'STUBEOF'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    args=) echo "/usr/bin/some-other-daemon"; exit 0 ;;
    ppid=) echo "1"; exit 0 ;;
  esac
done
exit 0
STUBEOF
chmod +x "$NOSTUB/ps"

export AGENT_CLI=claude AGENT_SESSION=3f9a1b2c-dead-beef

mkrepo "$TMP/private" "https://github.com/gitjfmd/central-command.git"
mkrepo "$TMP/pubfork" "https://github.com/gitjfmd/oh-my-pi.git"      # public FORK (not CEO-authored)
mkrepo "$TMP/pubown"  "https://github.com/gitjfmd/stt-switch.git"    # public, CEO-authored (isFork=false)
mkrepo "$TMP/noremote"
mkrepo "$TMP/weird"   "https://gitlab.example.com/x/y.git"

probe "private repo"        claude "$TMP/private"
probe "public FORK"         agent  "$TMP/pubfork"
probe "public CEO-authored" agent  "$TMP/pubown"
probe "no remote"           agent  "$TMP/noremote"
probe "unknown host remote" agent  "$TMP/weird"

# no network / no gh: no gh on PATH + a virgin cache => lookup impossible => fail safe to public.
( PATH=/usr/bin:/bin; HOME="$TMP/home"; mkdir -p "$HOME"; export PATH HOME
  . "$LIB" "$TMP/private" >/dev/null 2>&1
  printf '%-28s rc=%d  %s\n' "no gh / no network" $? "${AGENT_COMMITTER_NAME:-<empty>}"
  case "${AGENT_COMMITTER_NAME:-}" in agent/*) ;; *) echo "  FAIL: expected neutral"; exit 9 ;; esac )
[ $? -eq 0 ] || fails=$((fails+1))

# detached HEAD + worktree still resolve (toplevel/remote are independent of HEAD state)
git -C "$TMP/private" checkout -q --detach 2>/dev/null
probe "detached HEAD"       claude "$TMP/private"
git -C "$TMP/private" worktree add -q "$TMP/wt" -b wtb 2>/dev/null
probe "linked worktree"     claude "$TMP/wt"

# a human commit (no AGENT_* env) must stay completely untouched.
# The `ps` shadow hides any real omp ancestor so the case is deterministic.
( unset AGENT_CLI AGENT_SESSION AGENT_MODEL AGENT PI_SESSION_ID PI_SESSION_FILE
  out="$(PATH="$NOSTUB:$PATH" bash -c '
    set -uo pipefail
    . "$1" "$2" >/dev/null 2>&1
    printf "%s" "${AGENT_TRAILER:-}"
  ' _ "$LIB" "$TMP/private")"
  rc=$?
  printf '%-28s rc=%d  %s\n' "human (no AGENT_* env)" "$rc" "${out:-<empty>}"
  [ "$rc" -eq 0 ] && [ -z "$out" ] ) || fails=$((fails+1))

# ==============================================================================
# omp fallbacks (measured 2026-11-15, jfmd-mc-pro)
# The omp CLI is launched BARE — it never runs through _otel-cli-wrapper — so it
# exports no AGENT_CLI/AGENT_SESSION and used to stamp as a human. Two fallbacks
# recover it: (a) the env contract AGENT=1 + PI_SESSION_*, (b) process-ancestry
# discovery for commits whose worker env carries no markers at all.
# ==============================================================================

# --- (a) omp env fallback ------------------------------------------------------
# A fake omp session jsonl under a temp */.omp/agent/sessions/ path. The model
# comes from the LAST line-start-anchored model_change record.
OMP_DIR="$TMP/omp-home/.omp/agent/sessions"
mkdir -p "$OMP_DIR"
OMP_SESSION="$OMP_DIR/20261115T120000_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
cat > "$OMP_SESSION" <<'JSONL'
{"type":"session_start","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}
{"type":"model_change","model":"vendor/Model-X"}
{"type":"message","text":"quoted {\"type\":\"model_change\",\"model\":\"NOT-A-REAL-MODEL\"} inside a transcript"}
{"type":"model_change","model":"vendor/Model-Last"}
JSONL

# omp_env <label> <expect-trailer-empty|-> <session-file> — run the lib in a fresh
# bash with ONLY the omp env contract set (no AGENT_CLI/AGENT_SESSION/AGENT_MODEL).
omp_env() {
  local label="$1" expect="$2" sessfile="$3" out rc
  # The NOSTUB `ps` shadow keeps the ancestry fallback out of the way: this case
  # exercises the ENV fallback only.
  out="$(env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
           AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" PI_SESSION_FILE="$sessfile" \
           PATH="$NOSTUB:$PATH" bash -c '
             set -uo pipefail
             . "$1" "$2" >/dev/null 2>&1
             printf "%s" "${AGENT_TRAILER:-}"
           ' _ "$LIB" "$TMP/private")"
  rc=$?
  printf '%-28s rc=%d  %s\n' "$label" "$rc" "${out:-<empty>}"
  [ "$rc" -eq 0 ] || { echo "  FAIL: nonzero exit"; fails=$((fails+1)); }
  if [ "$expect" = "-" ]; then
    [ -z "$out" ] || { echo "  FAIL: expected no trailer, got '$out'"; fails=$((fails+1)); }
    return
  fi
  case "$out" in
    *omp/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee*) ;;
    *) echo "  FAIL: trailer missing omp session id"; fails=$((fails+1)) ;;
  esac
  # the model is BASENAMEd by the lib (a model id may carry a vendor path prefix)
  case "$out" in
    *"Agent-Model: model-last"*) ;;
    *) echo "  FAIL: expected last model_change model, got '$out'"; fails=$((fails+1)) ;;
  esac
}

omp_env "omp env fallback"      trailer "$OMP_SESSION"

# a non-omp session file must NOT trigger the omp fallback (human stays human)
mkdir -p "$TMP/other-cli/sessions"
: > "$TMP/other-cli/sessions/x.jsonl"
omp_env "omp env: non-omp file" "-" "$TMP/other-cli/sessions/x.jsonl"

# --- (b) omp ancestry fallback -------------------------------------------------
# PATH-shadowed ps/lsof stubs: `ps` reports the current PID's ancestry as an omp
# process holding a session jsonl; `lsof` reports that jsonl as an open fd.
# No network, no real process tree — deterministic.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/ps" <<'STUBEOF'
#!/usr/bin/env bash
# Shadowed ps: -o args= reports the omp ancestor; -o ppid= walks to pid 1.
for a in "$@"; do
  case "$a" in
    args=) echo "/Users/x/.local/bin/omp --session"; exit 0 ;;
    ppid=) echo "1"; exit 0 ;;
  esac
done
exit 0
STUBEOF
cat > "$STUB/lsof" <<'STUBEOF'
#!/usr/bin/env bash
# The session paths come from the environment: a quoted heredoc would not expand them.
echo "COMMAND  PID  FD  TYPE DEVICE SIZE/OFF NODE NAME"
if [ "${FAKE_OMP_AGENT_FIRST:-}" = "1" ]; then
  echo "omp   1234 11r  REG  1,1 1234 0 0 0 ${FAKE_OMP_AGENT_SESSION:?}"
  echo "omp   1234 12r  REG  1,1 1234 0 0 0 ${FAKE_OMP_SESSION:?}"
else
  echo "omp   1234 11r  REG  1,1 1234 0 0 0 ${FAKE_OMP_SESSION:?}"
  echo "omp   1234 12r  REG  1,1 1234 0 0 0 ${FAKE_OMP_AGENT_SESSION:?}"
fi
exit 0
STUBEOF
chmod +x "$STUB/ps" "$STUB/lsof"

# A per-agent file has no timestamp/UUID basename and must never win over the
# canonical session file, regardless of lsof output order.
OMP_AGENT_SESSION="$OMP_DIR/AdversarialVerify2.jsonl"
printf '%s\n' '{"type":"model_change","model":"vendor/Wrong-Agent-Model"}' > "$OMP_AGENT_SESSION"

# ancestry <label> <expect-trailer-empty|-> <path-shadow> [agent-first]
ancestry() {
  local label="$1" expect="$2" shadow="$3" agent_first="${4:-0}" out rc
  out="$(env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL -u AGENT -u PI_SESSION_ID -u PI_SESSION_FILE \
           FAKE_OMP_SESSION="$OMP_SESSION" FAKE_OMP_AGENT_SESSION="$OMP_AGENT_SESSION" FAKE_OMP_AGENT_FIRST="$agent_first" \
           PATH="$shadow:$PATH" bash -c '
             set -uo pipefail
             . "$1" "$2" >/dev/null 2>&1
             printf "%s" "${AGENT_TRAILER:-}"
           ' _ "$LIB" "$TMP/private")"
  rc=$?
  printf '%-28s rc=%d  %s\n' "$label" "$rc" "${out:-<empty>}"
  [ "$rc" -eq 0 ] || { echo "  FAIL: nonzero exit"; fails=$((fails+1)); }
  if [ "$expect" = "-" ]; then
    [ -z "$out" ] || { echo "  FAIL: expected no trailer, got '$out'"; fails=$((fails+1)); }
    return
  fi
  # session jsonl is "<ts>_<uuid>.jsonl" => the uuid after the LAST underscore
  case "$out" in
    *omp/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee*) ;;
    *) echo "  FAIL: trailer missing ancestry-derived session id"; fails=$((fails+1)) ;;
  esac
  case "$out" in
    *"Agent-Model: model-last"*) ;;
    *) echo "  FAIL: expected ancestry-derived model, got '$out'"; fails=$((fails+1)) ;;
  esac
}

ancestry "omp ancestry: canonical first" trailer "$STUB" 0
ancestry "omp ancestry: agent first"      trailer "$STUB" 1
ancestry "ancestry: no omp ancestor"      "-"      "$NOSTUB"

# --- multi-line trailer is actually MULTI-LINE ---------------------------------
# AGENT_TRAILER carries Agent-Session + Agent-Model as two separate lines. A hook
# that passes it to `git interpret-trailers` as ONE --trailer loses the second line.
tl_out="$(env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL -u AGENT_NAME \
      AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" PI_SESSION_FILE="$OMP_SESSION" \
      bash -c '
        set -uo pipefail
        . "$1" "$2" >/dev/null 2>&1
        printf "%s\n" "$AGENT_TRAILER"
      ' _ "$LIB" "$TMP/private")"
n="$(grep -c "^Agent-" <<<"$tl_out")"
printf '%-28s lines=%s\n' "multi-line trailer" "$n"
grep -q '^Agent-Session: ' <<<"$tl_out" || { echo "  FAIL: trailer carries no Agent-Session"; fails=$((fails+1)); }
grep -q '^Agent-Name: ' <<<"$tl_out" || { echo "  FAIL: trailer carries no Agent-Name"; fails=$((fails+1)); }
grep -qE '^Agent-Session: .*[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-' <<<"$tl_out" || { echo "  FAIL: Agent-Session carries no uuid"; fails=$((fails+1)); }
[ "$n" -ge 3 ] || { echo "  FAIL: expected at least 3 trailer lines (Session, Name, Model), got $n"; fails=$((fails+1)); }

# --- the repo hook appends EACH trailer line (multi-line-safe) ------------------
# End-to-end through scripts/git-hooks/prepare-commit-msg: both trailers must land
# in the commit message, and re-running the hook must not double them.
HOOK="$(cd "$(dirname "$0")" && pwd)/git-hooks/prepare-commit-msg"
if [ -x "$HOOK" ] || [ -r "$HOOK" ]; then
  hookrepo="$TMP/hookrepo"
  mkrepo "$hookrepo" "https://github.com/gitjfmd/central-command.git"
  # REPO-FIRST under test: the lib goes into the test repo's scripts/ (that is the
  # copy the hook must use), and HOME points at a DECOY lib whose trailer is
  # "Agent-Session: HOME-DECOY-WON" with no Agent-Name/Agent-Model lines. If the
  # hook ever resolves $HOME/.local/lib before the repo copy again ("whichever
  # repo installs last wins", CEO 2026-11-16), the assertions below fail loudly.
  mkdir -p "$hookrepo/scripts"
  cp "$LIB" "$hookrepo/scripts/agent-commit-identity.sh"
  DECOY_HOME="$TMP/decoy-home"; mkdir -p "$DECOY_HOME/.local/lib" "$DECOY_HOME/.claude/state"
  cat > "$DECOY_HOME/.local/lib/agent-commit-identity.sh" <<'DECOYEOF'
AGENT_TRAILER="Agent-Session: HOME-DECOY-WON"; AGENT_WORK_RECORD=""
export AGENT_TRAILER AGENT_WORK_RECORD
DECOYEOF
  printf '%s\t%s\t%s\n' "$(date +%s)" "gitjfmd/central-command" "private" > "$DECOY_HOME/.claude/state/repo-visibility.cache"
  msg="$TMP/msg.txt"; printf 'subject line\n' > "$msg"

  # run_hook <msg-file> [source-arg] — the hook in a fresh bash with the omp env
  run_hook() {
    env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
      HOME="$DECOY_HOME" \
      AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" PI_SESSION_FILE="$OMP_SESSION" \
      bash -c 'cd "$3" && bash "$1" "$2" ${4:+$4} >/dev/null 2>&1' _ "$HOOK" "$1" "$hookrepo" "${2:-}"
  }

  run_hook "$msg"
  n1="$(grep -c '^Agent-' "$msg")"
  printf '%-28s %s\n' "hook: trailer lines" "$n1"
  grep -q '^Agent-Session: ' "$msg" || { echo "  FAIL: hook did not append Agent-Session"; fails=$((fails+1)); }
  grep -q '^Agent-Name: ' "$msg"   || { echo "  FAIL: hook did not append Agent-Name"; fails=$((fails+1)); }
  grep -q '^Agent-Model: ' "$msg"  || { echo "  FAIL: hook did not append Agent-Model"; fails=$((fails+1)); }
  # idempotence: a second run must not add more trailers
  run_hook "$msg"
  n2="$(grep -c '^Agent-' "$msg")"
  printf '%-28s %s\n' "hook: idempotent" "$n2"
  [ "$n2" -eq "$n1" ] || { echo "  FAIL: hook not idempotent ($n1 -> $n2 trailer lines)"; fails=$((fails+1)); }
  # merge/squash messages are never stamped
  msg2="$TMP/msg2.txt"; printf 'Merge branch x\n' > "$msg2"
  run_hook "$msg2" merge
  n3="$(grep -c '^Agent-' "$msg2" 2>/dev/null | head -1)"
  printf '%-28s %s\n' "hook: merge unstamped" "$n3"
  [ "$n3" -eq 0 ] || { echo "  FAIL: merge message was stamped"; fails=$((fails+1)); }

  # Machines WITHOUT the global core.hooksPath install this hook directly, so it
  # must stamp the SAME work record: exactly once, and a commit BODY that
  # mentions the field names must not suppress it.
  # A canonical session (ISO filename + title + real user prompt) so the record
  # is fully populated, not a bag of "unknown".
  # Hermetic HOME: the REPO copy (installed into $hookrepo/scripts above) must
  # win; the HOME copy here is a DECOY, and the visibility gate reads
  # $HOME/.claude/state/repo-visibility.cache.
  hookhome="$TMP/hookhome"; mkdir -p "$hookhome/.local/lib" "$hookhome/.claude/state"
  cat > "$hookhome/.local/lib/agent-commit-identity.sh" <<'DECOYEOF'
AGENT_TRAILER="Agent-Session: HOME-DECOY-WON"; AGENT_WORK_RECORD=""
export AGENT_TRAILER AGENT_WORK_RECORD
DECOYEOF
  printf '%s\t%s\t%s\n' "$(date +%s)" "gitjfmd/central-command" "private" > "$hookhome/.claude/state/repo-visibility.cache"
  HOOK_STORE="$TMP/hookstore/.omp/agent/sessions"; mkdir -p "$HOOK_STORE"
  HOOK_BASE="2026-11-14T23-58-57-702Z_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  HOOK_SESSION="$HOOK_STORE/$HOOK_BASE.jsonl"
  cat > "$HOOK_SESSION" <<'JSONL'
{"type":"title","v":1,"title":"Repo hook title","updatedAt":"2026-11-01T00:00:00.000Z"}
{"type":"model_change","id":"m1","timestamp":"2026-11-01T00:00:01.000Z","model":"vendor/Model-Hook"}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"repo hook prompt"}],"attribution":"user"}}
JSONL
  run_hook_session() {
    # $1 = session jsonl, $2 = message file
    # HOME points at a fake home (DECOY lib + seeded visibility cache); the
    # hook must use the REPO copy under $hookrepo/scripts.
    env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
      HOME="$hookhome" AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" PI_SESSION_FILE="$1" \
      bash -c 'cd "$3" && bash "$4" "$5" >/dev/null 2>&1' _ "$1" "$HOOK" "$hookrepo" "$HOOK" "$2"
  }
  msg3="$TMP/msg3.txt"
  printf 'subject line\n\nbody documenting the fields\n\n  Agent-Session-Title: example\n' > "$msg3"
  run_hook_session "$HOOK_SESSION" "$msg3"
  n4="$(grep -c '^Agent-Session-Title: ' "$msg3")"
  printf '%-28s %s\n' "hook: record lines" "$n4"
  [ "$n4" -eq 1 ] || { echo "  FAIL: repo hook did not append exactly one record block"; fails=$((fails+1)); }
  grep -q '^Agent-Session-Title: Repo hook title$' "$msg3" \
    || { echo "  FAIL: repo hook did not append the session title"; fails=$((fails+1)); }
  grep -q '^Agent-Session-Start: 2026-11-14T23:58:57.702Z$' "$msg3" \
    || { echo "  FAIL: repo hook did not append the session start"; fails=$((fails+1)); }
  grep -q '^Agent-Message: repo hook prompt$' "$msg3" \
    || { echo "  FAIL: repo hook did not append the prompt excerpt"; fails=$((fails+1)); }
  grep -q "^Agent-Jsonl: ${HOOK_SESSION}\$" "$msg3" \
    || { echo "  FAIL: repo hook did not append Agent-Jsonl"; fails=$((fails+1)); }
  grep -q '^Agent-Branch: ' "$msg3" \
    || { echo "  FAIL: repo hook did not append Agent-Branch"; fails=$((fails+1)); }
  # idempotence: a second run must not add another record block
  run_hook_session "$HOOK_SESSION" "$msg3"
  n5="$(grep -c '^Agent-Session-Title: ' "$msg3")"
  printf '%-28s %s\n' "hook: record idempotent" "$n5"
  [ "$n5" -eq 1 ] || { echo "  FAIL: repo hook not idempotent ($n5 record blocks)"; fails=$((fails+1)); }
  n6="$(grep -c '^Agent-' "$msg3")"
  printf '%-28s %s\n' "hook: total trailers" "$n6"
  # 3 base trailers (Session, Name, Model) + 6 record lines (Title, Start, Branch,
  # Message, Agents="none" — this fixture has no session SUBDIR — and Jsonl) = 9.
  [ "$n6" -eq 9 ] || { echo "  FAIL: expected 9 trailer lines, got $n6"; fails=$((fails+1)); }

  # HOME FALLBACK still works when the repo does NOT carry the lib: remove the
  # repo copy, put the REAL lib in HOME, and the record must land again.
  rm -f "$hookrepo/scripts/agent-commit-identity.sh"
  cp "$LIB" "$hookhome/.local/lib/agent-commit-identity.sh"
  msg6="$TMP/msg6.txt"; printf 'fallback subject\n' > "$msg6"
  run_hook_session "$HOOK_SESSION" "$msg6"
  n7="$(grep -c '^Agent-Session-Title: ' "$msg6")"
  printf '%-28s %s\n' "hook: HOME fallback" "$n7"
  [ "$n7" -eq 1 ] || { echo "  FAIL: HOME fallback did not stamp the record"; fails=$((fails+1)); }
  grep -q '^Agent-Session: ' "$msg6" \
    || { echo "  FAIL: HOME fallback did not stamp Agent-Session"; fails=$((fails+1)); }
else
  echo "  SKIP: hook script not found at $HOOK"
fi

# --- the global dispatcher is present and syntactically valid -------------------
DISPATCHER="$(cd "$(dirname "$0")" && pwd)/git-hooks/chained-hook"
if [ -r "$DISPATCHER" ]; then
  printf '%-28s %s\n' "chained-hook present" "yes"
  bash -n "$DISPATCHER" 2>/dev/null || { echo "  FAIL: chained-hook syntax error"; fails=$((fails+1)); }
else
  echo "  FAIL: chained-hook missing at $DISPATCHER"; fails=$((fails+1))
fi

# ==============================================================================
# Agent work record (CEO 2026-11-15)
# Every agent commit carries WHAT the session did, not just WHO it was:
#   Agent-Session-Title / -Start / Agent-Branch / Agent-Message / -Agents / -Jsonl
# PRIVATE REPOS ONLY — public/unknown => the whole record is empty.
# All fixtures below are deterministic: a hand-written session jsonl, no live store.
# ==============================================================================

WR="$TMP/wr"; mkdir -p "$WR"
WR_REPO="$WR/repo"; mkrepo "$WR_REPO" "https://github.com/gitjfmd/central-command.git"   # private
WR_PUB="$WR/pub";   mkrepo "$WR_PUB"   "https://github.com/gitjfmd/oh-my-pi.git"          # public

# The session store shape: a canonical session jsonl
#   "<ISO>_<uuid>.jsonl"
# plus a SIBLING SUBDIR of the same name (no extension) holding one jsonl per
# sub-agent. Both live under a */.omp/agent/sessions/ path so the lib's omp env
# fallback accepts them.
WR_STORE="$WR/.omp/agent/sessions"; mkdir -p "$WR_STORE"
WR_BASE="2026-11-14T23-58-57-702Z_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
WR_SESSION="$WR_STORE/$WR_BASE.jsonl"
mkdir -p "$WR_STORE/$WR_BASE"          # the session SUBDIR
cat > "$WR_SESSION" <<'JSONL'
{"type":"title","v":1,"title":"Old title","updatedAt":"2026-11-01T00:00:00.000Z"}
{"type":"session","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","timestamp":"2026-11-14T23:58:57.702Z"}
{"type":"model_change","id":"m1","timestamp":"2026-11-01T00:00:01.000Z","model":"vendor/Model-Fixture"}
{"type":"title_change","id":"x1","timestamp":"2026-11-02T00:00:00.000Z","title":"Newer title"}
{"type":"title_change","id":"x2","timestamp":"2026-11-03T00:00:00.000Z","title":"Latest title"}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"earlier prompt"}],"attribution":"user"}}
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"not a user prompt"}]}}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"final user prompt\nsecond line here"}],"attribution":"user"}}
JSONL
# a sub-agent jsonl carries its own session id in the "type":"session" record
cat > "$WR_STORE/$WR_BASE/AdversarialVerify.jsonl" <<'JSONL'
{"type":"title","v":1,"title":"","updatedAt":"2026-11-15T06:13:24.699Z"}
{"type":"session","version":3,"id":"11111111-2222-3333-4444-555555555555","timestamp":"2026-11-15T06:13:24.699Z"}
JSONL
cat > "$WR_STORE/$WR_BASE/LiveVerifier.jsonl" <<'JSONL'
{"type":"title","v":1,"title":"","updatedAt":"2026-11-15T06:14:24.699Z"}
{"type":"session","version":3,"id":"99999999-8888-7777-6666-555555555555","timestamp":"2026-11-15T06:14:24.699Z"}
JSONL

# wr_record <repo> <session-jsonl> — build the record for a fixture session.
# Driven through the REAL entry point (_aci_main) with the omp env contract, so
# the visibility gate applies exactly as it does on a live commit.
wr_record() {
  local repo="$1" sess="$2"
  env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
    AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" PI_SESSION_FILE="$sess" \
    PATH="$NOSTUB:$PATH" bash -c '
      set -uo pipefail
      . "$1" "$2" >/dev/null 2>&1
      printf "%s" "${AGENT_WORK_RECORD:-}"
    ' _ "$LIB" "$repo"
}

rec="$(wr_record "$WR_REPO" "$WR_SESSION")"
printf '%-28s %s\n' "work record: populated" "$(printf '%s' "$rec" | grep -c '^Agent-')"
printf '%s\n' "$rec" | sed 's/^/    /'

# --- leaked shell: the lib was ALREADY sourced once in this shell -----------------
# The lib EXPORTS AGENT_CLI/AGENT_SESSION/AGENT_MODEL, so sourcing it ONCE leaves
# those set in the shell. Sourcing it AGAIN (or running any hook in that shell)
# skipped BOTH omp fallbacks (keyed on `[ -z "$AGENT_CLI" ]`), which lost the work
# record entirely AND dropped the Agent-Model line (omp's bash env exports
# AGENT_MODEL= set-but-empty). Real workflow: AGENTS.md tells an agent to source
# the lib to paste AGENT_PR_RECORD into a PR body; the later `git commit` in that
# SAME shell then lost both fields.
leak="$(env -u AGENT -u PI_SESSION_ID \
  AGENT_CLI=omp AGENT_SESSION="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" AGENT_MODEL= \
  PI_SESSION_FILE="$WR_SESSION" \
  PATH="$NOSTUB:$PATH" bash -c '
    set -uo pipefail
    . "$1" "$2" >/dev/null 2>&1
    printf "%s\n%s" "${AGENT_MODEL:-}" "${AGENT_WORK_RECORD:-}"
  ' _ "$LIB" "$WR_REPO")"
leak_model="$(printf '%s\n' "$leak" | sed -n '1p')"
leak_rec="$(printf '%s\n' "$leak" | sed -n '2,$p')"
printf '%-28s %s\n' "leaked shell: model" "[$leak_model]"
printf '%-28s %s\n' "leaked shell: record lines" "$(printf '%s' "$leak_rec" | grep -c '^Agent-')"
[ -n "$leak_model" ] \
  || { echo "  FAIL: leaked shell lost the model"; fails=$((fails+1)); }
printf '%s' "$leak_rec" | grep -q '^Agent-Session-Title: ' \
  || { echo "  FAIL: leaked shell lost the work record title"; fails=$((fails+1)); }
printf '%s' "$leak_rec" | grep -q '^Agent-Session-Start: 2026-11-14T23:58:57.702Z$' \
  || { echo "  FAIL: leaked shell lost the work record start"; fails=$((fails+1)); }
printf '%s' "$leak_rec" | grep -q '^Agent-Message: ' \
  || { echo "  FAIL: leaked shell lost the work record message"; fails=$((fails+1)); }
printf '%s' "$leak_rec" | grep -q "^Agent-Jsonl: $WR_SESSION\$" \
  || { echo "  FAIL: leaked shell lost the work record jsonl"; fails=$((fails+1)); }
# the TRAILER must carry the Agent-Model line too
leak_trailer="$(env -u AGENT -u PI_SESSION_ID \
  AGENT_CLI=omp AGENT_SESSION="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" AGENT_MODEL= \
  PI_SESSION_FILE="$WR_SESSION" \
  PATH="$NOSTUB:$PATH" bash -c '
    set -uo pipefail
    . "$1" "$2" >/dev/null 2>&1
    printf "%s" "${AGENT_TRAILER:-}"
  ' _ "$LIB" "$WR_REPO")"
printf '%s' "$leak_trailer" | grep -q '^Agent-Model: ' \
  || { echo "  FAIL: leaked shell lost the Agent-Model trailer line"; fails=$((fails+1)); }

# title: the LATEST title_change wins (not the first "title" record)
printf '%s' "$rec" | grep -q '^Agent-Session-Title: Latest title$' \
  || { echo "  FAIL: title is not the latest title_change"; fails=$((fails+1)); }
# session start: ISO derived from the canonical FILENAME
printf '%s' "$rec" | grep -q '^Agent-Session-Start: 2026-11-14T23:58:57.702Z$' \
  || { echo "  FAIL: session start not derived from the filename"; fails=$((fails+1)); }
# branch: the branch of the repo at commit time
printf '%s' "$rec" | grep -q '^Agent-Branch: ' \
  || { echo "  FAIL: branch missing"; fails=$((fails+1)); }
# message: the FIRST LINE of the LAST attribution-user prompt
printf '%s' "$rec" | grep -q '^Agent-Message: final user prompt$' \
  || { echo "  FAIL: message excerpt wrong (expected first line of the last attribution-user prompt)"; fails=$((fails+1)); }
# agents: sub-agent names + their session ids, from the session SUBDIR
printf '%s' "$rec" | grep -q 'AdversarialVerify(11111111-2222-3333-4444-555555555555)' \
  || { echo "  FAIL: agents list missing name(id)"; fails=$((fails+1)); }
printf '%s' "$rec" | grep -q 'LiveVerifier(99999999-8888-7777-6666-555555555555)' \
  || { echo "  FAIL: agents list missing second agent"; fails=$((fails+1)); }
# jsonl: the absolute path of the canonical session file
printf '%s' "$rec" | grep -q "^Agent-Jsonl: $WR_SESSION\$" \
  || { echo "  FAIL: jsonl path missing/wrong"; fails=$((fails+1)); }

# --- excerpt truncation at 120 chars -------------------------------------------
LONG="$(awk 'BEGIN{s="";for(i=0;i<40;i++)s=s "0123456789";print s}')"
WR_LONG_BASE="2026-11-14T23-58-57-702Z_11111111-1111-1111-1111-111111111111"
WR_LONG_SESSION="$WR_STORE/$WR_LONG_BASE.jsonl"
cat > "$WR_LONG_SESSION" <<JSONL
{"type":"title","v":1,"title":"Long title","updatedAt":"2026-11-01T00:00:00.000Z"}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"$LONG"}],"attribution":"user"}}
JSONL
longmsg="$(wr_record "$WR_REPO" "$WR_LONG_SESSION" | awk -F': ' '/^Agent-Message: /{print substr($0, index($0,": ")+2)}')"
printf '%-28s len=%s\n' "work record: excerpt len" "${#longmsg}"
[ "${#longmsg}" -le 120 ] || { echo "  FAIL: excerpt not truncated to 120 chars (${#longmsg})"; fails=$((fails+1)); }

# --- newline sanitization: the record must stay ONE line per field -------------
WR_NL_BASE="2026-11-14T23-58-57-702Z_22222222-2222-2222-2222-222222222222"
WR_NL_SESSION="$WR_STORE/$WR_NL_BASE.jsonl"
cat > "$WR_NL_SESSION" <<'JSONL'
{"type":"title","v":1,"title":"line one\nline two","updatedAt":"2026-11-01T00:00:00.000Z"}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"a\nb\tc"}],"attribution":"user"}}
JSONL
nlrec="$(wr_record "$WR_REPO" "$WR_NL_SESSION")"
nlines="$(printf '%s' "$nlrec" | grep -c '^Agent-Session-Title: ')"
printf '%-28s %s\n' "work record: title lines" "$nlines"
[ "$nlines" -eq 1 ] || { echo "  FAIL: title spans multiple lines"; fails=$((fails+1)); }
# the message is the FIRST LINE of the prompt; the tab is flattened to a space
printf '%s' "$nlrec" | grep -q '^Agent-Message: a$' \
  || { echo "  FAIL: message excerpt is not the first line of the prompt"; fails=$((fails+1)); }

# --- a SUB-AGENT session file resolves the canonical parent -------------------
# A sub-agent jsonl has no title, no ISO filename and no attribution-user
# prompt; the parent canonical session has all three. The record must come
# from the parent, and Agent-Jsonl points at the canonical.
subrec="$(env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
  AGENT=1 PI_SESSION_ID="11111111-2222-3333-4444-555555555555" \
  PI_SESSION_FILE="$WR_STORE/$WR_BASE/AdversarialVerify.jsonl" \
  PATH="$NOSTUB:$PATH" bash -c '
    set -uo pipefail
    . "$1" "$2" >/dev/null 2>&1
    printf "%s" "${AGENT_WORK_RECORD:-}"
  ' _ "$LIB" "$WR_REPO")"
printf '%s' "$subrec" | grep -q '^Agent-Session-Title: Latest title$' \
  || { echo "  FAIL: sub-agent session did not resolve the canonical title"; fails=$((fails+1)); }
printf '%s' "$subrec" | grep -q '^Agent-Session-Start: 2026-11-14T23:58:57.702Z$' \
  || { echo "  FAIL: sub-agent session did not resolve the canonical start"; fails=$((fails+1)); }
printf '%s' "$subrec" | grep -q "^Agent-Jsonl: ${WR_SESSION}\$" \
  || { echo "  FAIL: Agent-Jsonl does not point at the canonical session"; fails=$((fails+1)); }

# --- the PR block carries the CEO's canonical field set (verbatim names) -------
prrec="$(env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
  AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" PI_SESSION_FILE="$WR_SESSION" \
  PATH="$NOSTUB:$PATH" bash -c '
    set -uo pipefail
    . "$1" "$2" >/dev/null 2>&1
    printf "%s" "${AGENT_PR_RECORD:-}"
  ' _ "$LIB" "$WR_REPO")"
printf '%-28s %s\n' "PR block: lines" "$(printf '%s' "$prrec" | grep -c ':')"
printf '%s' "$prrec" | grep -q '^cli: omp$' \
  || { echo "  FAIL: PR block missing 'cli:'"; fails=$((fails+1)); }
printf '%s' "$prrec" | grep -q '^session-id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee$' \
  || { echo "  FAIL: PR block missing 'session-id:'"; fails=$((fails+1)); }
printf '%s' "$prrec" | grep -q '^session-name: Latest title$' \
  || { echo "  FAIL: PR block missing populated 'session-name:'"; fails=$((fails+1)); }
printf '%s' "$prrec" | grep -q '^datetime: 2026-11-14T23:58:57.702Z$' \
  || { echo "  FAIL: PR block missing 'datetime:'"; fails=$((fails+1)); }
printf '%s' "$prrec" | grep -q '^message: "final user prompt"$' \
  || { echo "  FAIL: PR block missing verbatim 'message:'"; fails=$((fails+1)); }
printf '%s' "$prrec" | grep -q '^branch: ' \
  || { echo "  FAIL: PR block missing 'branch:'"; fails=$((fails+1)); }
printf '%s' "$prrec" | grep -q '^agents:$' \
  || { echo "  FAIL: PR block missing 'agents:' header"; fails=$((fails+1)); }
printf '%s' "$prrec" | grep -q '  - .*/11111111-2222-3333-4444-555555555555 · jsonl: ' \
  || { echo "  FAIL: PR block agents entries missing id/jsonl"; fails=$((fails+1)); }

# --- public repo => the WHOLE record is empty ---------------------------------
pubrec="$(wr_record "$WR_PUB" "$WR_SESSION")"
printf '%-28s [%s]\n' "work record: public repo" "$pubrec"
[ -z "$pubrec" ] || { echo "  FAIL: public repo must have an empty work record"; fails=$((fails+1)); }

# --- public repo => the PR block is the neutral/redacted shape -----------------
pubblk="$(env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
  AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" PI_SESSION_FILE="$WR_SESSION" \
  PATH="$NOSTUB:$PATH" bash -c '
    set -uo pipefail
    . "$1" "$2" >/dev/null 2>&1
    printf "%s" "${AGENT_PR_RECORD:-}"
  ' _ "$LIB" "$WR_PUB")"
printf '%-28s %s\n' "PR block: public shape" "$(printf '%s' "$pubblk" | head -1)"
printf '%s' "$pubblk" | grep -q '^cli: agent$' \
  || { echo "  FAIL: public PR block must use the neutral cli"; fails=$((fails+1)); }
printf '%s' "$pubblk" | grep -qF 'message: "(redacted: public repo)"' \
  || { echo "  FAIL: public PR block must redact the message"; fails=$((fails+1)); }
printf '%s' "$pubblk" | grep -q 'jsonl: ' \
  && { echo "  FAIL: public PR block must carry no jsonl paths"; fails=$((fails+1)); }
printf '%s' "$pubblk" | grep -q '^session-name: none$' \
  || { echo "  FAIL: public PR block must keep session-name neutral"; fails=$((fails+1)); }

# --- no session jsonl => the whole record is empty -----------------------------
norec="$(wr_record "$WR_REPO" "$WR_STORE/does-not-exist.jsonl")"
printf '%-28s [%s]\n' "work record: no jsonl" "$norec"
[ -z "$norec" ] || { echo "  FAIL: missing session jsonl must yield an empty record"; fails=$((fails+1)); }

# --- no sub-agent SUBDIR => Agent-Agents reads "none" (never omitted) -----------
WR_SOLO_BASE="2026-11-15T10-00-00-000Z_33333333-3333-3333-3333-333333333333"
WR_NOAGENTS="$WR_STORE/$WR_SOLO_BASE.jsonl"
cat > "$WR_NOAGENTS" <<'JSONL'
{"type":"title","v":1,"title":"Solo session","updatedAt":"2026-11-01T00:00:00.000Z"}
JSONL
solo="$(wr_record "$WR_REPO" "$WR_NOAGENTS")"
printf '%s\n' "$solo" | sed 's/^/    /'
printf '%s' "$solo" | grep -q '^Agent-Agents: none$' \
  || { echo "  FAIL: Agent-Agents must read 'none' when there is no sub-agent dir"; fails=$((fails+1)); }

# --- more than 6 sub-agents => 6 listed + "+N more" ---------------------------
WR_MANY_BASE="2026-11-16T10-00-00-000Z_44444444-4444-4444-4444-444444444444"
WR_MANY="$WR_STORE/$WR_MANY_BASE.jsonl"
mkdir -p "$WR_STORE/$WR_MANY_BASE"
printf '%s\n' '{"type":"title","v":1,"title":"Many agents","updatedAt":"2026-11-01T00:00:00.000Z"}' > "$WR_MANY"
i=1; while [ "$i" -le 9 ]; do
  printf '{"type":"session","version":3,"id":"agent-%03d-0000-0000-0000-000000000000"}\n' "$i" > "$WR_STORE/$WR_MANY_BASE/Agent$i.jsonl"
  i=$((i+1))
done
many="$(wr_record "$WR_REPO" "$WR_MANY")"
shown="$(printf '%s' "$many" | grep '^Agent-Agents: ' | tr ';' '\n' | grep -c 'Agent')"
printf '%-28s shown=%s  %s\n' "work record: agents cap" "$shown" "$(printf '%s' "$many" | grep '^Agent-Agents: ' | cut -c1-40)..."
[ "$shown" -eq 6 ] || { echo "  FAIL: expected 6 agents listed, got $shown"; fails=$((fails+1)); }
printf '%s' "$many" | grep -q '+3 more' \
  || { echo "  FAIL: expected '+3 more' overflow marker"; fails=$((fails+1)); }

# --- the dispatcher appends the record lines ONCE, and stays idempotent --------
# End-to-end through the real chained-hook: the record must land in the commit
# message exactly once, and a second run must not duplicate it.
if [ -r "$DISPATCHER" ]; then
  hookrepo2="$TMP/hookrepo2"
  mkrepo "$hookrepo2" "https://github.com/gitjfmd/central-command.git"
  wr_msg="$TMP/wrmsg.txt"; printf 'subject line\n' > "$wr_msg"

  # The dispatcher resolves the lib REPO-FIRST with a $HOME/.local/lib fallback.
  # hookrepo2 carries the repo copy and the fake home carries a DECOY, so a
  # regression to HOME-first resolution fails these assertions.
  # The hook dispatches on basename "$0", so it must be invoked through the
  # prepare-commit-msg SYMLINK, exactly as git invokes it.
  mkdir -p "$hookrepo2/scripts"
  cp "$LIB" "$hookrepo2/scripts/agent-commit-identity.sh"
  fakehome="$TMP/fakehome"; mkdir -p "$fakehome/.local/lib" "$fakehome/.config/git/hooks"
  cat > "$fakehome/.local/lib/agent-commit-identity.sh" <<'DECOYEOF'
AGENT_TRAILER="Agent-Session: HOME-DECOY-WON"; AGENT_WORK_RECORD=""
export AGENT_TRAILER AGENT_WORK_RECORD
DECOYEOF
  cp "$DISPATCHER" "$fakehome/.config/git/hooks/chained-hook"
  ln -sf chained-hook "$fakehome/.config/git/hooks/prepare-commit-msg"

  # The visibility gate reads $HOME/.claude/state/repo-visibility.cache and only
  # calls gh on a cache miss. Seed the cache so the gate says "private" with no
  # network call, and shadow gh so a miss can never reach the network.
  mkdir -p "$fakehome/.claude/state"
  printf '%s\t%s\t%s\n' "$(date +%s)" "gitjfmd/central-command" "private" > "$fakehome/.claude/state/repo-visibility.cache"
  ghhome="$TMP/ghstub"; mkdir -p "$ghhome"
  cat > "$ghhome/gh" <<'GHSTUB'
#!/usr/bin/env bash
echo "PRIVATE"
exit 0
GHSTUB
  chmod +x "$ghhome/gh"

  # The omp env contract: AGENT=1 + PI_SESSION_FILE pointing at an omp store path.
  run_dispatcher() {
    env -u AGENT_CLI -u AGENT_SESSION -u AGENT_MODEL \
      HOME="$fakehome" AGENT=1 PI_SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
      PI_SESSION_FILE="$WR_SESSION" \
      PATH="$ghhome:$NOSTUB:$PATH" bash -c 'cd "$3" && bash "$1" "$2" >/dev/null 2>&1' _ "$fakehome/.config/git/hooks/prepare-commit-msg" "$1" "$hookrepo2"
  }

  run_dispatcher "$wr_msg"
  nrec="$(grep -c '^Agent-Session-Title: ' "$wr_msg")"
  printf '%-28s %s\n' "dispatcher: record lines" "$nrec"
  [ "$nrec" -eq 1 ] || { echo "  FAIL: dispatcher did not append exactly one record block"; fails=$((fails+1)); }
  grep -q '^Agent-Jsonl: ' "$wr_msg" || { echo "  FAIL: dispatcher did not append Agent-Jsonl"; fails=$((fails+1)); }
  grep -q '^Agent-Session: ' "$wr_msg" || { echo "  FAIL: dispatcher did not append Agent-Session"; fails=$((fails+1)); }
  grep -q '^Agent-Model: ' "$wr_msg" || { echo "  FAIL: dispatcher did not append Agent-Model"; fails=$((fails+1)); }

  # idempotence: a second run must not add another record block
  run_dispatcher "$wr_msg"
  nrec2="$(grep -c '^Agent-Session-Title: ' "$wr_msg")"
  printf '%-28s %s\n' "dispatcher: idempotent" "$nrec2"
  [ "$nrec2" -eq 1 ] || { echo "  FAIL: dispatcher not idempotent ($nrec2 record blocks)"; fails=$((fails+1)); }
  nall="$(grep -c '^Agent-' "$wr_msg")"
  printf '%-28s %s\n' "dispatcher: total trailers" "$nall"
  [ "$nall" -eq 9 ] || { echo "  FAIL: expected 9 trailer lines, got $nall"; fails=$((fails+1)); }

  # A commit BODY that documents the field names must not suppress the real
  # trailers — only actual trailers count (git interpret-trailers --parse).
  wr_msg2="$TMP/wrmsg2.txt"
  printf 'subject\n\nbody documenting the fields\n\n  Agent-Session-Title: example\n' > "$wr_msg2"
  run_dispatcher "$wr_msg2"
  nrec3="$(grep -c '^Agent-Session-Title: ' "$wr_msg2")"
  printf '%-28s %s\n' "dispatcher: body mention" "$nrec3"
  [ "$nrec3" -eq 1 ] || { echo "  FAIL: body mention of a field name suppressed the record"; fails=$((fails+1)); }
  grep -q '^Agent-Jsonl: ' "$wr_msg2" \
    || { echo "  FAIL: body mention suppressed Agent-Jsonl"; fails=$((fails+1)); }

  # HOME FALLBACK through the dispatcher: repo copy gone, REAL lib in HOME.
  rm -f "$hookrepo2/scripts/agent-commit-identity.sh"
  cp "$LIB" "$fakehome/.local/lib/agent-commit-identity.sh"
  wr_msg3="$TMP/wrmsg3.txt"; printf 'fallback subject\n' > "$wr_msg3"
  run_dispatcher "$wr_msg3"
  nrec4="$(grep -c '^Agent-Session-Title: ' "$wr_msg3")"
  printf '%-28s %s\n' "dispatcher: HOME fallback" "$nrec4"
  [ "$nrec4" -eq 1 ] || { echo "  FAIL: dispatcher HOME fallback did not stamp the record"; fails=$((fails+1)); }
else
  echo "  SKIP: chained-hook not readable for the dispatcher test"
fi

echo
[ "$fails" -eq 0 ] && { echo "PASS — all paths exit 0 and gate correctly"; exit 0; }
echo "FAIL — $fails problem(s)"; exit 1
