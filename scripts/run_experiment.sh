#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROFILE="${1:-${SUPERVISOR_PROMPT_PROFILE:-baseline}}"
CUSTOM_PROMPT_FILE="${2:-}"
case "$PROFILE" in
  baseline|improved) [[ -z "$CUSTOM_PROMPT_FILE" ]] || { echo "A custom file is only valid with profile custom" >&2; exit 2; } ;;
  custom)
    [[ -n "$CUSTOM_PROMPT_FILE" && -f "$CUSTOM_PROMPT_FILE" ]] || {
      echo "usage: $0 baseline|improved OR $0 custom CUSTOM_PROMPT_FILE" >&2
      exit 2
    }
    ;;
  *) echo "usage: $0 baseline|improved OR $0 custom CUSTOM_PROMPT_FILE" >&2; exit 2 ;;
esac

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

export SUPERVISOR_PROMPT_PROFILE="$PROFILE"
if [[ "$PROFILE" == "custom" ]]; then
  export SUPERVISOR_PROMPT_CUSTOM_FILE="$(cd "$(dirname "$CUSTOM_PROMPT_FILE")" && pwd)/$(basename "$CUSTOM_PROMPT_FILE")"
else
  unset SUPERVISOR_PROMPT_CUSTOM_FILE
  unset SUPERVISOR_PROMPT_CUSTOM
fi

case "${APP_MODEL_API_KEY_SOURCE:-}" in
  VLLM_API_KEY) export APP_MODEL_API_KEY="${VLLM_API_KEY:?VLLM_API_KEY is required}" ;;
  DASHSCOPE_API_KEY) export APP_MODEL_API_KEY="${DASHSCOPE_API_KEY:?DASHSCOPE_API_KEY is required}" ;;
  *) echo "Unsupported APP_MODEL_API_KEY_SOURCE" >&2; exit 2 ;;
esac

export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-splunk-ao-banking-qwen-demo-experiment}"
cd "$ROOT_DIR/app"
exec .venv/bin/python experiment.py
