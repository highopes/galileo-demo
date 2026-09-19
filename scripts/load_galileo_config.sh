# Source this file from a repository script after defining ROOT_DIR.
# It maps the shared GALILEO_* operator contract to the application's runtime
# environment without introducing a second configuration file.

[[ -n "${ROOT_DIR:-}" ]] || {
  echo "ROOT_DIR must be set before sourcing load_galileo_config.sh" >&2
  return 2
}

config_file="${KUP_CONFIG:-$ROOT_DIR/kup.conf}"
[[ -f "$config_file" ]] || {
  echo "Private config not found: $config_file; copy kup.conf.example to kup.conf first" >&2
  return 2
}

SCRIPT_DIR="${SCRIPT_DIR:-$ROOT_DIR}"
set -a
# shellcheck disable=SC1090
source "$config_file"
set +a

for config_name in \
  GALILEO_SPLUNK_AO_API_KEY GALILEO_SPLUNK_AO_PROJECT \
  GALILEO_SPLUNK_AO_AGENT_STREAM GALILEO_SPLUNK_AO_CONSOLE_URL \
  GALILEO_APP_MODEL_PROVIDER GALILEO_APP_MODEL_NAME GALILEO_APP_MODEL_BASE_URL \
  GALILEO_APP_MODEL_API_KEY GALILEO_MODEL_REQUEST_TIMEOUT GALILEO_MODEL_MAX_RETRIES \
  GALILEO_PINECONE_API_KEY GALILEO_PINECONE_INDEX_NAME GALILEO_PINECONE_NAMESPACE \
  GALILEO_PINECONE_TEXT_FIELD GALILEO_SPLUNK_AO_EXPERIMENT_EVALUATORS \
  GALILEO_SUPERVISOR_PROMPT_PROFILE GALILEO_BASELINE_PROMPT_VARIANT; do
  config_value="${!config_name:-}"
  [[ -n "$config_value" && "$config_value" != "ReplaceMe" ]] || {
    echo "Required setting is empty or still a placeholder: $config_name" >&2
    return 2
  }
done
unset config_name config_value

export SPLUNK_AO_API_KEY="$GALILEO_SPLUNK_AO_API_KEY"
export SPLUNK_AO_PROJECT="$GALILEO_SPLUNK_AO_PROJECT"
export SPLUNK_AO_AGENT_STREAM="$GALILEO_SPLUNK_AO_AGENT_STREAM"
export SPLUNK_AO_CONSOLE_URL="$GALILEO_SPLUNK_AO_CONSOLE_URL"
export APP_MODEL_PROVIDER="$GALILEO_APP_MODEL_PROVIDER"
export APP_MODEL_NAME="$GALILEO_APP_MODEL_NAME"
export APP_MODEL_BASE_URL="$GALILEO_APP_MODEL_BASE_URL"
export APP_MODEL_API_KEY="$GALILEO_APP_MODEL_API_KEY"
export MODEL_REQUEST_TIMEOUT="$GALILEO_MODEL_REQUEST_TIMEOUT"
export MODEL_MAX_RETRIES="$GALILEO_MODEL_MAX_RETRIES"
export PINECONE_API_KEY="$GALILEO_PINECONE_API_KEY"
export PINECONE_INDEX_NAME="$GALILEO_PINECONE_INDEX_NAME"
export PINECONE_NAMESPACE="$GALILEO_PINECONE_NAMESPACE"
export PINECONE_TEXT_FIELD="$GALILEO_PINECONE_TEXT_FIELD"
export SPLUNK_AO_EXPERIMENT_EVALUATORS="$GALILEO_SPLUNK_AO_EXPERIMENT_EVALUATORS"
export SPLUNK_AO_EXPERIMENT_DATASET="${GALILEO_SPLUNK_AO_EXPERIMENT_DATASET:-}"

case "$GALILEO_SUPERVISOR_PROMPT_PROFILE:$GALILEO_BASELINE_PROMPT_VARIANT" in
  baseline:qwen)
    export SUPERVISOR_PROMPT_PROFILE="custom"
    export SUPERVISOR_PROMPT_CUSTOM_FILE="$ROOT_DIR/app/prompts/supervisor-baseline-qwen.txt"
    ;;
  baseline:official)
    export SUPERVISOR_PROMPT_PROFILE="baseline"
    unset SUPERVISOR_PROMPT_CUSTOM_FILE SUPERVISOR_PROMPT_CUSTOM
    ;;
  improved:*)
    export SUPERVISOR_PROMPT_PROFILE="improved"
    unset SUPERVISOR_PROMPT_CUSTOM_FILE SUPERVISOR_PROMPT_CUSTOM
    ;;
  *)
    echo "Unsupported GALILEO prompt selection" >&2
    return 2
    ;;
esac
