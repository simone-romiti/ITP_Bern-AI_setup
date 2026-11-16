#!/usr/bin/env bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE="opencode-image"
export DOCKER_BUILDKIT=1

docker build \
  --build-arg USERNAME="${USER:-$(id -un)}" \
  --build-arg USER_UID="$(id -u)" \
  --build-arg USER_GID="$(id -g)" \
  --build-arg "OPENCODE_VERSION=${OPENCODE_VERSION:-1.19.5}" \
  -f Dockerfile.opencode \
  -t "$IMAGE" .
