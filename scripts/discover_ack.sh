#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/.deploy.env"

die() {
  echo "ACK DISCOVERY STOP: $*" >&2
  exit 2
}

for command_name in git terraform kubectl; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done

[[ -d "${ACK_BYOCNI_DIR:-}" ]] || die "ACK_BYOCNI_DIR is not a directory"
[[ -d "$ACK_BYOCNI_DIR/.git" ]] || die "ACK_BYOCNI_DIR is not the expected Git working clone"

echo "ACK infrastructure working tree (read-only inventory):"
git -C "$ACK_BYOCNI_DIR" status --short

if ! terraform -chdir="$ACK_BYOCNI_DIR" state list | grep -Fxq "alicloud_cs_managed_kubernetes.demo"; then
  if [[ "${ALLOW_ACK_CREATE:-0}" == "1" ]]; then
    die "Terraform has no active ACK cluster. Run the infrastructure repository's supported ./kup entrypoint first."
  fi
  die "Current ACK BYOCNI Terraform state has no active cluster and ALLOW_ACK_CREATE=0"
fi

cluster_id="$(terraform -chdir="$ACK_BYOCNI_DIR" output -raw cluster_id)"
cluster_name="$(terraform -chdir="$ACK_BYOCNI_DIR" output -raw cluster_name)"
kubernetes_version="$(terraform -chdir="$ACK_BYOCNI_DIR" output -raw kubernetes_version)"
[[ -n "$cluster_id" && -n "$cluster_name" && -n "$kubernetes_version" ]] || die "Terraform ACK outputs are incomplete"

context_name="${ACK_CONTEXT:-ack-byocni-demo}"
kubeconfig_path="$ACK_BYOCNI_DIR/kubeconfig"

has_expected_context() {
  local candidate="$1"
  [[ -s "$candidate" ]] &&
    kubectl --kubeconfig "$candidate" config get-contexts -o name 2>/dev/null |
      grep -Fxq "$context_name"
}

api_is_ready() {
  local candidate="$1"
  has_expected_context "$candidate" &&
    kubectl --kubeconfig "$candidate" --context "$context_name" \
      --request-timeout=15s get --raw=/readyz >/dev/null 2>&1
}

regenerate_kubeconfig() {
  local response_file target_file original_context
  command -v aliyun >/dev/null 2>&1 || die "aliyun CLI is required to regenerate kubeconfig"
  [[ -f "$ROOT_DIR/.secrets/alicloud.env" ]] || die ".secrets/alicloud.env is required to regenerate kubeconfig"

  # shellcheck disable=SC1091
  set -a
  source "$ROOT_DIR/.secrets/alicloud.env"
  set +a
  export ALIBABA_CLOUD_IGNORE_PROFILE=TRUE
  if [[ -z "${ALIBABA_CLOUD_REGION_ID:-}" && -n "${ALIBABA_CLOUD_REGION:-}" ]]; then
    export ALIBABA_CLOUD_REGION_ID="$ALIBABA_CLOUD_REGION"
  fi

  response_file="$(mktemp "$ROOT_DIR/.runtime/ack-kubeconfig-response.XXXXXX")"
  target_file="$ROOT_DIR/.secrets/ack-kubeconfig"
  trap 'rm -f "${response_file:-}"' RETURN

  aliyun cs GET "/k8s/${cluster_id}/user_config" >"$response_file"
  python3 - "$response_file" "$target_file" <<'PY'
import json
import os
import sys

source, destination = sys.argv[1:]
with open(source, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
config = payload.get("config")
if not isinstance(config, str) or not config.strip():
    raise SystemExit("ACK kubeconfig API response did not contain config")
temporary = destination + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    handle.write(config)
os.chmod(temporary, 0o600)
os.replace(temporary, destination)
PY

  original_context="$(kubectl --kubeconfig "$target_file" config current-context)"
  [[ -n "$original_context" ]] || die "Regenerated kubeconfig has no current context"
  if [[ "$original_context" != "$context_name" ]]; then
    kubectl --kubeconfig "$target_file" config rename-context "$original_context" "$context_name" >/dev/null
  fi
  kubectl --kubeconfig "$target_file" config use-context "$context_name" >/dev/null
  chmod 0600 "$target_file"
  kubeconfig_path="$target_file"
}

if ! api_is_ready "$kubeconfig_path"; then
  echo "Repository kubeconfig is missing or stale; obtaining the current cluster credential through ACK OpenAPI." >&2
  regenerate_kubeconfig
fi

api_is_ready "$kubeconfig_path" || die "Current ACK API is unreachable through the dynamically selected kubeconfig"

mkdir -p "$ROOT_DIR/.runtime"
resolved_file="$(mktemp "$ROOT_DIR/.runtime/resolved-ack.env.XXXXXX")"
{
  printf 'ACK_CLUSTER_ID=%q\n' "$cluster_id"
  printf 'ACK_CLUSTER_NAME=%q\n' "$cluster_name"
  printf 'ACK_KUBERNETES_VERSION=%q\n' "$kubernetes_version"
  printf 'ACK_KUBECONFIG=%q\n' "$kubeconfig_path"
  printf 'ACK_CONTEXT=%q\n' "$context_name"
} >"$resolved_file"
chmod 0600 "$resolved_file"
mv "$resolved_file" "$ROOT_DIR/.runtime/resolved-ack.env"

echo "Resolved ACK cluster ID: $cluster_id"
echo "Resolved ACK cluster name: $cluster_name"
echo "Terraform Kubernetes version: $kubernetes_version"
echo "Private kubeconfig: $kubeconfig_path"
echo "Explicit context: $context_name"

kubectl --kubeconfig "$kubeconfig_path" --context "$context_name" cluster-info
kubectl --kubeconfig "$kubeconfig_path" --context "$context_name" \
  get nodes -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,ARCH:.status.nodeInfo.architecture,KUBELET:.status.nodeInfo.kubeletVersion'

not_ready="$(kubectl --kubeconfig "$kubeconfig_path" --context "$context_name" get nodes \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
  --no-headers | awk '$2 != "True" { print $1 }')"
[[ -z "$not_ready" ]] || die "One or more ACK nodes are not Ready"
