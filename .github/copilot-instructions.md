# Agent Instructions
<!-- scaffold-agent-files: no-generate -->

<!-- CANARY-GUARDRAILS-V1 -->

This file is the single hand-edited source for project context, rules, and instructions.

## Fleet guardrails

27. **SURGICAL CHANGES (Karpathy, CEO 2026-11-18).** When editing existing code, every changed line
    traces to the request; remove only orphans your change created. Never "improve", refactor or
    reformat adjacent code, and never delete dead code you did not create: mention it instead.
    Refs:
    1. /central-command/policies-procedures/compliance/policies/GUARDRAILS.md (44 Surgical changes)

28. **AGENTS.MD IS THE ONLY HAND-EDITED AGENT FILE (CEO 2026-11-18).** Edit only the repo-root
    `AGENTS.md`, only on a branch named `agents-md-update-<triggering-branch-slug>` (central-command
    off `dev`, other repos off `main`); `bash scripts/agents-md-guard.sh sync` then writes the copies
    (`QWEN.md`, `WARP.md`, `.clinerules/`, copilot, `GEMINI.md`) and the `CLAUDE.md` stub. Never
    hand-edit a copy. Any other branch touching these files: STOP-severity, CI `agents-md-guard` fails.
    The branch name is a workflow signal, not authorization; CI also requires a same-repo PR by an
    authorized actor and executes the guard from the protected base ref on GitHub-hosted runners.
    Refs:
    1. /central-command/policies-procedures/compliance/policies/GUARDRAILS.md (45 AGENTS.md is the only hand-edited agent file)
    2. /central-command/scripts/agents-md-guard.sh
    3. /central-command/policies-procedures/operations/procedures/PROJECT-SCAFFOLDING.md

## Project rules

stt-switch routes Claude Code voice mode to a local STT engine of your choice. Apple Silicon
native, MIT licensed, zero outbound traffic on the happy path: one env var
(`VOICE_STREAM_BASE_URL`) points `/voice` audio at a local WebSocket proxy that speaks the
Anthropic protocol, transcribed on device by one of 16 backends.

- Layout: `src/stt_switch/` (package: proxy and backends), `bin/`, `examples/`, `launch/`
  (launchd wiring), `docs/`.
- Python 3.10+; core deps websockets, numpy, soundfile; optional extras per backend
  (see `pyproject.toml`).
- `README.md` stays authoritative for product detail; this section is orientation only.
- This repo had no CLAUDE.md before the 2026-11-19 AGENTS.md rollout, so no prior agent
  file content was folded in here.
