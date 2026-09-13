#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.deploy.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.secrets/runtime.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-model.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-pinecone.env"
set +a

case "${APP_MODEL_API_KEY_SOURCE:-}" in
  VLLM_API_KEY)
    export APP_MODEL_API_KEY="${VLLM_API_KEY:?VLLM_API_KEY is required}"
    ;;
  DASHSCOPE_API_KEY)
    export APP_MODEL_API_KEY="${DASHSCOPE_API_KEY:?DASHSCOPE_API_KEY is required}"
    ;;
  *)
    echo "Unsupported APP_MODEL_API_KEY_SOURCE" >&2
    exit 2
    ;;
esac

export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-splunk-ao-banking-qwen-demo-local}"

cd "$ROOT_DIR/app"
exec .venv/bin/chainlit run app.py -h --host 127.0.0.1 --port "${PORT:-8000}"
