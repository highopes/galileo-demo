#!/usr/bin/env python3
"""Render a ConfigMap merge patch for a built-in or custom prompt profile."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) not in {3, 4}:
        print("usage: render_prompt_patch.py PROFILE OUTPUT [CUSTOM_PROMPT_FILE]", file=sys.stderr)
        return 2
    profile = sys.argv[1]
    output = Path(sys.argv[2])
    if profile not in {"baseline", "improved", "custom"}:
        print("PROFILE must be baseline, improved, or custom", file=sys.stderr)
        return 2

    custom_prompt = ""
    if profile == "custom":
        if len(sys.argv) != 4:
            print("custom profile requires CUSTOM_PROMPT_FILE", file=sys.stderr)
            return 2
        source = Path(sys.argv[3])
        if not source.is_file():
            print(f"custom prompt file does not exist: {source}", file=sys.stderr)
            return 2
        custom_prompt = source.read_text(encoding="utf-8").strip()
        if not custom_prompt:
            print("custom prompt file is empty", file=sys.stderr)
            return 2
        if len(custom_prompt.encode("utf-8")) > 100_000:
            print("custom prompt must be no larger than 100 KiB", file=sys.stderr)
            return 2
    elif len(sys.argv) != 3:
        print("CUSTOM_PROMPT_FILE is only valid with the custom profile", file=sys.stderr)
        return 2

    patch = {
        "data": {
            "SUPERVISOR_PROMPT_PROFILE": profile,
            "SUPERVISOR_PROMPT_CUSTOM": custom_prompt,
        }
    }
    output.write_text(json.dumps(patch, ensure_ascii=False), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
