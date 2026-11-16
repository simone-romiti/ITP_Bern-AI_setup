#!/usr/bin/env bash
set -euo pipefail

# Minimal OpenCode launcher: a plain TUI in a container, no audio/voice.
#
# Usage:
#     ./run-opencode.sh                 # from the repository root
#
# OpenCode runs inside the container but the current working directory is
# bind-mounted as the workspace, so run this script from the folder you want
# the agent to work on (typically the repository root).
#
# Configuration:
#     config/opencode.json is mounted read-write at ~/.config/opencode inside
#     the container (models, default model, permissions). Edit it in the repo.
#     The API key is read from .env in the repository root (gitignored).
#
# Optional environment variables:
#     CONTAINER_NAME       container name        (default: opencode-container)
#     OPENCODE_PORT        opencode server port  (default: 4096)
#     EXTRA_PORTS          extra published ports (default: "3001 5173 8080")
#     OPENCODE_SESSION_DIR session data dir      (default: <cwd>/.opencode_data/share)
#     OPENCODE_STATE_DIR   state data dir        (default: <cwd>/.opencode_data/state)
#     OPENCODE_CACHE_DIR   provider cache dir    (default: <cwd>/.opencode_data/cache)

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=docker_setup/env.sh
source "$SCRIPT_DIR/env.sh"
load_api_key "$ROOT" || exit 1

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed or not on PATH." >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: cannot talk to the Docker daemon. Is Docker running?" >&2
    exit 1
fi

NAME="${CONTAINER_NAME:-opencode-container}"
IMAGE=opencode-image
WORKSPACE="$(pwd -P)"
# OpenWebUI owns host port 3000 (see run-openwebui.sh); opencode publishes 3001.
PORTS="$(echo "${OPENCODE_PORT:-4096} ${EXTRA_PORTS:-3001 5173 8080}" | tr ' ' '\n' | sort -nu | tr '\n' ' ')"
CONFIG_DIR="$ROOT/config"
HOME_IN="/home/${USER:-$(id -un)}"

# Sessions, state and the provider cache live in the directory this launcher is
# run from, so they survive container removal and travel with the project.
SESSION_DIR="${OPENCODE_SESSION_DIR:-$WORKSPACE/.opencode_data/share}"
STATE_DIR="${OPENCODE_STATE_DIR:-$WORKSPACE/.opencode_data/state}"
CACHE_DIR="${OPENCODE_CACHE_DIR:-$WORKSPACE/.opencode_data/cache}"

if [[ ! -f "$CONFIG_DIR/opencode.json" ]]; then
    echo "ERROR: $CONFIG_DIR/opencode.json is missing (should ship with the repo)." >&2
    exit 1
fi

mkdir -p "$SESSION_DIR" "$STATE_DIR" "$CACHE_DIR"

# Build the image on first use, so a fresh clone works with one command.
if ! docker image inspect -f '{{.Id}}' "$IMAGE" >/dev/null 2>&1; then
    echo "Image '$IMAGE' not found - building it now (one-time, a few minutes)..."
    "$SCRIPT_DIR/build_image-opencode.sh"
fi
IMAGE_ID="$(docker image inspect -f '{{.Id}}' "$IMAGE")"

# Signature of what the container was built with; mismatch => recreate.
SIG="$WORKSPACE|$PORTS|rslave|$CONFIG_DIR|data-v2:$SESSION_DIR|state-v1:$STATE_DIR|cache-v1:$CACHE_DIR|no-audio"
OLD_SIG="$(docker inspect -f '{{ index .Config.Labels "itp.sig" }}' "$NAME" 2>/dev/null || true)"

if [[ -n "$OLD_SIG" && "$OLD_SIG" != "$SIG" ]]; then
    echo "Workspace, ports, config or mounts changed, recreating container..." >&2
    docker rm -f "$NAME" >/dev/null
fi

# Recreate if the image was rebuilt: a plain `docker start` would otherwise keep
# running the image baked into the old container.
CONTAINER_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$NAME" 2>/dev/null || true)"
if [[ -n "$CONTAINER_IMAGE_ID" && "$IMAGE_ID" != "$CONTAINER_IMAGE_ID" ]]; then
    echo "Image changed, recreating container..." >&2
    docker rm -f "$NAME" >/dev/null
fi

if ! docker inspect "$NAME" >/dev/null 2>&1; then
    # First run with the new layout: copy sessions from the old host-wide
    # location, if one exists.
    if [[ -z "$(ls -A "$SESSION_DIR" 2>/dev/null)" && -d "$HOME/opencode_data" ]]; then
        echo "Migrating existing sessions from $HOME/opencode_data ..." >&2
        cp -a "$HOME/opencode_data/." "$SESSION_DIR/" || true
    fi

    port_args=()
    for p in $PORTS; do
        owner="$(docker ps --filter "publish=$p" --format '{{.Names}}')"
        if [[ -n "$owner" ]]; then
            echo "ERROR: host port $p already published by $owner (run: docker rm -f $owner, or change OPENCODE_PORT/EXTRA_PORTS)" >&2
            exit 1
        fi
        port_args+=(-p "$p:$p")
    done

    docker run -d --init \
        --name "$NAME" \
        --label "itp.sig=$SIG" \
        --user "$(id -u):$(id -g)" \
        -v "$WORKSPACE:$HOME_IN/workspace:rslave" \
        -v "$CONFIG_DIR:$HOME_IN/.config/opencode" \
        -v "$SESSION_DIR:$HOME_IN/.local/share/opencode" \
        -v "$STATE_DIR:$HOME_IN/.local/state/opencode" \
        -v "$CACHE_DIR:$HOME_IN/.cache" \
        -e HOME="$HOME_IN" \
        -e OPENCODE_CONFIG_DIR="$HOME_IN/.config/opencode" \
        -e OPENCODE_CONFIG="$HOME_IN/.config/opencode/opencode.json" \
        -e SWISSAI_RESEARCH_API_KEY \
        "${port_args[@]}" \
        --entrypoint sleep "$IMAGE" infinity >/dev/null
fi

docker start "$NAME" >/dev/null

exec docker exec -it -w "$HOME_IN/workspace" "$NAME" bash
