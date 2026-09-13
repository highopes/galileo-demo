#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/discover_ack.sh"

set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.deploy.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-model.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-pinecone.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-ack.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/image.env"
# Prefer the ACR copy when it has been resolved.
if [[ -f "$ROOT_DIR/.runtime/acr-image.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.runtime/acr-image.env"
fi
# shellcheck disable=SC1091
source "$ROOT_DIR/.secrets/runtime.env"
if [[ -f "$ROOT_DIR/.secrets/dockerhub.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.secrets/dockerhub.env"
fi
if [[ -f "$ROOT_DIR/.secrets/acr.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.secrets/acr.env"
fi
set +a

case "${APP_MODEL_API_KEY_SOURCE:-}" in
  VLLM_API_KEY) export APP_MODEL_API_KEY="${VLLM_API_KEY:?VLLM_API_KEY is required}" ;;
  DASHSCOPE_API_KEY) export APP_MODEL_API_KEY="${DASHSCOPE_API_KEY:?DASHSCOPE_API_KEY is required}" ;;
  *) echo "Unsupported APP_MODEL_API_KEY_SOURCE" >&2; exit 2 ;;
esac

for name in SPLUNK_AO_API_KEY APP_MODEL_API_KEY PINECONE_API_KEY; do
  [[ -n "${!name:-}" ]] || { echo "$name is required" >&2; exit 2; }
  [[ "${!name}" != *$'\n'* && "${!name}" != *$'\r'* ]] || { echo "$name contains an unsupported newline" >&2; exit 2; }
done

export IMAGE_REF="${1:-${ACR_IMAGE_IMMUTABLE_REF:-$IMAGE_IMMUTABLE_REF}}"
[[ "$IMAGE_REF" == *@sha256:* || "$IMAGE_REF" == *:* ]] || { echo "An image tag or digest is required" >&2; exit 2; }

if [[ -n "${ACR_REGISTRY:-}" && "$IMAGE_REF" == "$ACR_REGISTRY"/* ]]; then
  export REGISTRY_SERVER="$ACR_REGISTRY"
  export REGISTRY_USERNAME="${ACR_USERNAME:?ACR_USERNAME is required}"
  export REGISTRY_PASSWORD="${ACR_PASSWORD:?ACR_PASSWORD is required}"
elif [[ "$IMAGE_REF" == "$DOCKERHUB_REPOSITORY"* ]]; then
  export REGISTRY_SERVER="https://index.docker.io/v1/"
  export REGISTRY_USERNAME="${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME is required}"
  export REGISTRY_PASSWORD="${DOCKERHUB_PAT:?DOCKERHUB_PAT is required}"
else
  echo "No configured registry credentials match IMAGE_REF" >&2
  exit 2
fi

rendered_dir="$(mktemp -d "$ROOT_DIR/.runtime/k8s-rendered.XXXXXX")"
runtime_secret_file="$(mktemp "$ROOT_DIR/.runtime/runtime-secret.XXXXXX")"
registry_auth_file="$(mktemp "$ROOT_DIR/.runtime/dockerconfigjson.XXXXXX")"
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
"$ROOT_DIR/scripts/render_registry_auth.py" "$registry_auth_file"

kctl=(kubectl --kubeconfig "$ACK_KUBECONFIG" --context "$ACK_CONTEXT")
"${kctl[@]}" apply -f "$rendered_dir/namespace.yaml"
"${kctl[@]}" -n "$ACK_NAMESPACE" create secret generic splunk-ao-banking-qwen-runtime \
  --from-env-file="$runtime_secret_file" --dry-run=client -o yaml | "${kctl[@]}" apply -f -
"${kctl[@]}" -n "$ACK_NAMESPACE" create secret generic registry-pull \
  --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$registry_auth_file" \
  --dry-run=client -o yaml | "${kctl[@]}" apply -f -
"${kctl[@]}" apply -f "$rendered_dir/configmap.yaml"
"${kctl[@]}" apply -f "$rendered_dir/deployment.yaml"
"${kctl[@]}" apply -f "$rendered_dir/service.yaml"

"${kctl[@]}" -n "$ACK_NAMESPACE" rollout status deployment/splunk-ao-banking-qwen --timeout=10m
"${kctl[@]}" -n "$ACK_NAMESPACE" get deployment,pod,service -l app.kubernetes.io/name=splunk-ao-banking-qwen -o wide

deployment_file="$(mktemp "$ROOT_DIR/.runtime/deployment.env.XXXXXX")"
{
  printf 'DEPLOYED_IMAGE=%q\n' "$IMAGE_REF"
  printf 'DEPLOYED_NAMESPACE=%q\n' "$ACK_NAMESPACE"
  printf 'DEPLOYED_AT_UTC=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$deployment_file"
chmod 0600 "$deployment_file"
mv "$deployment_file" "$ROOT_DIR/.runtime/deployment.env"
