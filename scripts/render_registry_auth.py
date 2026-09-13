#!/usr/bin/env python3
"""Write a temporary Docker registry auth file without printing credentials."""

from __future__ import annotations

import base64
import json
import os
import sys
from pathlib import Path


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value or "\n" in value or "\r" in value:
        raise ValueError(f"{name} is missing or invalid")
    return value


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: render_registry_auth.py OUTPUT", file=sys.stderr)
        return 2
    registry = required("REGISTRY_SERVER")
    username = required("REGISTRY_USERNAME")
    password = required("REGISTRY_PASSWORD")
    auth = base64.b64encode(f"{username}:{password}".encode()).decode()
    payload = {"auths": {registry: {"username": username, "password": password, "auth": auth}}}
    destination = Path(sys.argv[1])
    destination.write_text(json.dumps(payload), encoding="utf-8")
    destination.chmod(0o600)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
