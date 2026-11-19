# Worktree brief — agents-md-update-agents-reader-lean

> **Read this first.** Execution brief for any agent/CLI working in this worktree.
> Branch: `agents-md-update-agents-reader-lean` (off `origin/main`). Repo: stt-switch.
> Full rules: ./AGENTS.md  ·  guardrails: ./CLAUDE.local.md

## Scope / goal
AGENTS.md rollout: repo-root AGENTS.md becomes the only hand-edited agent file
(GUARDRAILS § 45). Deliverables: (a) AGENTS.md with the two fleet nutshell rules
(§ 44 surgical changes, § 45 AGENTS.md ownership) and the byte copies + CLAUDE.md
stub written by sync; (b) .github/workflows/agents-md-guard.yml; (c)
scripts/agents-md-guard.sh; (d) provenance stamp in the PR body. The guard-only
bootstrap [#3](https://github.com/gitjfmd/stt-switch/pull/3) lands the script on
`main` first; this PR waits for it.

## Build / verify
- `bash scripts/agents-md-guard.sh sync` (idempotent)
- `bash scripts/agents-md-guard.sh check --canary`
- `bash scripts/agents-md-guard.sh selftest`
- `bash scripts/agents-md-guard.sh branch-gate origin/main`
- PR body passes `scripts/check-pr-stamp.sh`

## Done = PR to `main` (when complete & usable), then teardown.
