#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/.deploy.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.secrets/dockerhub.env"

"$ROOT_DIR/scripts/discover_ack.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/resolved-ack.env"

[[ -n "${DOCKERHUB_USERNAME:-}" ]] || { echo "DOCKERHUB_USERNAME is required" >&2; exit 2; }
[[ -n "${DOCKERHUB_PAT:-}" ]] || { echo "DOCKERHUB_PAT is required" >&2; exit 2; }
[[ -n "${DOCKERHUB_REPOSITORY:-}" ]] || { echo "DOCKERHUB_REPOSITORY is required" >&2; exit 2; }

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
else
  tag="${tag}-uncommitted"
fi
image_ref="${DOCKERHUB_REPOSITORY}:${tag}"

docker_config="$ROOT_DIR/.runtime/docker-auth"
mkdir -p "$docker_config"
chmod 0700 "$docker_config"
export DOCKER_CONFIG="$docker_config"
export DOCKER_HOST="$docker_endpoint"

cleanup_auth() {
  docker logout >/dev/null 2>&1 || true
  rm -f "$docker_config/config.json"
  rmdir "$docker_config" 2>/dev/null || true
}
trap cleanup_auth EXIT

printf '%s' "$DOCKERHUB_PAT" | docker login \
  --username "$DOCKERHUB_USERNAME" --password-stdin >/dev/null

echo "Building local smoke image: $image_ref (linux/amd64)"
"${buildx[@]}" build --platform linux/amd64 --load --tag "$image_ref" "$ROOT_DIR"

container_name="galileo-image-smoke-${tag}"
docker run --detach --rm --platform linux/amd64 --name "$container_name" \
  --publish 127.0.0.1::8000 "$image_ref" >/dev/null
cleanup_container() {
  docker rm --force "$container_name" >/dev/null 2>&1 || true
}
trap 'cleanup_container; cleanup_auth' EXIT

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
cleanup_container

echo "Pushing image: $image_ref"
"${buildx[@]}" build --platform linux/amd64 --push --tag "$image_ref" "$ROOT_DIR"
digest="$("${buildx[@]}" imagetools inspect "$image_ref" | awk '/^Digest:/ {print $2; exit}')"
[[ "$digest" == sha256:* ]] || { echo "Could not resolve pushed image digest" >&2; exit 2; }
immutable_ref="${DOCKERHUB_REPOSITORY}@${digest}"

resolved_file="$(mktemp "$ROOT_DIR/.runtime/image.env.XXXXXX")"
{
  printf 'IMAGE_TAG_REF=%q\n' "$image_ref"
  printf 'IMAGE_DIGEST=%q\n' "$digest"
  printf 'IMAGE_IMMUTABLE_REF=%q\n' "$immutable_ref"
  printf 'IMAGE_PLATFORM=%q\n' "linux/amd64"
} >"$resolved_file"
chmod 0600 "$resolved_file"
mv "$resolved_file" "$ROOT_DIR/.runtime/image.env"

echo "Image tag: $image_ref"
echo "Image digest: $digest"
echo "Immutable deployment reference: $immutable_ref"
