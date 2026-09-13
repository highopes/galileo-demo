#!/usr/bin/env python3
"""Render a non-secret Kubernetes manifest template from environment values."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from string import Template


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: render_k8s.py INPUT OUTPUT", file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    destination.write_text(Template(source.read_text(encoding="utf-8")).substitute(os.environ), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
