#!/usr/bin/env bash
# agent-commit-identity.sh — resolve the per-CLI, per-session commit identity for THIS repo.
#
# SOURCE this (do not exec it). It exports, or leaves empty:
#   AGENT_TRAILER          e.g. "Agent-Session: claude/3f9a1b2c@jfmd-mc-pro"
#   AGENT_COMMITTER_NAME   e.g. "claude/3f9a1b2c"
#   AGENT_COMMITTER_EMAIL  e.g. "claude+3f9a1b2c@agents.invalid"
#
# Inputs (set by the caller, never guessed):
#   AGENT_CLI      which CLI is committing (claude, codex, kimi, agy, qwen, omp, pi, opencode, hermes)
#   AGENT_SESSION  that CLI's session id
#   AGENT_MODEL    (optional) the model behind this session (e.g. mimo-v2.6-pro,
#                  claude-fable-5-1) — CEO 2026-11-03: "I cannot tell if that was
#                  Sonnet". Named in private repos, neutral in public (same rule
#                  as AGENT_CLI).
#   $1             optional repo dir (default: cwd)
# No AGENT_CLI/AGENT_SESSION => a human is committing => everything stays empty. That is correct:
# the CEO's own commits must look exactly as they always have.
#
# Exports, or leaves empty:
#   AGENT_TRAILER          e.g. "Agent-Session: claude/3f9a1b2c@jfmd-mc-pro" — plus a
#                          second line "Agent-Model: <model>" when AGENT_MODEL is set
#   AGENT_COMMITTER_NAME   e.g. "claude/3f9a1b2c"
#   AGENT_COMMITTER_EMAIL  e.g. "claude+3f9a1b2c@agents.invalid"
#   AGENT_PR_STAMP         the PR BODY identity block in the CEO's canonical field
#                          set (CEO 2026-11-15, names and order verbatim):
#                            cli: / session-id: / session-name: / datetime: /
#                            message: "..." / branch: / agents: (or "none")
#                          — PR authorship is a shared account, so the PR body is
#                          where "who did what" has to be readable (CEO 2026-11-03).
#   AGENT_WORK_RECORD      MULTI-LINE traceability block, one trailer line per field:
#                          Agent-Session-Title / Agent-Session-Start / Agent-Branch /
#                          Agent-Message / Agent-Agents / Agent-Jsonl.
#                          PRIVATE REPOS ONLY — empty on public/unknown (paths + prompt text
#                          in permanent public git history is a leak, not a feature).
#   AGENT_PR_RECORD        the same canonical block as AGENT_PR_STAMP (kept as a
#                          separate name because PR bodies and AGENTS.md cite it).
#
# CEO directive 2026-08-16: naming the CLI is REQUIRED in private repos, BANNED in public ones.
# The visibility gate therefore FAILS SAFE — no network, no gh, API error, unknown remote, no
# remote at all => treated as PUBLIC => neutral "agent/..." form, never a vendor name.
#
# ALWAYS exits/returns 0. This runs on the hot path of every agent edit; a prior P0 lockout came
# from a hook that exited non-zero. Nothing here may block, slow, or fail a commit.

AGENT_TRAILER=""; AGENT_COMMITTER_NAME=""; AGENT_COMMITTER_EMAIL=""; AGENT_PR_STAMP=""
AGENT_WORK_RECORD=""; AGENT_PR_RECORD=""
export AGENT_TRAILER AGENT_COMMITTER_NAME AGENT_COMMITTER_EMAIL AGENT_PR_STAMP
export AGENT_WORK_RECORD AGENT_PR_RECORD

# Canonical omp session jsonl discovered while resolving identity (global so the
# work-record builder can reuse it instead of re-discovering it).
_ACI_SESSION_JSONL=""
# Extracted session facts (global so the PR-block builder can reuse them).
_ACI_TITLE=""; _ACI_ISO=""; _ACI_MSG=""; _ACI_AGENTS_CANON=""
# claude session-index facts (name/created/firstPrompt) when the store gave them.
_ACI_CLAUDE_NAME=""; _ACI_CLAUDE_CREATED=""; _ACI_CLAUDE_PROMPT=""

