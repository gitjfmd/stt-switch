#!/usr/bin/env python3
"""stt-switch — flip the cc-voice-proxy backend in one command.

Reads the current ``CC_STT_PROFILE`` from
``~/Library/LaunchAgents/com.local.cc-voice-proxy.plist``,
optionally rewrites it, and reloads the launchd agent.

Usage:
    stt-switch                       # interactive picker (shows current + menu)
    stt-switch list                  # list available profiles
    stt-switch current               # show what's running now
    stt-switch <profile>             # set + reload (e.g. stt-switch remote-chain)
    stt-switch bench                 # run stt-bench.py over the catalog
    stt-switch reload                # reload without changing the profile

Exits non-zero if the proxy fails to come back healthy after a swap.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SCRIPT = Path(__file__).resolve()
STT_ROOT = SCRIPT.parent.parent
from stt_switch import backends as _backends_module

PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / "com.local.cc-voice-proxy.plist"
HEALTH_URL = "http://127.0.0.1:8113/health"


def _load_profiles():
    from stt_switch.backends import PROFILES

    return list(PROFILES.keys())


def _read_plist() -> str:
    if not PLIST_PATH.exists():
        sys.exit(f"plist not found at {PLIST_PATH} — run STT/bin/wire-cc-voice.sh first")
    return PLIST_PATH.read_text(encoding="utf-8")


def _current_profile() -> str:
    text = _read_plist()
    # Find the <string> right after <key>CC_STT_PROFILE</key>.
    m = re.search(r"<key>CC_STT_PROFILE</key>\s*<string>([^<]+)</string>", text)
    return m.group(1) if m else "(unset)"


def _set_profile(profile: str) -> None:
    text = _read_plist()
    # Two cases: key already present (replace), or missing (append into env block).
    if re.search(r"<key>CC_STT_PROFILE</key>\s*<string>[^<]+</string>", text):
        new = re.sub(
            r"(<key>CC_STT_PROFILE</key>\s*<string>)[^<]+(</string>)",
            rf"\g<1>{profile}\g<2>",
            text,
        )
    else:
        # Insert before the EnvironmentVariables closing </dict>. Best-effort —
        # if the plist is hand-edited weirdly, fall back to appending plain.
        snippet = (
            f"    <key>CC_STT_PROFILE</key>\n    <string>{profile}</string>\n"
        )
        if "<key>EnvironmentVariables</key>" in text:
            new = re.sub(
                r"(<key>EnvironmentVariables</key>\s*<dict>(?:.|\n)*?)(\s*</dict>)",
                rf"\1{snippet}\2",
                text,
                count=1,
            )
        else:
            sys.exit("plist has no EnvironmentVariables dict; refusing to corrupt it")
    PLIST_PATH.write_text(new, encoding="utf-8")


def _reload_agent() -> None:
    subprocess.run(
        ["launchctl", "unload", "-w", str(PLIST_PATH)], check=False, capture_output=True
    )
    subprocess.run(["launchctl", "load", "-w", str(PLIST_PATH)], check=True, capture_output=True)


def _wait_healthy(timeout_s: float = 30.0) -> dict | None:
    deadline = time.monotonic() + timeout_s
    last_err = None
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(HEALTH_URL, timeout=1.5) as r:
                import json as _json

                return _json.loads(r.read())
        except (urllib.error.URLError, OSError) as e:
            last_err = e
            time.sleep(0.5)
    print(f"  health probe never returned 200 (last error: {last_err})", file=sys.stderr)
    return None


# ── Pretty output ───────────────────────────────────────────────────


def _color_supported() -> bool:
    return sys.stdout.isatty() and os.environ.get("TERM", "") != "dumb"


_C = {
    "reset": "\033[0m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "green": "\033[1;38;5;120m",
    "yellow": "\033[1;38;5;220m",
    "cyan": "\033[1;38;5;45m",
    "red": "\033[1;38;5;203m",
    "magenta": "\033[1;38;5;213m",
}


def col(name: str, s: str) -> str:
    if not _color_supported():
        return s
    return f"{_C.get(name, '')}{s}{_C['reset']}"


# ── Commands ────────────────────────────────────────────────────────


def cmd_list(args):  # noqa: ARG001
    profiles = _load_profiles()
    current = _current_profile()
    print(f"Current: {col('cyan', current)}\n")
    for p in profiles:
        marker = col("green", "▸ ") if p == current else "  "
        print(f"{marker}{p}")
    return 0


def cmd_current(args):  # noqa: ARG001
    print(_current_profile())
    return 0


def cmd_set(args):
    profiles = _load_profiles()
    target = args.profile
    if target not in profiles:
        # Allow loose match: substring case-insensitive
        candidates = [p for p in profiles if target.lower() in p.lower()]
        if len(candidates) == 1:
            target = candidates[0]
        elif len(candidates) > 1:
            print(col("red", "ambiguous match. candidates:"))
            for c in candidates:
                print(f"  {c}")
            return 1
        else:
            print(col("red", f"unknown profile {args.profile!r}"))
            print(f"Run {col('bold', 'stt-switch list')} to see all.")
            return 1

    current = _current_profile()
    if target == current:
        print(f"Already on {col('cyan', target)}.")
        return 0

    print(f"Switching {col('dim', current)} → {col('green', target)}")
    _set_profile(target)
    _reload_agent()
    print("  reloading launchd agent...")
    health = _wait_healthy()
    if not health:
        return 2
    print(f"  {col('green', '✓')} backend now: {col('cyan', health.get('backend', '?'))}")
    return 0


def cmd_reload(args):  # noqa: ARG001
    print("reloading launchd agent...")
    _reload_agent()
    health = _wait_healthy()
    if not health:
        return 2
    print(f"  {col('green', '✓')} backend: {col('cyan', health.get('backend', '?'))}")
    return 0


def cmd_bench(args):  # noqa: ARG001
    bench = STT_ROOT / "bin" / "stt-bench.py"
    if not bench.exists():
        sys.exit(f"missing {bench}")
    venv_py = Path.home() / ".hermes/hermes-agent/venv/bin/python"
    py = str(venv_py) if venv_py.exists() else sys.executable
    return subprocess.call([py, str(bench), "-p", "all"])


def cmd_interactive(args):  # noqa: ARG001
    profiles = _load_profiles()
    current = _current_profile()
    print(col("bold", "STT backend switcher"))
    print(f"Current: {col('cyan', current)}\n")
    for i, p in enumerate(profiles, 1):
        marker = col("green", "▸") if p == current else " "
        print(f"  {marker} {i:>2}. {p}")
    print()
    try:
        choice = input("Pick a number (or blank to cancel): ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        return 0
    if not choice:
        print("cancelled.")
        return 0
    if not choice.isdigit() or not (1 <= int(choice) <= len(profiles)):
        print(col("red", "invalid choice"))
        return 1
    args = argparse.Namespace(profile=profiles[int(choice) - 1])
    return cmd_set(args)


def main(argv: list[str] | None = None) -> int:
    """Dispatcher. Accepts:
        stt-switch                  (interactive)
        stt-switch list|current|reload|bench
        stt-switch set <profile>
        stt-switch <profile>        (shortcut)
    Custom dispatch (no subparser) so a profile name like "mlx-chain" isn't
    misinterpreted as an unknown subcommand.
    """
    args = list(argv or sys.argv[1:])
    if "-h" in args or "--help" in args:
        print(__doc__.strip())
        return 0
    if not args:
        return cmd_interactive(argparse.Namespace())
    head = args[0]
    if head == "list":
        return cmd_list(argparse.Namespace())
    if head == "current":
        return cmd_current(argparse.Namespace())
    if head == "reload":
        return cmd_reload(argparse.Namespace())
    if head == "bench":
        return cmd_bench(argparse.Namespace())
    if head == "set":
        if len(args) < 2:
            sys.exit("usage: stt-switch set <profile>")
        return cmd_set(argparse.Namespace(profile=args[1]))
    # Bare `stt-switch <profile>` shortcut
    return cmd_set(argparse.Namespace(profile=head))


if __name__ == "__main__":
    sys.exit(main())
