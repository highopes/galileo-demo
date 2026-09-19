#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load_galileo_config.sh"

export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-splunk-ao-banking-qwen-demo-local}"

cd "$ROOT_DIR/app"
exec .venv/bin/chainlit run app.py -h --host 127.0.0.1 --port "${PORT:-8000}"