# _aci_claude_index <project-dir> <session-id> — read name/created/firstPrompt for a
# claude session from the store's sessions-index.json. Best effort: any failure
# leaves the fields empty ("none" downstream), never an error.
_aci_claude_index() {
  local dir="$1" sid="$2" idx out
  idx="$dir/sessions-index.json"
  [ -r "$idx" ] || return 0
  out=""
  if command -v jq >/dev/null 2>&1; then
    out="$(jq -r --arg id "$sid" '.entries[]? | select(.sessionId==$id) | [(.customTitle // .agentName // ""), (.created // ""), ((.firstPrompt // "") | gsub("[\\t\\n]"; " "))] | @tsv' "$idx" 2>/dev/null | head -1)"
  elif command -v python3 >/dev/null 2>&1; then
    out="$(python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for e in d.get("entries",[]):
        if e.get("sessionId")==sys.argv[2]:
            print(chr(9).join([str(e.get("customTitle") or e.get("agentName") or ""), str(e.get("created") or ""), str(e.get("firstPrompt") or "").replace(chr(9)," ").replace(chr(10)," ")]))
            break
except Exception:
    pass
' "$idx" "$sid" 2>/dev/null)"
  fi
  [ -n "$out" ] || return 0
  _ACI_CLAUDE_NAME="$(printf '%s' "$out" | cut -f1)"
  _ACI_CLAUDE_CREATED="$(printf '%s' "$out" | cut -f2)"
  _ACI_CLAUDE_PROMPT="$(printf '%s' "$out" | cut -f3-)"
  return 0
}

