#!/usr/bin/env bash
# install-git-hooks.sh — one-shot installer for this repo's git hooks.
#
# .git/hooks/ is NOT tracked by git, so each clone/worktree must install the
# managed hook once. This installs the pre-commit FRAMEWORK hook
# (.git/hooks/pre-commit), which runs every hook declared in
# .pre-commit-config.yaml:
#   • gitleaks            — secret scan (MANDATORY per SECRET-SCANNING.md)
#   • the hygiene checks  — yaml/json/large-file/merge-conflict/private-key/...
#   • agent-files-verify  — keeps the GENERATED agent rule files in sync with
#                           templates/AGENT-RULES-DIGEST.md (this task)
#
# The pre-commit hook is the PRIMARY, quota-proof enforcement layer; the
# .github/workflows/agent-files.yml CI job is belt-and-suspenders.
#
# Usage: bash scripts/install-git-hooks.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not inside a git repo" >&2; exit 1; }
cd "$REPO_ROOT" || exit 1

# prepare-commit-msg: stamps the per-CLI/per-session Agent-Session trailer onto agent commits.
# Plain hook, not a pre-commit-framework stage — `pre-commit install` (no -t) does not touch it.
# Hooks live in the COMMON git dir, so installing once also covers every worktree.
hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)"
if [ -n "$hooks_dir" ] && [ -r scripts/git-hooks/prepare-commit-msg ]; then
  mkdir -p "$hooks_dir" 2>/dev/null
  if cp scripts/git-hooks/prepare-commit-msg "$hooks_dir/prepare-commit-msg" 2>/dev/null; then
    chmod +x "$hooks_dir/prepare-commit-msg" 2>/dev/null
    echo "Installed prepare-commit-msg hook (per-CLI/per-session commit identity)."
  else
    echo "warn: could not install prepare-commit-msg into $hooks_dir (continuing)." >&2
  fi
fi

# --- HOME fallback refresh -----------------------------------------------------
# The identity lib resolves REPO copy first, $HOME/.local/lib second. Repos that do
# not ship scripts/agent-commit-identity.sh read the HOME copy, so refresh it from
# THIS repo's copy on every install: the fallback then tracks the source of truth
# instead of whichever repo happened to install last (CEO 2026-11-16:
# "whichever repo installs last wins --- that's not work that luck - we need a fix").
if [ -r scripts/agent-commit-identity.sh ]; then
  mkdir -p "$HOME/.local/lib" 2>/dev/null
  if cp scripts/agent-commit-identity.sh "$HOME/.local/lib/agent-commit-identity.sh" 2>/dev/null; then
    echo "Refreshed HOME fallback $HOME/.local/lib/agent-commit-identity.sh from this repo's copy."
  else
    echo "warn: could not refresh $HOME/.local/lib/agent-commit-identity.sh (continuing)." >&2
  fi
fi

# --- pre-commit framework hook (FIRST) -----------------------------------------
# ORDER MATTERS: `pre-commit install` REFUSES to run while core.hooksPath is set
# ("Cowardly refusing to install hooks with `core.hooksPath` set"), and it writes
# the hook into <git-common-dir>/hooks/. With the global dispatcher in place the
# repo's own hook is still reached: git runs the dispatcher (hooksPath), and the
# dispatcher chains to <git-common-dir>/hooks/<name>.
#
# So: unset core.hooksPath for the install call, then set it again below.
PC_STATUS=0
if command -v pre-commit >/dev/null 2>&1; then
  saved_hooks_path="$(git config --global --get core.hooksPath 2>/dev/null)"
  restore_hooks_path() {
    if [ -n "$saved_hooks_path" ]; then
      git config --global core.hooksPath "$saved_hooks_path" 2>/dev/null
    fi
  }
  trap restore_hooks_path EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -n "$saved_hooks_path" ]; then
    git config --global --unset-all core.hooksPath 2>/dev/null
  fi
  if pre-commit install; then
    echo "Installed pre-commit hooks (gitleaks + hygiene + agent-files-verify)."
  else
    echo "pre-commit install failed — see output above." >&2
    PC_STATUS=1
  fi
  restore_hooks_path
  trap - EXIT HUP INT TERM
else
  echo "pre-commit is not installed. Install it once, then re-run this script:" >&2
  echo "  pipx install pre-commit      # or: pip install --user pre-commit" >&2
  PC_STATUS=1
fi

# --- global dispatcher (chained-hook) -----------------------------------------
# ONE dispatcher for every repo on this Mac: ~/.config/git/hooks/chained-hook is installed
# once and every standard hook name in that directory is a symlink to it. It stamps the
# agent identity on prepare-commit-msg AND chains to each repo's own hook of the same
# name, so per-repo hooks keep working. Idempotent: re-running overwrites the
# dispatcher and re-points the symlinks; nothing is duplicated.
#
# ponytail: the hook-name list is the git hook-name set, nothing more.
GLOBAL_HOOKS_DIR="$HOME/.config/git/hooks"
GLOBAL_HOOK_LIST="applypatch-msg commit-msg fsmonitor-watchman p4-changelist p4-post-changelist p4-prepare-changelist post-applypatch post-checkout post-commit post-index-change post-merge post-receive post-rewrite post-update pre-applypatch pre-auto-gc pre-commit pre-merge-commit pre-push pre-rebase pre-receive prepare-commit-msg proc-receive push-to-checkout reference-transaction sendemail-validate update"

if [ -r scripts/git-hooks/chained-hook ]; then
  mkdir -p "$GLOBAL_HOOKS_DIR" 2>/dev/null
  if cp scripts/git-hooks/chained-hook "$GLOBAL_HOOKS_DIR/chained-hook" 2>/dev/null; then
    chmod +x "$GLOBAL_HOOKS_DIR/chained-hook" 2>/dev/null
    for h in $GLOBAL_HOOK_LIST; do
      ln -sf chained-hook "$GLOBAL_HOOKS_DIR/$h" 2>/dev/null
    done
    git config --global core.hooksPath "$GLOBAL_HOOKS_DIR" 2>/dev/null \
      && echo "Installed global hook dispatcher ($GLOBAL_HOOKS_DIR/chained-hook) + $(echo $GLOBAL_HOOK_LIST | wc -w | tr -d ' ') hook symlinks; core.hooksPath set." \
      || { echo "warn: could not set global core.hooksPath (continuing)." >&2; PC_STATUS=1; }
  else
    echo "warn: could not install chained-hook into $GLOBAL_HOOKS_DIR (continuing)." >&2
    PC_STATUS=1
  fi
fi

exit "$PC_STATUS"
