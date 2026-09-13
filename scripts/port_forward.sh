#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT_DIR/scripts/discover_ack.sh" >/dev/null
# shellcheck disable=SC1091
source "$ROOT_DIR/.deploy.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-ack.env"

exec kubectl --kubeconfig "$ACK_KUBECONFIG" --context "$ACK_CONTEXT" \
  -n "$ACK_NAMESPACE" port-forward service/splunk-ao-banking-qwen "${LOCAL_PORT:-8000}:80"
