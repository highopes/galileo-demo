#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/.runtime/image.env"
# shellcheck disable=SC1091
source "$ROOT_DIR/.secrets/acr.env"

for name in ACR_REGISTRY ACR_REPOSITORY ACR_USERNAME ACR_PASSWORD IMAGE_TAG_REF; do
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

docker info >/dev/null
docker image inspect "$IMAGE_TAG_REF" >/dev/null
docker_endpoint="$(docker context inspect "$(docker context show)" --format '{{.Endpoints.docker.Host}}')"
[[ -n "$docker_endpoint" ]] || { echo "Could not resolve the active Docker endpoint" >&2; exit 2; }

image_tag="${IMAGE_TAG_REF##*:}"
acr_tag_ref="${ACR_REPOSITORY}:${image_tag}"
docker_config="$ROOT_DIR/.runtime/acr-docker-auth"
mkdir -p "$docker_config"
chmod 0700 "$docker_config"
export DOCKER_CONFIG="$docker_config"
export DOCKER_HOST="$docker_endpoint"

cleanup_auth() {
  docker logout "$ACR_REGISTRY" >/dev/null 2>&1 || true
  rm -f "$docker_config/config.json"
  rmdir "$docker_config" 2>/dev/null || true
}
trap cleanup_auth EXIT

printf '%s' "$ACR_PASSWORD" | docker login "$ACR_REGISTRY" \
  --username "$ACR_USERNAME" --password-stdin >/dev/null
docker tag "$IMAGE_TAG_REF" "$acr_tag_ref"
echo "Pushing the verified linux/amd64 image to the configured ACR multi-agent-banking repository."
docker push "$acr_tag_ref"

if docker buildx version >/dev/null 2>&1; then
  buildx=(docker buildx)
elif command -v docker-buildx >/dev/null 2>&1; then
  buildx=(docker-buildx)
else
  echo "Docker buildx is required to inspect the ACR digest" >&2
  exit 2
fi
digest="$("${buildx[@]}" imagetools inspect "$acr_tag_ref" | awk '/^Digest:/ {print $2; exit}')"
[[ "$digest" == sha256:* ]] || { echo "Could not resolve ACR image digest" >&2; exit 2; }
immutable_ref="${ACR_REPOSITORY}@${digest}"

resolved_file="$(mktemp "$ROOT_DIR/.runtime/acr-image.env.XXXXXX")"
{
  printf 'ACR_IMAGE_TAG_REF=%q\n' "$acr_tag_ref"
  printf 'ACR_IMAGE_DIGEST=%q\n' "$digest"
  printf 'ACR_IMAGE_IMMUTABLE_REF=%q\n' "$immutable_ref"
  printf 'ACR_IMAGE_PLATFORM=%q\n' "linux/amd64"
} >"$resolved_file"
chmod 0600 "$resolved_file"
mv "$resolved_file" "$ROOT_DIR/.runtime/acr-image.env"

echo "ACR image push: PASS"
echo "ACR image digest: $digest"
