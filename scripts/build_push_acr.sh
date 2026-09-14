#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/.deploy.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.secrets/acr.env"

"$ROOT_DIR/scripts/discover_ack.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-ack.env"

for name in ACR_REGISTRY ACR_REPOSITORY ACR_USERNAME ACR_PASSWORD; do
  [[ -n "${!name:-}" ]] || { echo "$name is required" >&2; exit 2; }
done
[[ "${ACR_REPOSITORY##*/}" == "multi-agent-banking" ]] || {
  echo "ACR repository name must be multi-agent-banking" >&2
  exit 2
}
[[ "$ACR_REPOSITORY" == "$ACR_REGISTRY"/* ]] || {
  echo "ACR_REPOSITORY must belong to ACR_REGISTRY" >&2
  exit 2
}

architectures="$(kubectl --kubeconfig "$ACK_KUBECONFIG" --context "$ACK_CONTEXT" \
  get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -u)"
[[ "$architectures" == "amd64" ]] || {
  echo "Expected one ACK architecture (amd64), found: $architectures" >&2
  exit 2
}

if docker buildx version >/dev/null 2>&1; then
  buildx=(docker buildx)
elif command -v docker-buildx >/dev/null 2>&1; then
  buildx=(docker-buildx)
else
  echo "Docker buildx is required" >&2
  exit 2
fi

docker info >/dev/null
docker_endpoint="$(docker context inspect "$(docker context show)" --format '{{.Endpoints.docker.Host}}')"
[[ -n "$docker_endpoint" ]] || { echo "Could not resolve the active Docker endpoint" >&2; exit 2; }

tag="$(date -u +%Y%m%d-%H%M%S)"
if git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  tag="${tag}-$(git -C "$ROOT_DIR" rev-parse --short=10 HEAD)"
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
    tag="${tag}-dirty"
  fi
else
  tag="${tag}-uncommitted"
fi
image_ref="${ACR_REPOSITORY}:${tag}"

docker_config="$ROOT_DIR/.runtime/acr-build-auth"
mkdir -p "$docker_config"
chmod 0700 "$docker_config"
export DOCKER_CONFIG="$docker_config"
export DOCKER_HOST="$docker_endpoint"

container_name="galileo-acr-smoke-${tag}"
image_file=""
acr_file=""
cleanup() {
  docker rm --force "$container_name" >/dev/null 2>&1 || true
  docker logout "$ACR_REGISTRY" >/dev/null 2>&1 || true
  [[ -z "$image_file" ]] || rm -f "$image_file"
  [[ -z "$acr_file" ]] || rm -f "$acr_file"
  rm -rf "$docker_config"
}
trap cleanup EXIT

printf '%s' "$ACR_PASSWORD" | docker login "$ACR_REGISTRY" \
  --username "$ACR_USERNAME" --password-stdin >/dev/null

echo "Building local smoke image: $image_ref (linux/amd64)"
"${buildx[@]}" build --platform linux/amd64 --load --tag "$image_ref" "$ROOT_DIR"

docker run --detach --rm --platform linux/amd64 --name "$container_name" \
  --publish 127.0.0.1::8000 "$image_ref" >/dev/null
container_port="$(docker port "$container_name" 8000/tcp | awk -F: 'NR==1 {print $NF}')"
[[ -n "$container_port" ]] || { echo "Could not determine local container port" >&2; exit 2; }
for _ in $(seq 1 60); do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:${container_port}/" >/dev/null 2>&1; then
    echo "Local container HTTP smoke: PASS"
    break
  fi
  if ! docker inspect "$container_name" >/dev/null 2>&1; then
    echo "Local smoke container exited unexpectedly" >&2
    exit 2
  fi
  sleep 2
done
curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:${container_port}/" >/dev/null
docker rm --force "$container_name" >/dev/null

echo "Pushing image directly to the configured ACR multi-agent-banking repository."
"${buildx[@]}" build --platform linux/amd64 --push --tag "$image_ref" "$ROOT_DIR"
digest="$("${buildx[@]}" imagetools inspect "$image_ref" | awk '/^Digest:/ {print $2; exit}')"
[[ "$digest" == sha256:* ]] || { echo "Could not resolve ACR image digest" >&2; exit 2; }
immutable_ref="${ACR_REPOSITORY}@${digest}"

image_file="$(mktemp "$ROOT_DIR/.runtime/image.env.XXXXXX")"
acr_file="$(mktemp "$ROOT_DIR/.runtime/acr-image.env.XXXXXX")"
{
  printf 'IMAGE_TAG_REF=%q\n' "$image_ref"
  printf 'IMAGE_DIGEST=%q\n' "$digest"
  printf 'IMAGE_IMMUTABLE_REF=%q\n' "$immutable_ref"
  printf 'IMAGE_PLATFORM=%q\n' "linux/amd64"
} >"$image_file"
{
  printf 'ACR_IMAGE_TAG_REF=%q\n' "$image_ref"
  printf 'ACR_IMAGE_DIGEST=%q\n' "$digest"
  printf 'ACR_IMAGE_IMMUTABLE_REF=%q\n' "$immutable_ref"
  printf 'ACR_IMAGE_PLATFORM=%q\n' "linux/amd64"
} >"$acr_file"
chmod 0600 "$image_file" "$acr_file"
mv "$image_file" "$ROOT_DIR/.runtime/image.env"
mv "$acr_file" "$ROOT_DIR/.runtime/acr-image.env"
image_file=""
acr_file=""

echo "ACR image push: PASS"
echo "ACR image digest: $digest"
echo "Immutable deployment reference: $immutable_ref"
