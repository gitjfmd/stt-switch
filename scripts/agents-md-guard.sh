#!/usr/bin/env bash
# agents-md-guard.sh: AGENTS.md at the repo root is the ONLY hand-edited agent rules
# file. Every other agent file is derived from it (CEO decision 2026-11-18):
#   QWEN.md, WARP.md, .clinerules/00-central-command-rules.md,
#   .github/copilot-instructions.md, and GEMINI.md when present: byte copies.
#   CLAUDE.md: the single line "@AGENTS.md", unless .agents-md-guard-exceptions lists it.
# A copy that is a symlink resolving to AGENTS.md is left as it is and passes.
# Only a branch named agents-md-update-* may change any of these files or the guard's
# own control files. In CI the branch name is a workflow signal, not authorization:
# a same-repo PR and an authorized actor are also required.
#
# Usage:
#   agents-md-guard.sh sync                 write every copy (and the stub) from AGENTS.md
#   agents-md-guard.sh check [--canary]     fail naming each file out of line; --canary
#                                           also requires CANARY-GUARDRAILS-V1 in AGENTS.md
#   agents-md-guard.sh branch-gate <base>   gate agent and control files changed in
#                                           <base>...HEAD by branch, plus PR provenance in CI
#   agents-md-guard.sh selftest             run the cases in throwaway repos
# Runs against the git repo containing the current directory (sync and check also run in
# a directory that is not a git repo yet). Exit 0 = ok, 1 = fail.
set -uo pipefail

COPIES=(QWEN.md WARP.md .clinerules/00-central-command-rules.md .github/copilot-instructions.md)
STUB='@AGENTS.md'
CANARY='CANARY-GUARDRAILS-V1'
EXCEPTIONS=.agents-md-guard-exceptions
CONTROL_FILES=(scripts/agents-md-guard.sh "$EXCEPTIONS" .pre-commit-config.yaml .github/workflows/agents-md-guard.yml)
BRANCH_RE='^agents-md-update-'

say() { echo "agents-md-guard: $*"; }

copy_set() {  # the four copies, plus GEMINI.md when present
  printf '%s\n' "${COPIES[@]}"
  if [ -e GEMINI.md ] || [ -L GEMINI.md ]; then echo GEMINI.md; fi
}
links_to_agents() { [ -L "$1" ] && [ "$1" -ef AGENTS.md ]; }
claude_excepted() { grep -qE '^CLAUDE\.md([[:space:]]|$)' "$EXCEPTIONS" 2>/dev/null; }