_aci_main() {
  # --- omp fallback (measured 2026-11-15, jfmd-mc-pro) -------------------------
  # The omp CLI is launched BARE (self-updating Mach-O at ~/.local/bin/omp) and
  # never runs through _otel-cli-wrapper like pi/kimi/agy, so it exports no
  # AGENT_CLI/AGENT_SESSION and its commits stamp as human. omp instead exports
  # AGENT=1 + PI_SESSION_ID / PI_SESSION_FILE (its session jsonl). Derive the
  # identity from that contract only when the wrapper vars are absent AND the
  # session file is genuinely an omp one; a human shell carries none of these.
  if [ -z "${AGENT_CLI:-}" ] && [ "${AGENT:-}" = "1" ] && [ -n "${PI_SESSION_FILE:-}" ]; then
    case "$PI_SESSION_FILE" in
      */.omp/agent/sessions/*)
        AGENT_CLI=omp
        AGENT_SESSION="${PI_SESSION_ID:-$(basename "$PI_SESSION_FILE" .jsonl)}"
        _ACI_SESSION_JSONL="$PI_SESSION_FILE"
        # ponytail: full-file scan (line-start anchored so text embedded in tool
        # transcripts cannot false-match), last model_change = current model.
        [ -n "${AGENT_MODEL:-}" ] || AGENT_MODEL="$(grep '^{"type":"model_change"' "$PI_SESSION_FILE" 2>/dev/null | tail -1 | sed -E 's/.*"model":"([^"]+)".*/\1/;s|.*/||')"
        export AGENT_CLI AGENT_SESSION AGENT_MODEL
        ;;
    esac
  fi

  # --- omp ancestry fallback (measured 2026-11-15, jfmd-mc-pro) -----------------
  # The agent `commit` tool runs inside an eval-kernel worker whose process env has
  # NO identity markers at all (the eval env() helper does not propagate AGENT /
  # PI_SESSION_*), so the env fallback above misses those commits. The omp session
  # process keeps its session jsonl OPEN, so walk up the process ancestry: the
  # first omp ancestor that holds a session jsonl gives us session + model.
  if [ -z "${AGENT_CLI:-}" ]; then
    # ponytail: cost ceiling = up to 8 cheap `ps` calls; `lsof` runs ONLY for omp-matching
    # ancestors and scans candidates until the canonical UUID session file is found.
    # Runs on the commit hot path of agent commits only.
    local apid sessfile base uuid mdl candidate
    apid=$$
    local i=0
    while [ "$i" -lt 8 ] && [ -n "$apid" ] && [ "$apid" != "0" ] && [ "$apid" != "1" ]; do
      local aargs; aargs="$(ps -ww -o args= -p "$apid" 2>/dev/null)"
      case "$aargs" in
        *bin/omp*|*__omp_worker_js_eval_process*|omp)
          sessfile=""
          while IFS= read -r candidate; do
            base="$(basename "$candidate" .jsonl)"
            case "$base" in *_*) ;; *) continue ;; esac
            uuid="${base##*_}"                        # session jsonl is "<ts>_<uuid>.jsonl" => uuid
            [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || continue
            sessfile="$candidate"
            break
          done < <(lsof -p "$apid" 2>/dev/null | awk '{print $NF}' | awk '/\.omp\/agent\/sessions\/.*\.jsonl$/ {print}')
          if [ -n "$sessfile" ]; then
            base="$(basename "$sessfile" .jsonl)"
            base="${base##*_}"
            mdl="$(grep '^{"type":"model_change"' "$sessfile" 2>/dev/null | tail -1 | sed -E 's/.*"model":"([^"]+)".*/\1/;s|.*/||')"
            AGENT_CLI=omp
            AGENT_SESSION="$base"
            AGENT_MODEL="$mdl"
            _ACI_SESSION_JSONL="$sessfile"
            export AGENT_CLI AGENT_SESSION AGENT_MODEL
            break
          fi
          ;;
      esac
      apid="$(ps -ww -o ppid= -p "$apid" 2>/dev/null | tr -d ' ')"
      i=$((i+1))
    done
  fi

  # --- leaked-shell recovery (measured 2026-11-15) --------------------------------
  # The lib EXPORTS AGENT_CLI/AGENT_SESSION/AGENT_MODEL. So sourcing it ONCE in a
  # shell leaves those set; sourcing it AGAIN (or running any hook in that shell)
  # skips BOTH omp fallbacks above (both are keyed on `[ -z "$AGENT_CLI" ]`), which
  # lost the work record entirely AND dropped the Agent-Model line (omp's bash env
  # exports AGENT_MODEL= set-but-empty, so the `[ -n "$AGENT_MODEL" ]` grep never
  # ran). Real workflow: AGENTS.md tells agents to source the lib to paste
  # AGENT_PR_RECORD into a PR body; the later `git commit` in that SAME shell then
  # ran the hook with the inherited identity and lost both fields.
  # Fix: recover the session jsonl + model from the omp env contract when the
  # identity already resolved but the jsonl is unknown.
  if [ -z "${_ACI_SESSION_JSONL:-}" ] && [ "${AGENT_CLI:-}" = "omp" ]; then
    case "${PI_SESSION_FILE:-}" in
      */.omp/agent/sessions/*) _ACI_SESSION_JSONL="$PI_SESSION_FILE" ;;
    esac
  fi
  if [ -n "${_ACI_SESSION_JSONL:-}" ] && [ -z "${AGENT_MODEL:-}" ]; then
    # ponytail: same line-start-anchored last-model_change extraction as above.
    AGENT_MODEL="$(grep '^{"type":"model_change"' "$_ACI_SESSION_JSONL" 2>/dev/null | tail -1 | sed -E 's/.*"model":"([^"]+)".*/\1/;s|.*/||')"
    export AGENT_MODEL
  fi

  # --- claude session store (CEO 2026-11-15/16: the footprint reaches EVERY CLI) ---
  # The claude PostToolUse hook exports AGENT_CLI=claude + AGENT_SESSION=<uuid> but
  # no session FILE, so the PR block stayed empty on claude. The store keeps one
  # "<uuid>.jsonl" per session under ~/.claude/projects/<slug>/, a sessions-index.json
  # with that session's name / created / firstPrompt, and sub-agent transcripts under
  # "<uuid>/subagents/". One index read, no full-file pass (the transcript can be
  # 100MB+, the awk hot-path ceiling does not belong on a commit).
  if [ -z "${_ACI_SESSION_JSONL:-}" ] && [ "${AGENT_CLI:-}" = "claude" ] && [ -n "${AGENT_SESSION:-}" ]; then
    _aci_cand=""
    for _aci_cand in "$HOME"/.claude/projects/*/"${AGENT_SESSION}".jsonl; do
      if [ -f "$_aci_cand" ]; then
        _ACI_SESSION_JSONL="$_aci_cand"
        _aci_claude_index "$(dirname "$_aci_cand")" "${AGENT_SESSION}"
        break
      fi
    done
  fi

  [ -n "${AGENT_CLI:-}" ] || return 0
  [ -n "${AGENT_SESSION:-}" ] || return 0

  local dir="${1:-$PWD}"
  local top; top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$top" ] || return 0

  # --- visibility gate (cached; fail-safe = public) ------------------------------
  local vis; vis="$(_aci_visibility "$top")"

  # --- identity ------------------------------------------------------------------
  # Session ids differ in shape per CLI: claude = uuid, the otel-wrapped CLIs = 20260817T041530-9931.
  # The TRAILER carries the id VERBATIM (sanitized only) — that is the canonical, greppable record
  # and the same string Langfuse traces are keyed on, so a commit joins to its trace.
  # The COMMITTER name carries an 8-hex digest instead: `git log --format=%cn` stays readable, and
  # a digest is collision-free where truncation is NOT — truncating the wrapper's id to 8 chars
  # yields "20260817", a DATE, which every session on that day would share.
  local sess dig
  sess="$(printf '%s' "$AGENT_SESSION" | tr -cd '[:alnum:]._-')"
  [ -n "$sess" ] || sess="nosession"
  dig="$(printf '%s' "$sess" | shasum -a 256 2>/dev/null | cut -c1-8)"
  [ -n "$dig" ] || dig="$(printf '%s' "$sess" | cut -c1-8)"
  local host; host="$(hostname -s 2>/dev/null || echo unknown)"

  local who
  if [ "$vis" = "private" ]; then
    who="$(printf '%s' "$AGENT_CLI" | tr -cd '[:alnum:]._-' | tr '[:upper:]' '[:lower:]')"
    [ -n "$who" ] || who="agent"
  else
    who="agent"   # ponytail: public repos get the neutral form, no vendor name, ever.
  fi

  AGENT_COMMITTER_NAME="${who}/${dig}"
  AGENT_COMMITTER_EMAIL="${who}+${dig}@agents.invalid"   # .invalid is RFC-2606 reserved: never routes, never maps to a GitHub account

  # Agent NAME alongside the session UUID (CEO 2026-11-15: "960 says noname but uuid
  # I also want the name in addition to uuid"). The uuid is canonical and greppable;
  # the name is what a human reads. Source order: explicit AGENT_NAME, then a sibling
  # per-agent session file (omp writes one alongside the canonical "<ts>_<uuid>.jsonl"),
  # else the CLI name. Private repos only: a name in public history is identity, so it
  # falls back to the neutral form there.
  local aname=""
  [ -n "${AGENT_NAME:-}" ] && aname="$(printf '%s' "$AGENT_NAME" | tr -cd '[:alnum:]._-')"
  if [ -z "$aname" ] && [ -n "${_ACI_SESSION_JSONL:-}" ]; then
    local sib
    for sib in "$(dirname "$_ACI_SESSION_JSONL")"/*.jsonl; do
      [ -e "$sib" ] || continue
      case "$(basename "$sib")" in
        [0-9]*_[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-*) continue ;;  # canonical
      esac
      aname="$(basename "$sib" .jsonl | tr -cd '[:alnum:]._-')"; break
    done
  fi
  [ -n "$aname" ] || aname="$who"
  [ "$vis" = "private" ] || aname="agent"

  AGENT_TRAILER="Agent-Session: ${who}/${sess}@${host}"
  AGENT_TRAILER="${AGENT_TRAILER}"$'\n'"Agent-Name: ${aname}"

  # Model identity (CEO 2026-11-03): rides the trailer + the PR stamp under the
  # SAME visibility rule as the CLI name — named in private, neutral in public.
  local mdl=""
  if [ -n "${AGENT_MODEL:-}" ] && [ "$vis" = "private" ]; then
    mdl="$(printf '%s' "$AGENT_MODEL" | tr -cd '[:alnum:]._+-' | tr '[:upper:]' '[:lower:]')"
  fi
  [ -n "$mdl" ] && AGENT_TRAILER="${AGENT_TRAILER}"$'\n'"Agent-Model: ${mdl}"

  # --- work record (CEO 2026-11-15): WHAT the session did, not just WHO it was -----
  # Private repos only. Public/unknown => empty (paths + prompt text in permanent
  # public git history is a leak). Any error => empty, never a failed commit.
  if [ "$vis" = "private" ]; then
    _aci_work_record "$top" "$who" || true
  fi

  # --- PR body identity block: the CEO's canonical field set (CEO 2026-11-15/16) ----
  _aci_pr_block "$vis" "$who" "$sess" "$top" || true
  return 0
}

# _aci_pr_block <vis> <who> <sess> <top> — AGENT_PR_STAMP / AGENT_PR_RECORD in the
# CEO's canonical field set, names and order VERBATIM (CEO 2026-11-15):
#   cli: / session-id: / session-name: / datetime: / message: "..." / branch: / agents:
# Public/unknown repos get the neutral shape: cli "agent", session-name "none",
# message "(redacted: public repo)", agents "none" (prompt text + jsonl paths in a
# PUBLIC PR body are a leak, same rule as the trailer). Never errors.
_aci_pr_block() {
  local vis="$1" who="$2" sess="$3" top="$4"
  local sname datetime msg branch agents blk
  sname="${_ACI_TITLE:-}"
  [ "$sname" != "unknown" ] || sname=""
  datetime="${_ACI_ISO:-}"
  [ "$datetime" != "unknown" ] || datetime=""
  branch="$(git -C "$top" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$branch" ] || branch="unknown"

  if [ "$vis" = "private" ]; then
    msg="${_ACI_MSG:-}"
    [ -n "$msg" ] || msg="(no user message captured)"
    agents="${_ACI_AGENTS_CANON:-}"
  else
    sname=""; msg="(redacted: public repo)"; agents=""
  fi
  [ -n "$sname" ] || sname="none"
  [ -n "$datetime" ] || datetime="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # the template quotes the message: a double quote inside would break the visual
  # contract, so the extractor flattens it to a single quote first.
  msg="$(printf '%s' "$msg" | tr '"' "'")"

  blk="cli: ${who}"
  blk="${blk}"$'\n'"session-id: ${sess}"
  blk="${blk}"$'\n'"session-name: ${sname}"
  blk="${blk}"$'\n'"datetime: ${datetime}"
  blk="${blk}"$'\n'"message: \"${msg}\""
  blk="${blk}"$'\n'"branch: ${branch}"
  if [ -n "$agents" ]; then
    blk="${blk}"$'\n'"agents:"
    blk="${blk}"$'\n'"${agents}"
  else
    blk="${blk}"$'\n'"agents: none"
  fi
  AGENT_PR_STAMP="$blk"
  AGENT_PR_RECORD="$blk"
  return 0
}

# _aci_work_record <top> <who> — build AGENT_WORK_RECORD plus the extracted
# facts (_ACI_TITLE/_ACI_ISO/_ACI_MSG/_ACI_AGENTS_CANON) the PR-block builder
# assembles into the CEO's canonical field set.
#
# Fields (one trailer line each):
#   Agent-Session-Title: latest session title (single line, <=100 chars)
#   Agent-Session-Start: ISO start time, derived from the canonical jsonl FILENAME
#   Agent-Branch:       branch at commit time (short sha when detached)
#   Agent-Message:      FIRST LINE of the last user prompt (<=120 chars, one line)
#   Agent-Agents:       subagent names (+ ids), <=6 shown, "; "-separated;
#                       ALWAYS present — "none" when there are no sub-agents
#   Agent-Jsonl:        absolute path of the canonical session jsonl
#
# ponytail: cost ceiling = ONE full-file awk pass over the canonical session jsonl
# (MEASURED 2026-11-15: ~0.9-1.1s on a 25MB jsonl — one pass, not several greps)
# + at most 12 sub-agent files peeked at their first 4KB. Both bounds are hard
# caps below. If this ever shows up on the commit hot path, replace the full awk
# with a tail-window read (the title is at the head, the last user prompt near
# the tail); do NOT add more passes.
_aci_work_record() {
  local top="$1" who="${2:-agent}" jsonl start branch
  jsonl="$_ACI_SESSION_JSONL"
  [ -n "$jsonl" ] || return 0
  [ -f "$jsonl" ] || return 0

  # A SUB-AGENT session file (e.g. "<canonical-dir>/WorkRecordBuild.jsonl")
  # carries no title, no ISO filename and no attribution-user prompt — the
  # parent does. Resolve the canonical parent session and read title/start/
  # message/agents from THERE; Agent-Jsonl still points at the file we ran in.
  local canonical="$jsonl"
  case "$(basename "$jsonl" .jsonl)" in
    *_*) : ;;   # already "<ISO>_<uuid>" — canonical
    *)
      # The sub-agent file lives in the canonical session's SUBDIR, and the
      # canonical jsonl is that SUBDIR's SIBLING in the store:
      #   <store>/<ISO>_<uuid>/<AgentName>.jsonl   <- sub-agent
      #   <store>/<ISO>_<uuid>.jsonl               <- canonical
      local pdir pbase pstore
      pdir="$(dirname "$jsonl")"
      pbase="$(basename "$pdir")"
      pstore="$(dirname "$pdir")"
      case "$pbase" in
        *_*) : ;;
        *) pbase="" ;;
      esac
      if [ -n "$pbase" ] && [ -f "$pstore/$pbase.jsonl" ]; then
        canonical="$pstore/$pbase.jsonl"
      fi
      ;;
  esac

  # --- session start (from the canonical filename "<ISO>_<uuid>.jsonl") ----------
  # "2026-11-14T23-58-57-702Z" => "2026-11-14T23:58:57.702Z"
  local base stem iso
  base="$(basename "$canonical" .jsonl)"
  stem="${base%%_*}"
  iso="$(printf '%s' "$stem" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{3})Z$/\1T\2:\3:\4.\5Z/')"
  case "$iso" in *[!0-9TZ:.-]*) iso="" ;; esac
  [ -n "$iso" ] || iso="unknown"

  # --- branch ------------------------------------------------------------------
  branch="$(git -C "$top" symbolic-ref --short HEAD 2>/dev/null)" || branch=""
  [ -n "$branch" ] || branch="$(git -C "$top" rev-parse --short HEAD 2>/dev/null)" || branch=""
  [ -n "$branch" ] || branch="unknown"

  # --- title + message ---------------------------------------------------------
  # claude sessions carry their facts in sessions-index.json (read in _aci_main):
  # use them and SKIP the full-file pass — a claude transcript can be 100MB+ and
  # the awk hot-path ceiling does not belong on a commit.
  local out title msg
  if [ -n "${_ACI_CLAUDE_NAME:-}" ] || [ -n "${_ACI_CLAUDE_PROMPT:-}" ]; then
    title="${_ACI_CLAUDE_NAME:-}"
    msg="${_ACI_CLAUDE_PROMPT:-}"
    [ -n "${_ACI_CLAUDE_CREATED:-}" ] && iso="${_ACI_CLAUDE_CREATED}"
  else
  # ONE awk pass: latest title + last attribution-user message.
  # Real user prompts carry "attribution":"user" INSIDE the message record (omp
  # shape); pi shape is role:"user" without attribution (tool results there are
  # role:"toolResult"), so attribution wins and bare role is the fallback.
  # JSON string escapes are decoded here (\n \t \r \" \\) because the store is
  # JSONL: a newline in the prompt is the two characters backslash+n on disk.
  out="$(awk '
    function unescape(s,   t) {
      t = s
      gsub(/\\n/, " ", t); gsub(/\\t/, " ", t); gsub(/\\r/, " ", t)
      gsub(/\\"/, "\"", t); gsub(/\\\\/, "\\", t)
      return t
    }
    # The MESSAGE is the FIRST LINE of the last user prompt. The store is JSONL,
    # so a newline is the two characters backslash+n on disk: split on that BEFORE
    # flattening, then turn tabs/CR into spaces.
    function firstline(s,   t) {
      t = s
      sub(/\\n.*$/, "", t)          # keep only the first line
      gsub(/\\t/, " ", t); gsub(/\\r/, " ", t)
      gsub(/\\"/, "\"", t); gsub(/\\\\/, "\\", t)
      return t
    }
    {
      # title: "type":"title" (updatedAt) or "type":"title_change" (timestamp)
      if (match($0, /"type":"title_change"/)) {
        ts = ""; if (match($0, /"timestamp":"[^"]+"/)) ts = substr($0, RSTART+12, RLENGTH-13)
        if (match($0, /"title":"[^"]*"/)) { t = unescape(substr($0, RSTART+9, RLENGTH-10)); if (ts >= tts) { tts = ts; title = t } }
      } else if (match($0, /"type":"title"[,"]/)) {
        ts = ""; if (match($0, /"updatedAt":"[^"]+"/)) ts = substr($0, RSTART+12, RLENGTH-13)
        if (match($0, /"title":"[^"]*"/)) { t = unescape(substr($0, RSTART+9, RLENGTH-10)); if (ts >= tts) { tts = ts; title = t } }
      }
      # last REAL user message: attribution inside a message record (omp shape);
      # pi shape is role:"user" with no attribution (tool results there are
      # role:"toolResult") — fallback, attribution wins whenever present.
      if (match($0, /"type":"message"/) && match($0, /"attribution":"user"/)) {
        if (match($0, /"text":"[^"]*"/)) msga = firstline(substr($0, RSTART+8, RLENGTH-9))
      } else if (match($0, /"type":"message"/) && match($0, /"role":"user"/)) {
        if (match($0, /"text":"[^"]*"/)) msgb = firstline(substr($0, RSTART+8, RLENGTH-9))
      }
    }
    END { printf "%s\n%s\n", title, (msga != "" ? msga : msgb) }
  ' "$canonical" 2>/dev/null)" || out=""
  title="$(printf '%s' "$out" | awk 'NR==1{print; exit}')"
  msg="$(printf '%s' "$out" | awk 'NR==2{print; exit}')"
  fi

  # --- sanitize to a single safe line ------------------------------------------
  # strip control chars + newlines/tabs, collapse whitespace runs, truncate.
  _aci_clean() { printf '%s' "$1" | tr -d '\000-\037\177' | tr '\n\r\t' '   ' | tr -s ' ' | sed -E 's/^ +//; s/ +$//'; }
  title="$(_aci_clean "$title")"
  msg="$(_aci_clean "$msg")"
  [ -n "$title" ] || title="unknown"
  if [ "${#title}" -gt 100 ]; then title="$(printf '%s' "$title" | cut -c1-100)"; fi
  [ -n "$msg" ] || msg="(no user message captured)"
  if [ "${#msg}" -gt 120 ]; then msg="$(printf '%s' "$msg" | cut -c1-120)"; fi

  # --- sub-agents (session SUBDIR holds one jsonl per subagent) -----------------
  # ponytail: <=12 files examined, <=6 listed, 4KB peek each. Bounded on purpose.
  # The SUBDIR belongs to the CANONICAL session, so use that path (for a
  # sub-agent file the canonical's own dir is the one holding every agent).
  # claude keeps them one level deeper, under "<uuid>/subagents/".
  local agents="" canon="" subdir adir
  subdir="${canonical%.jsonl}"
  adir="$subdir"
  [ -d "$subdir/subagents" ] && adir="$subdir/subagents"
  if [ -d "$adir" ]; then
    local f name id role listed=0 total=0
    for f in "$adir"/*.jsonl; do
      [ -f "$f" ] || continue
      total=$((total+1))
      [ "$listed" -lt 6 ] || continue
      name="$(basename "$f" .jsonl)"
      case "$name" in .*) continue ;; esac
      id=""
      id="$(awk 'NR<=2' "$f" 2>/dev/null | head -c 4096 | awk '
        match($0, /"type":"session"[^\n]*/) {
          s = substr($0, RSTART, RLENGTH)
          if (match(s, /"id":"[^"]+"/)) { print substr(s, RSTART+6, RLENGTH-7); exit }
        }')"
      [ -n "$id" ] || id="$name"
      role=""
      [ -r "${f%.jsonl}.meta.json" ] && \
        role="$(grep -m1 -oE '"agentType":"[^"]+"' "${f%.jsonl}.meta.json" 2>/dev/null | sed 's/"agentType":"//;s/"$//')"
      [ -n "$role" ] || role="$name"
      agents="${agents:+$agents; }${name}(${id})"
      canon="${canon:+$canon$'\n'}  - ${role}: ${who}/${id} · jsonl: ${f}"
      listed=$((listed+1))
    done
    if [ "$total" -gt 6 ] && [ -n "$agents" ]; then
      agents="$agents; +$((total-6)) more"
    fi
  fi

  local rec=""
  rec="Agent-Session-Title: ${title}"
  rec="${rec}"$'\n'"Agent-Session-Start: ${iso}"
  rec="${rec}"$'\n'"Agent-Branch: ${branch}"
  rec="${rec}"$'\n'"Agent-Message: ${msg}"
  # Always present, "none" when solo: the PR-stamp checker requires the field, and
  # an omitted list reads as "not checked" rather than "no parallel agents".
  rec="${rec}"$'\n'"Agent-Agents: ${agents:-none}"
  rec="${rec}"$'\n'"Agent-Jsonl: ${canonical}"
  AGENT_WORK_RECORD="$rec"

  # Facts for the PR block builder (CEO canonical field set).
  _ACI_TITLE="$title"; _ACI_ISO="$iso"; _ACI_MSG="$msg"; _ACI_AGENTS_CANON="$canon"
  return 0
}

# echo "private" | "public"  — anything we cannot positively prove private is "public".
_aci_visibility() {
  local top="$1" url slug cache line now ts cached vis
  url="$(git -C "$top" config --get remote.origin.url 2>/dev/null)" || url=""
  [ -n "$url" ] || { echo public; return 0; }              # no remote => fail safe

  # git@github.com:owner/repo.git | https://github.com/owner/repo.git — anything else is not
  # something `gh` can resolve, so don't even ask: unresolvable == public == fail safe.
  case "$url" in *github.com*) ;; *) echo public; return 0 ;; esac
  slug="${url#*github.com}"; slug="${slug#:}"; slug="${slug#/}"; slug="${slug%.git}"
  case "$slug" in */*) ;; *) echo public; return 0 ;; esac  # unparseable => fail safe

  cache="$HOME/.claude/state/repo-visibility.cache"
  mkdir -p "$(dirname "$cache")" 2>/dev/null
  now=$(date +%s)
  line="$(grep -F "	${slug}	" "$cache" 2>/dev/null | tail -1)"
  if [ -n "$line" ]; then
    ts="${line%%	*}"; cached="${line##*	}"
    # 24h TTL: visibility is a near-static property, and a stale "public" only ever under-shares.
    if [ $((now - ts)) -lt 86400 ] 2>/dev/null && [ -n "$cached" ]; then echo "$cached"; return 0; fi
  fi

  # One network call per repo per 24h. perl alarm = portable 5s timeout (macOS has no `timeout`).
  # ONLY `visibility` is asked for. Owner and fork status are deliberately NOT consulted: the
  # CEO's rule is visibility-alone, so a public FORK and a public CEO-authored repo take the
  # identical neutral path. INTERNAL is not special-cased either — only a literal PRIVATE names
  # the CLI; every other answer is the neutral form.
  vis="$(perl -e 'alarm 5; exec @ARGV' gh repo view "$slug" --json visibility -q '.visibility' 2>/dev/null)" || vis=""
  case "$vis" in
    PRIVATE) vis=private ;;
    *)       vis=public  ;;    # PUBLIC, INTERNAL, empty, error, timeout, no gh — all fail safe
  esac
  printf '%s\t%s\t%s\n' "$now" "$slug" "$vis" >> "$cache" 2>/dev/null
  tail -100 "$cache" > "$cache.tmp" 2>/dev/null && mv "$cache.tmp" "$cache" 2>/dev/null
  echo "$vis"
}

_aci_main "${1:-}" 2>/dev/null || true
return 0 2>/dev/null || true
