#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${GENERIC_K8S_ENV_FILE:-$ROOT_DIR/.secrets/generic-k8s.env}"

if [[ "${GENERIC_K8S_USE_ENV:-0}" == "1" ]]; then
  config_source="the current environment"
else
  [[ -f "$CONFIG_FILE" ]] || {
    echo "Generic Kubernetes configuration not found: $CONFIG_FILE" >&2
    echo "Create it from the README example or set GENERIC_K8S_ENV_FILE." >&2
    exit 2
  }
  set -a
  # This is an operator-owned local configuration file and must remain outside Git.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set +a
  config_source="$CONFIG_FILE"
fi

KUBE_NAMESPACE="${KUBE_NAMESPACE:-galileo-demo}"
SPLUNK_AO_CONSOLE_URL="${SPLUNK_AO_CONSOLE_URL:-https://console.multitenant.galileocloud.io}"
MODEL_REQUEST_TIMEOUT="${MODEL_REQUEST_TIMEOUT:-120}"
MODEL_MAX_RETRIES="${MODEL_MAX_RETRIES:-2}"
PINECONE_NAMESPACE="${PINECONE_NAMESPACE:-bank-docs}"
PINECONE_TEXT_FIELD="${PINECONE_TEXT_FIELD:-chunk_text}"
SPLUNK_AO_EXPERIMENT_EVALUATORS="${SPLUNK_AO_EXPERIMENT_EVALUATORS:-Action Advancement - Qwen,Action Completion - Qwen,Tool Errors - Qwen,Tool Selection Quality - Qwen}"
SPLUNK_AO_EXPERIMENT_DATASET="${SPLUNK_AO_EXPERIMENT_DATASET:-ReplaceMe}"
SUPERVISOR_PROMPT_PROFILE="${SUPERVISOR_PROMPT_PROFILE:-baseline}"
ACK_NAMESPACE="$KUBE_NAMESPACE"
export KUBE_NAMESPACE SPLUNK_AO_CONSOLE_URL MODEL_REQUEST_TIMEOUT MODEL_MAX_RETRIES
export PINECONE_NAMESPACE PINECONE_TEXT_FIELD SPLUNK_AO_EXPERIMENT_EVALUATORS
export SPLUNK_AO_EXPERIMENT_DATASET SUPERVISOR_PROMPT_PROFILE ACK_NAMESPACE

for name in KUBE_CONTEXT IMAGE_REF SPLUNK_AO_PROJECT SPLUNK_AO_AGENT_STREAM \
  SPLUNK_AO_API_KEY APP_MODEL_PROVIDER APP_MODEL_NAME APP_MODEL_BASE_URL \
  APP_MODEL_API_KEY PINECONE_API_KEY PINECONE_INDEX_NAME; do
  [[ -n "${!name:-}" && "${!name}" != "ReplaceMe" ]] || {
    echo "$name is required in $config_source" >&2
    exit 2
  }
done

[[ "$SUPERVISOR_PROMPT_PROFILE" == "baseline" || "$SUPERVISOR_PROMPT_PROFILE" == "improved" ]] || {
  echo "Fresh generic deployment profile must be baseline or improved; use switch_prompt.sh for custom prompts." >&2
  exit 2
}

if [[ -n "${KUBECONFIG_FILE:-}" ]]; then
  [[ -f "$KUBECONFIG_FILE" ]] || { echo "KUBECONFIG_FILE does not exist" >&2; exit 2; }
  kctl=(kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$KUBE_CONTEXT")
else
  kctl=(kubectl --context "$KUBE_CONTEXT")
fi

"${kctl[@]}" version >/dev/null
"${kctl[@]}" auth can-i create deployments -n "$KUBE_NAMESPACE" >/dev/null

mkdir -p "$ROOT_DIR/.runtime"
rendered_dir="$(mktemp -d "$ROOT_DIR/.runtime/k8s-generic-rendered.XXXXXX")"
runtime_secret_file="$(mktemp "$ROOT_DIR/.runtime/generic-runtime-secret.XXXXXX")"
registry_auth_file="$(mktemp "$ROOT_DIR/.runtime/generic-dockerconfigjson.XXXXXX")"
cleanup() {
  rm -f "$runtime_secret_file" "$registry_auth_file"
  rm -f "$rendered_dir/namespace.yaml" "$rendered_dir/configmap.yaml" "$rendered_dir/deployment.yaml" "$rendered_dir/service.yaml"
  rmdir "$rendered_dir" 2>/dev/null || true
}
trap cleanup EXIT
chmod 0600 "$runtime_secret_file" "$registry_auth_file"

for manifest in namespace configmap deployment service; do
  "$ROOT_DIR/scripts/render_k8s.py" \
    "$ROOT_DIR/deploy/k8s/${manifest}.yaml" "$rendered_dir/${manifest}.yaml"
done

{
  printf 'SPLUNK_AO_API_KEY=%s\n' "$SPLUNK_AO_API_KEY"
  printf 'APP_MODEL_API_KEY=%s\n' "$APP_MODEL_API_KEY"
  printf 'PINECONE_API_KEY=%s\n' "$PINECONE_API_KEY"
} >"$runtime_secret_file"

if [[ -n "${REGISTRY_SERVER:-}${REGISTRY_USERNAME:-}${REGISTRY_PASSWORD:-}" ]]; then
  for name in REGISTRY_SERVER REGISTRY_USERNAME REGISTRY_PASSWORD; do
    [[ -n "${!name:-}" ]] || { echo "$name is required when private registry auth is configured" >&2; exit 2; }
  done
  export REGISTRY_SERVER REGISTRY_USERNAME REGISTRY_PASSWORD
  "$ROOT_DIR/scripts/render_registry_auth.py" "$registry_auth_file"
else
  printf '{"auths":{}}' >"$registry_auth_file"
fi

"${kctl[@]}" apply -f "$rendered_dir/namespace.yaml"
"${kctl[@]}" -n "$KUBE_NAMESPACE" create secret generic splunk-ao-banking-qwen-runtime \
  --from-env-file="$runtime_secret_file" --dry-run=client -o yaml | "${kctl[@]}" apply -f -
"${kctl[@]}" -n "$KUBE_NAMESPACE" create secret generic registry-pull \
  --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$registry_auth_file" \
  --dry-run=client -o yaml | "${kctl[@]}" apply -f -
"${kctl[@]}" apply -f "$rendered_dir/configmap.yaml"
"${kctl[@]}" apply -f "$rendered_dir/deployment.yaml"
"${kctl[@]}" apply -f "$rendered_dir/service.yaml"
"${kctl[@]}" -n "$KUBE_NAMESPACE" rollout status deployment/splunk-ao-banking-qwen --timeout=10m
"${kctl[@]}" -n "$KUBE_NAMESPACE" get deployment,pod,service \
  -l app.kubernetes.io/name=splunk-ao-banking-qwen -o wide

echo "Generic Kubernetes deployment complete."
echo "Prompt profile: $SUPERVISOR_PROMPT_PROFILE"
echo "Run scripts/switch_prompt.sh with KUBE_CONTEXT/KUBECONFIG_FILE/KUBE_NAMESPACE to switch profiles."
