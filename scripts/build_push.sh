#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${KUP_CONFIG:-$ROOT_DIR/kup.conf}"
[[ -f "$CONFIG_FILE" ]] || die "private config not found: $CONFIG_FILE"

SCRIPT_DIR="$ROOT_DIR"
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a

for command_name in docker git curl python3; do
  need "$command_name"
done
for setting_name in \
  GALILEO_REGISTRY_SERVER GALILEO_REGISTRY_USERNAME GALILEO_REGISTRY_PASSWORD; do
  setting_value="${!setting_name:-}"
  [[ -n "$setting_value" && "$setting_value" != "ReplaceMe" ]] \
    || die "required setting is empty or still a placeholder: $setting_name"
done
unset setting_name setting_value

repository="${1:-}"
if [[ -z "$repository" && "${GALILEO_IMAGE_REF:-}" == *@sha256:* ]]; then
  repository="${GALILEO_IMAGE_REF%@sha256:*}"
fi
[[ -n "$repository" ]] || die "usage: $0 REGISTRY/PROJECT/REPOSITORY"
[[ "$repository" == "${GALILEO_REGISTRY_SERVER}/"* ]] \
  || die "image repository must belong to GALILEO_REGISTRY_SERVER"
repository_name="${repository##*/}"
[[ "$repository" != *@* && "$repository_name" != *:* ]] \
  || die "pass a repository without a tag or digest"

git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 \
  || die "the repository must have a Git commit before building"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
  die "commit or intentionally remove every working-tree change before building an immutable release image"
fi
source_commit="$(git -C "$ROOT_DIR" rev-parse HEAD)"
short_commit="$(git -C "$ROOT_DIR" rev-parse --short=10 HEAD)"
tag="$(date -u +%Y%m%d-%H%M%S)-${short_commit}"
tag_ref="${repository}:${tag}"

if docker buildx version >/dev/null 2>&1; then
  buildx=(docker buildx)
elif command -v docker-buildx >/dev/null 2>&1; then
  buildx=(docker-buildx)
else
  die "Docker buildx is required"
fi
docker info >/dev/null

docker_config="$(mktemp -d)"
chmod 0700 "$docker_config"
export DOCKER_CONFIG="$docker_config"
container_name="galileo-image-smoke-${short_commit}"

cleanup() {
  docker rm --force "$container_name" >/dev/null 2>&1 || true
  docker logout "$GALILEO_REGISTRY_SERVER" >/dev/null 2>&1 || true
  rm -r -- "$docker_config"
}
trap cleanup EXIT

printf '%s' "$GALILEO_REGISTRY_PASSWORD" | docker login "$GALILEO_REGISTRY_SERVER" \
  --username "$GALILEO_REGISTRY_USERNAME" --password-stdin >/dev/null

log "build local linux/amd64 image for container smoke: $tag_ref"
"${buildx[@]}" build \
  --platform linux/amd64 \
  --load \
  --tag "$tag_ref" \
  "$ROOT_DIR"

image_uid="$(docker run --rm --platform linux/amd64 "$tag_ref" id -u)"
[[ "$image_uid" == "999" ]] || die "image runtime UID is $image_uid; expected 999"

docker run --detach --rm --platform linux/amd64 --name "$container_name" \
  --publish 127.0.0.1::8000 "$tag_ref" >/dev/null
container_port="$(docker port "$container_name" 8000/tcp | awk -F: 'NR==1 {print $NF}')"
[[ -n "$container_port" ]] || die "could not determine local container port"
for _ in $(seq 1 60); do
  if curl --fail --silent --max-time 2 "http://127.0.0.1:${container_port}/" >/dev/null 2>&1; then
    break
  fi
  docker inspect "$container_name" >/dev/null 2>&1 \
    || die "local smoke container exited unexpectedly"
  sleep 2
done
curl --fail --silent --show-error --max-time 5 \
  "http://127.0.0.1:${container_port}/" >/dev/null
docker rm --force "$container_name" >/dev/null
log "local non-root container HTTP smoke: PASS"

log "push linux/amd64 image to the configured registry"
"${buildx[@]}" build \
  --platform linux/amd64 \
  --push \
  --tag "$tag_ref" \
  "$ROOT_DIR"
digest="$("${buildx[@]}" imagetools inspect "$tag_ref" | awk '/^Digest:/ {print $2; exit}')"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "could not resolve a complete image digest"
immutable_ref="${repository}@${digest}"

python3 - "$CONFIG_FILE" "$source_commit" "$immutable_ref" <<'PY'
import os
import sys
import tempfile
from pathlib import Path

config_path = Path(sys.argv[1])
replacements = {
    "GALILEO_SOURCE_COMMIT": sys.argv[2],
    "GALILEO_IMAGE_REF": sys.argv[3],
}
seen = {name: 0 for name in replacements}
output = []
for line in config_path.read_text(encoding="utf-8").splitlines(keepends=True):
    name = line.split("=", 1)[0] if "=" in line else ""
    if name in replacements:
        output.append(f'{name}="{replacements[name]}"\n')
        seen[name] += 1
    else:
        output.append(line)
if any(count != 1 for count in seen.values()):
    raise SystemExit(f"kup.conf must contain each image provenance key exactly once: {seen}")
with tempfile.NamedTemporaryFile(
    mode="w", encoding="utf-8", dir=config_path.parent, prefix=".kup.conf.", delete=False
) as handle:
    handle.writelines(output)
    temporary = Path(handle.name)
temporary.chmod(0o600)
os.replace(temporary, config_path)
PY

log "image push: PASS"
printf 'Tag: %s\n' "$tag_ref"
printf 'Digest: %s\n' "$digest"
printf 'Immutable reference: %s\n' "$immutable_ref"
printf 'Source commit: %s\n' "$source_commit"
printf 'Updated private config: %s\n' "$CONFIG_FILE"
printf 'Next step: ./kup --galileo-only\n'