# classify_path <path> -> "gate" (known agent/control file), "unknown"
# (agent-instruction family the guard does not handle: fail closed), or ""
# (ordinary file). branch-gate diffs ALL changed files and routes each one
# through here; nothing is missed by a restrictive pathspec.
classify_path() {
  local p="$1" lc base
  lc="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
  base="${lc##*/}"
  case "$p" in
    AGENTS.md|CLAUDE.md|GEMINI.md|QWEN.md|WARP.md|.github/copilot-instructions.md) echo gate; return ;;
    .clinerules/*|.cursor/rules/*) echo gate; return ;;
    *.mdc) echo gate; return ;;
    scripts/agents-md-guard.sh|.agents-md-guard-exceptions|.pre-commit-config.yaml|.github/workflows/agents-md-guard.yml) echo gate; return ;;
  esac
  case "$lc" in *windsurf*) echo gate; return ;; esac
  case "$lc" in .clinerules|.clinerules/*|.cursor|.cursor/*) echo unknown; return ;; esac
  case "$base" in
    agents*.md|claude*.md|gemini*.md|qwen*.md|warp*.md|*.mdc|*windsurf*|*copilot-instructions*) echo unknown; return ;;
  esac
  echo ""
}

to_root() {
  local r; r="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"  # pwd: a repo before git init
  cd "$r" || exit 1
  [ -f AGENTS.md ] || { say "FAIL AGENTS.md is missing at $r"; exit 1; }
}

sync() {
  local f rc=0
  to_root
  while IFS= read -r f; do
    links_to_agents "$f" && continue
    if [ -L "$f" ]; then say "FAIL $f is a symlink that does not resolve to AGENTS.md; not writing through it"; rc=1; continue; fi
    cmp -s AGENTS.md "$f" && continue
    mkdir -p "$(dirname "$f")" && cp AGENTS.md "$f" && say "synced $f" || rc=1
  done < <(copy_set)
  if ! claude_excepted && ! links_to_agents CLAUDE.md; then
    if [ -L CLAUDE.md ]; then say "FAIL CLAUDE.md is a symlink that does not resolve to AGENTS.md; not writing through it"; rc=1
    elif ! printf '%s\n' "$STUB" | cmp -s - CLAUDE.md; then printf '%s\n' "$STUB" > CLAUDE.md && say "wrote CLAUDE.md stub"; fi
  fi
  return "$rc"
}

check() {
  local f rc=0
  to_root
  if [ "${1:-}" = --canary ] && ! grep -qF "$CANARY" AGENTS.md; then say "FAIL AGENTS.md does not carry $CANARY"; rc=1; fi
  while IFS= read -r f; do
    links_to_agents "$f" && continue
    if [ ! -f "$f" ]; then say "FAIL $f is missing (run: bash scripts/agents-md-guard.sh sync)"; rc=1
    elif ! cmp -s AGENTS.md "$f"; then say "FAIL $f differs from AGENTS.md (run: bash scripts/agents-md-guard.sh sync)"; rc=1; fi
  done < <(copy_set)
  # Only CLAUDE.md may be excepted; any other entry would be a silent hole in the copy set.
  if [ -f "$EXCEPTIONS" ] && grep -vE '^[[:space:]]*(#|$)|^CLAUDE\.md([[:space:]]|$)' "$EXCEPTIONS" >/dev/null; then
    say "FAIL $EXCEPTIONS lists a file other than CLAUDE.md; only CLAUDE.md may be excepted"; rc=1
  fi
  if ! claude_excepted && ! links_to_agents CLAUDE.md && ! printf '%s\n' "$STUB" | cmp -s - CLAUDE.md; then
    say "FAIL CLAUDE.md is not the one-line stub '$STUB' and $EXCEPTIONS does not list it"; rc=1
  fi
  [ "$rc" -eq 0 ] && say "check OK"
  return "$rc"
}

branch_gate() {
  local base="${1:-}" changed branch actor allowed authorized required actual_head
  local actors=()
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    for required in PR_HEAD_REPO PR_ACTOR ORIGIN_REPO BASE_SHA PR_HEAD_SHA; do
      if [ -z "${!required:-}" ]; then
        say "FAIL $required is unset in CI"
        return 1
      fi
    done
  fi
  [ -n "$base" ] || { say "usage: branch-gate <base-ref>"; return 1; }
  to_root
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    actual_head="$(git rev-parse HEAD)" || { say "FAIL could not resolve HEAD"; return 1; }
    if [ "$actual_head" != "$PR_HEAD_SHA" ]; then
      say "FAIL HEAD '$actual_head' does not equal PR_HEAD_SHA '$PR_HEAD_SHA'"
      return 1
    fi
    if [ "$base" != "$BASE_SHA" ]; then
      say "FAIL branch-gate base must be the event BASE_SHA, not a mutable ref"
      return 1
    fi
  fi
  git rev-parse -q --verify "$base^{commit}" >/dev/null || { say "FAIL base ref '$base' not found"; return 1; }
  # ALL changed files, no restrictive pathspec; every one is classified.
  all_changed="$(git diff --name-only "$base...HEAD")" \
    || { say "FAIL could not diff $base...HEAD"; return 1; }
  changed="" unknown=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(classify_path "$f")" in
      gate) changed="$changed$f"$'\n' ;;
      unknown) unknown="$unknown$f"$'\n' ;;
    esac
  done <<< "$all_changed"
  if [ -n "$unknown" ]; then
    say "FAIL unknown agent-instruction paths (fail closed); extend the guard before landing these:"
    printf '  %s' "$unknown"
    return 1
  fi
  [ -z "$changed" ] && { say "branch-gate OK (no agent or control file changed vs $base)"; return 0; }
  branch="${GITHUB_HEAD_REF:-$(git rev-parse --abbrev-ref HEAD)}"
  if ! [[ "$branch" =~ $BRANCH_RE ]]; then
    say "FAIL branch '$branch' changes agent or control files; only a branch named agents-md-update-* may:"
    printf '  %s\n' $changed
    return 1
  fi
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    if [ -z "${ORIGIN_REPO:-}" ] || [ "${PR_HEAD_REPO:-}" != "$ORIGIN_REPO" ]; then
      say "FAIL PR head repo '${PR_HEAD_REPO:-}' does not equal origin repo '${ORIGIN_REPO:-}'"
      return 1
    fi
    actor="${PR_ACTOR:-}"
    authorized=false
    # AGENTS_MD_AUTHORIZED_ACTORS is MANDATORY with no default: unset or empty
    # denies all actors. Entries are trimmed; empties are skipped.
    IFS=',' read -r -a actors <<< "${AGENTS_MD_AUTHORIZED_ACTORS:-}"
    for allowed in "${actors[@]}"; do
      allowed="$(printf '%s' "$allowed" | tr -d '[:space:]')"
      [ -n "$allowed" ] || continue
      [ "$actor" = "$allowed" ] && { authorized=true; break; }
    done
    if [ "$authorized" != true ]; then
      say "FAIL PR actor '$actor' is not in AGENTS_MD_AUTHORIZED_ACTORS"
      return 1
    fi
    say "branch-gate OK ($branch, same-repo PR, authorized actor $actor)"
    return 0
  fi
  say "branch-gate OK ($branch follows the local naming convention; this is not authorization)"
  return 0
}

selftest() {
  local self t fails=0 f n=0
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GITHUB_HEAD_REF GITHUB_ACTIONS
  unset ORIGIN_REPO PR_HEAD_REPO PR_ACTOR AGENTS_MD_AUTHORIZED_ACTORS BASE_SHA PR_HEAD_SHA
  unset TEST_ORIGIN_REPO TEST_BASE_SHA TEST_PR_HEAD_SHA TEST_ACTORS
  t="$(mktemp -d)"; trap "rm -rf '$t' '$t-nogit'" EXIT
  cd "$t" && git init -q -b main . || return 1
  g() { git -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null "$@"; }
  run() { bash "$self" "$@" >/dev/null 2>&1; }
  run_ci() {
    local base_sha head_sha
    base_sha="$(g rev-parse main)"
    head_sha="$(g rev-parse HEAD)"
    env GITHUB_ACTIONS=true ORIGIN_REPO="${TEST_ORIGIN_REPO-gitjfmd/central-command}" \
      PR_HEAD_REPO="${1-gitjfmd/central-command}" PR_ACTOR="${2-gitjfmd}" \
      GITHUB_HEAD_REF="${3:-agents-md-update-ci}" \
      AGENTS_MD_AUTHORIZED_ACTORS="${TEST_ACTORS-gitjfmd}" \
      BASE_SHA="${TEST_BASE_SHA-$base_sha}" PR_HEAD_SHA="${TEST_PR_HEAD_SHA-$head_sha}" \
      bash "$self" branch-gate "${TEST_BASE_SHA-$base_sha}" >/dev/null 2>&1
  }
  expect() {  # want label cmd...
    local want="$1" label="$2"; shift 2
    "$@"; local got=$?
    if [ "$got" -eq "$want" ]; then echo "ok   $label"; else echo "FAIL $label (exit $got, want $want)"; fails=$((fails+1)); fi
  }
  printf '# rules\n%s\n' "$CANARY" > AGENTS.md
  run sync
  expect 0 "identical copies pass"            run check --canary
  printf 'drift\n' >> QWEN.md
  expect 1 "drifted copy fails"               run check
  run sync
  expect 0 "stub CLAUDE.md passes"            run check
  printf '@AGENTS.md\nextra\n' > CLAUDE.md
  expect 1 "wrong stub fails"                 run check
  printf 'CLAUDE.md  hub\n' > "$EXCEPTIONS"
  expect 0 "excepted CLAUDE.md passes"        run check
  printf 'QWEN.md  no\n' >> "$EXCEPTIONS"
  expect 1 "exception other than CLAUDE.md fails" run check
  rm "$EXCEPTIONS"; run sync
  rm WARP.md && ln -s AGENTS.md WARP.md
  expect 0 "symlink to AGENTS.md passes"      run check
  printf '# rules\n' > AGENTS.md; run sync
  expect 1 "--canary fails without the canary" run check --canary
  for f in "${CONTROL_FILES[@]}"; do mkdir -p "$(dirname "$f")"; : >> "$f"; done
  g add -A && g commit -qm base
  g checkout -q -b agents-md-update-x && printf 'more\n' >> AGENTS.md && run sync && g commit -qam x
  expect 0 "gate passes on agents-md-update-x" run branch-gate main
  g checkout -q -b feature/x main && printf 'more\n' >> AGENTS.md && run sync && g commit -qam y
  expect 1 "gate fails on feature/x"          run branch-gate main
  for f in "${CONTROL_FILES[@]}"; do
    n=$((n+1))
    g checkout -q -b "feature/control-$n" main && printf 'control change\n' >> "$f" && g add "$f" && g commit -qm "control-$n"
    expect 1 "gate fails for $f on wrong branch" run branch-gate main
  done
  g checkout -q -b agents-md-update-unknown main && mkdir -p .cursor \
    && printf 'x\n' > .cursor/config.json && g add .cursor/config.json && g commit -qm unknown
  expect 1 "gate fails closed for unknown agent-instruction path" run branch-gate main
  g checkout -q -b feature/cursor main && mkdir -p .cursor/rules \
    && printf 'x\n' > .cursor/rules/new.md && g add .cursor && g commit -qm cursor
  expect 1 "gate fails for .cursor/rules on the wrong branch" run branch-gate main
  g checkout -q -b feature/y main && printf 'x\n' > other.txt && g add other.txt && g commit -qm z
  expect 0 "gate passes when no agent file changed" run branch-gate main
  g checkout -q -b agents-md-update-ci main && printf 'ci\n' >> AGENTS.md && run sync && g commit -qam ci
  expect 1 "CI rejects wrong actor"            run_ci gitjfmd/central-command mallory
  expect 1 "CI rejects fork head repo"         run_ci fork/central-command gitjfmd
  expect 1 "CI rejects missing head repo"      run_ci "" gitjfmd
  expect 1 "CI rejects missing actor"          run_ci gitjfmd/central-command ""
  TEST_ORIGIN_REPO= expect 1 "CI rejects missing origin repo" run_ci
  TEST_BASE_SHA= expect 1 "CI rejects missing base SHA" run_ci
  TEST_PR_HEAD_SHA= expect 1 "CI rejects missing head SHA" run_ci
  TEST_PR_HEAD_SHA=0000000000000000000000000000000000000000 expect 1 "CI rejects HEAD mismatch" run_ci
  expect 1 "CI still requires the branch signal" run_ci gitjfmd/central-command gitjfmd feature/ci
  expect 0 "CI accepts authorized same-repo actor" run_ci
  TEST_ACTORS= expect 1 "CI denies all actors when the actors var is empty" run_ci
  TEST_ACTORS='  gitjfmd ,,' expect 0 "CI trims actor entries and skips empties" run_ci
  mkdir "$t-nogit" && cd "$t-nogit" && printf '# rules\n' > AGENTS.md  # outside any repo
  expect 0 "sync works before git init"       run sync
  expect 0 "check passes before git init"     run check
  [ "$fails" -eq 0 ] && { say "selftest OK"; return 0; }
  say "selftest FAIL ($fails)"; return 1
}

case "${1:-}" in
  sync)        sync ;;
  check)       check "${2:-}" ;;
  branch-gate) branch_gate "${2:-}" ;;
  selftest)    selftest ;;
  *) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
