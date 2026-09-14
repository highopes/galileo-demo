#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-status}"
CUSTOM_PROMPT_FILE="${2:-}"

usage() {
  echo "usage: $0 status|baseline|improved|custom [custom-prompt-file]" >&2
}

case "$PROFILE" in
  status|baseline|improved) [[ -z "$CUSTOM_PROMPT_FILE" ]] || { usage; exit 2; } ;;
  custom) [[ -n "$CUSTOM_PROMPT_FILE" ]] || { usage; exit 2; } ;;
  *) usage; exit 2 ;;
esac

if [[ -n "${KUBE_CONTEXT:-}" ]]; then
  KUBE_NAMESPACE="${KUBE_NAMESPACE:-galileo-demo}"
  if [[ -n "${KUBECONFIG_FILE:-}" ]]; then
    kctl=(kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$KUBE_CONTEXT")
  else
    kctl=(kubectl --context "$KUBE_CONTEXT")
  fi
else
  "$ROOT_DIR/scripts/discover_ack.sh" >/dev/null
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.deploy.env"
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.runtime/resolved-ack.env"
  KUBE_NAMESPACE="${ACK_NAMESPACE:-galileo-demo}"
  kctl=(kubectl --kubeconfig "$ACK_KUBECONFIG" --context "$ACK_CONTEXT")
fi

configmap_name="splunk-ao-banking-qwen-config"
deployment_name="splunk-ao-banking-qwen"

resolve_state() {
  "${kctl[@]}" -n "$KUBE_NAMESPACE" exec "deployment/$deployment_name" -- \
    python -c 'import hashlib; from src.splunk_ao_langgraph_fsi_agent.prompt_profiles import resolve_supervisor_prompt; profile, prompt = resolve_supervisor_prompt(); print(profile + "\t" + hashlib.sha256(prompt.encode("utf-8")).hexdigest())'
}

show_status() {
  configured="$("${kctl[@]}" -n "$KUBE_NAMESPACE" get configmap "$configmap_name" \
    -o jsonpath='{.data.SUPERVISOR_PROMPT_PROFILE}')"
  mounted="$("${kctl[@]}" -n "$KUBE_NAMESPACE" exec "deployment/$deployment_name" -- \
    sh -c 'if test -n "$SUPERVISOR_PROMPT_PROFILE_FILE" && test -f "$SUPERVISOR_PROMPT_PROFILE_FILE"; then cat "$SUPERVISOR_PROMPT_PROFILE_FILE"; else printf %s "$SUPERVISOR_PROMPT_PROFILE"; fi')"
  resolved_state="$(resolve_state)"
  IFS=$'\t' read -r resolved resolved_digest <<< "$resolved_state"
  image="$("${kctl[@]}" -n "$KUBE_NAMESPACE" get "deployment/$deployment_name" \
    -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "Configured prompt profile: $configured"
  echo "Mounted prompt profile: $mounted"
  echo "Resolved application profile: $resolved"
  echo "Resolved prompt SHA-256: $resolved_digest"
  echo "Deployment image: $image"
}

if [[ "$PROFILE" == "status" ]]; then
  show_status
  exit 0
fi

patch_file="$(mktemp "$ROOT_DIR/.runtime/prompt-config-patch.XXXXXX")"
cleanup() {
  rm -f "$patch_file"
}
trap cleanup EXIT
chmod 0600 "$patch_file"

if [[ "$PROFILE" == "custom" ]]; then
  "$ROOT_DIR/scripts/render_prompt_patch.py" "$PROFILE" "$patch_file" "$CUSTOM_PROMPT_FILE"
  expected_digest="$(python3 -c 'import hashlib, pathlib, sys; value = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip(); print(hashlib.sha256(value.encode("utf-8")).hexdigest())' "$CUSTOM_PROMPT_FILE")"
else
  "$ROOT_DIR/scripts/render_prompt_patch.py" "$PROFILE" "$patch_file"
  expected_digest=""
fi

"${kctl[@]}" -n "$KUBE_NAMESPACE" patch configmap "$configmap_name" \
  --type merge --patch-file "$patch_file" >/dev/null

# A projected ConfigMap volume lets new chats observe the prompt without a Pod
# restart. Fall back to a one-Pod rollout only for an older deployment that has
# not yet been upgraded with the volume mount.
profile_file="$("${kctl[@]}" -n "$KUBE_NAMESPACE" exec "deployment/$deployment_name" -- \
  sh -c 'printf %s "${SUPERVISOR_PROMPT_PROFILE_FILE:-}"')"
if [[ -n "$profile_file" ]] && "${kctl[@]}" -n "$KUBE_NAMESPACE" exec "deployment/$deployment_name" -- \
  test -f "$profile_file"; then
  echo "Waiting for the projected ConfigMap to refresh; the application Pod stays running."
  resolved=""
  resolved_digest=""
  for _ in $(seq 1 90); do
    resolved_state="$(resolve_state)"
    IFS=$'\t' read -r resolved resolved_digest <<< "$resolved_state"
    if [[ "$resolved" == "$PROFILE" ]] && \
      { [[ "$PROFILE" != "custom" ]] || [[ "$resolved_digest" == "$expected_digest" ]]; }; then
      break
    fi
    sleep 2
  done
else
  echo "Older deployment detected; rolling only the application Pod once to apply the profile."
  "${kctl[@]}" -n "$KUBE_NAMESPACE" rollout restart "deployment/$deployment_name" >/dev/null
  "${kctl[@]}" -n "$KUBE_NAMESPACE" rollout status "deployment/$deployment_name" --timeout=5m
  resolved_state="$(resolve_state)"
  IFS=$'\t' read -r resolved resolved_digest <<< "$resolved_state"
fi

if [[ "$resolved" != "$PROFILE" ]] || \
  { [[ "$PROFILE" == "custom" ]] && [[ "$resolved_digest" != "$expected_digest" ]]; }; then
  echo "Application prompt resolution failed: expected $PROFILE with the requested content" >&2
  exit 2
fi

show_status
echo "Prompt switch complete. The Pod and image were preserved. Start a new Chainlit chat so the new session uses this profile."
