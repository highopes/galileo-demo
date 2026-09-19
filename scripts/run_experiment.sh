#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load_galileo_config.sh"

if [[ "$#" -eq 0 ]]; then
  PROFILE="${SUPERVISOR_PROMPT_PROFILE:-baseline}"
  CUSTOM_PROMPT_FILE="${SUPERVISOR_PROMPT_CUSTOM_FILE:-}"
else
  PROFILE="$1"
  CUSTOM_PROMPT_FILE="${2:-}"
fi
[[ "$#" -le 2 ]] || {
  echo "usage: $0 baseline|improved OR $0 custom CUSTOM_PROMPT_FILE" >&2
  exit 2
}
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

export SUPERVISOR_PROMPT_PROFILE="$PROFILE"
if [[ "$PROFILE" == "custom" ]]; then
  export SUPERVISOR_PROMPT_CUSTOM_FILE="$(cd "$(dirname "$CUSTOM_PROMPT_FILE")" && pwd)/$(basename "$CUSTOM_PROMPT_FILE")"
else
  unset SUPERVISOR_PROMPT_CUSTOM_FILE
  unset SUPERVISOR_PROMPT_CUSTOM
fi

export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-splunk-ao-banking-qwen-demo-experiment}"
cd "$ROOT_DIR/app"
exec .venv/bin/python experiment.py
