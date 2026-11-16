#!/bin/bash
# run-openwebui.sh - OpenWebUI Docker container launcher
#
# Intended to be run on the HOST machine (not inside the agent container).
# Uses OpenWebUI's default host port 3000. The opencode container publishes
# 3001 (see docker_setup/run-opencode.sh), so they do not collide.
#
# The API key is read from <repo>/.env (gitignored); see .env.example.
#
# Docker port-forwarding flag:
#   -p 0.0.0.0:3000:8080
# The web UI binds host port 3000 on ALL interfaces (0.0.0.0), so it is
# reachable at http://localhost:3000 on the machine itself and at
# http://<host-ip>:3000 from the network (or via an SSH tunnel, see README).
#
# IMPORTANT - the image is pulled and the container is recreated when the
# image (or the launch parameters) change. `docker start` alone keeps the
# image baked into the old container, so an instance created weeks ago keeps
# running that old release forever. That is exactly how a container got stuck
# on v0.12.3 while :main had already moved to v0.13.3.
#
# Optional environment variables:
#   OPENWEBUI_IMAGE            image ref (default: .../open-webui:main)
#                              pin a release with e.g. ...:v0.13.3
#   OPENWEBUI_CONTAINER_NAME   container name (default: open-webui)
#   OPENWEBUI_VOLUME           data volume (default: open-webui)
#   OPENWEBUI_HOST_PORT        host port (default: 3000)
#   OPENWEBUI_CONTAINER_PORT   container port (default: 8080)
#   OPENWEBUI_API_BASE         OpenAI-compatible base URL
#                              (default: https://api.swissai.svc.cscs.ch/v1)
#   SWISSAI_RESEARCH_API_KEY   API key (normally read from <repo>/.env)
#   OPENWEBUI_PULL=0           do not docker pull (use the local image)
#   OPENWEBUI_RESET=1          force-recreate the container (data volume kept)
#   OPENWEBUI_WAIT_TIMEOUT     seconds to wait for /ready (default: 300)
#   OPENWEBUI_NO_WAIT=1        skip waiting entirely
#   OPENWEBUI_BACKUP_DIR       where webui.db is saved before a recreate
#                              (default: ${XDG_DATA_HOME:-~/.local/share}/open-webui/backups)
#
# Before a recreate due to an image/parameter change the SQLite database is
# copied out of the container to OPENWEBUI_BACKUP_DIR. The data volume is
# never deleted. To restore a backup:
#   docker stop open-webui
#   docker cp <backup>.db open-webui:/app/backend/data/webui.db
#   docker start open-webui

set -euo pipefail

# --- Output helpers --------------------------------------------------------
# Print the URL as an OSC-8 terminal hyperlink when stdout is a TTY, so it is
# clickable in VTE/GNOME Terminal, iTerm2, kitty, WezTerm, Windows Terminal…
# Without a TTY the plain URL is printed (logs, pipes).
print_url() {
  local label="$1"
  local url="http://localhost:${HOST_PORT}"
  local line="=============================================================="

  echo
  echo "$line"
  echo "  $label"
  echo
  if [[ -t 1 ]]; then
    printf '  \033]8;;%s\033\\\033[1;4;94m%s\033[0m\033]8;;\033\\\n' "$url" "$url"
  else
    printf '  %s\n' "$url"
  fi
  echo
  echo "$line"
  echo
}

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=docker_setup/env.sh
source "$ROOT/docker_setup/env.sh"
load_api_key "$ROOT" || exit 1

CONTAINER_NAME="${OPENWEBUI_CONTAINER_NAME:-open-webui}"
IMAGE="${OPENWEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
HOST_PORT="${OPENWEBUI_HOST_PORT:-3000}"
CONTAINER_PORT="${OPENWEBUI_CONTAINER_PORT:-8080}"
VOLUME_NAME="${OPENWEBUI_VOLUME:-open-webui}"
API_BASE="${OPENWEBUI_API_BASE:-https://api.swissai.svc.cscs.ch/v1}"
BACKUP_DIR="${OPENWEBUI_BACKUP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/open-webui/backups}"

# --- Prerequisites ---------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not on PATH." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: cannot talk to the Docker daemon. Is Docker running?" >&2
  exit 1
fi

# --- Container state helpers ----------------------------------------------
container_exists() {
  [[ -n "$(docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}')" ]]
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

container_restart_count() {
  docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0
}

# Host port currently published for CONTAINER_PORT by CONTAINER_NAME, if any.
container_published_port() {
  docker inspect \
    --format "{{ range \$p, \$conf := .HostConfig.PortBindings }}{{ if eq \$p \"${CONTAINER_PORT}/tcp\" }}{{ range \$conf }}{{ .HostPort }}{{ end }}{{ end }}{{ end }}" \
    "$CONTAINER_NAME" 2>/dev/null | tr -d ' '
}

image_id() {
  docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true
}

container_image_id() {
  docker inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true
}

# Signature of everything that requires a container recreate. The API key is
# hashed so it never ends up in the Docker label.
key_hash() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$SWISSAI_RESEARCH_API_KEY" | sha256sum | cut -c1-16
  else
    printf '%s' "$SWISSAI_RESEARCH_API_KEY" | cksum | tr ' ' '-'
  fi
}

launch_signature() {
  echo "port=${HOST_PORT}:${CONTAINER_PORT}|volume=${VOLUME_NAME}|base=${API_BASE}|key=$(key_hash)"
}

# --- Pull the image --------------------------------------------------------
# The :main tag moves. Without a pull, an old container keeps the old release.
if [[ "${OPENWEBUI_PULL:-1}" != "0" ]]; then
  echo "Pulling '$IMAGE'..."
  if ! docker pull "$IMAGE"; then
    if [[ -n "$(image_id)" ]]; then
      echo "WARNING: pull failed - falling back to the local '$IMAGE' image." >&2
    else
      echo "ERROR: could not pull '$IMAGE' and no local copy exists." >&2
      exit 1
    fi
  fi
else
  echo "Skipping pull (OPENWEBUI_PULL=0)."
fi

TARGET_IMAGE_ID="$(image_id)"
if [[ -z "$TARGET_IMAGE_ID" ]]; then
  echo "ERROR: image '$IMAGE' is not available locally." >&2
  exit 1
fi

# --- Back up the database before destroying a container -------------------
backup_database() {
  local ts backup
  ts="$(date +%Y%m%d-%H%M%S)"
  backup="${BACKUP_DIR}/webui-${ts}.db"

  # Stop first so webui.db and its -wal file are consistent.
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true

  if mkdir -p "$BACKUP_DIR" &&
     docker cp "${CONTAINER_NAME}:/app/backend/data/webui.db" "$backup" >/dev/null 2>&1; then
    echo "Database backed up to: $backup"
  else
    echo "WARNING: could not back up webui.db (continuing; data volume is untouched)." >&2
  fi
}

# --- Start or (re)create the container ------------------------------------
RECREATE_REASON=""

if [[ "${OPENWEBUI_RESET:-0}" == "1" ]]; then
  RECREATE_REASON="OPENWEBUI_RESET=1"
elif container_exists; then
  existing_host_port="$(container_published_port || true)"
  existing_image_id="$(container_image_id || true)"
  existing_sig="$(docker inspect -f '{{ index .Config.Labels "openwebui.launch-sig" }}' "$CONTAINER_NAME" 2>/dev/null || true)"
  SIG="$(launch_signature)"

  if [[ "$existing_host_port" != "$HOST_PORT" ]]; then
    RECREATE_REASON="port mapping changed (${existing_host_port:-<none>} -> ${HOST_PORT})"
  elif [[ -n "$existing_image_id" && "$existing_image_id" != "$TARGET_IMAGE_ID" ]]; then
    RECREATE_REASON="image changed ($(docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$CONTAINER_NAME" 2>/dev/null || true) -> ${IMAGE})"
  elif [[ "$existing_sig" != "$SIG" ]]; then
    RECREATE_REASON="launch parameters changed"
  fi
fi

if [[ -n "$RECREATE_REASON" ]] && container_exists; then
  echo "Recreating container '$CONTAINER_NAME': $RECREATE_REASON"
  backup_database
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

if container_exists; then
  if container_running; then
    echo "Container '$CONTAINER_NAME' is already running."
  else
    echo "Container '$CONTAINER_NAME' already exists - starting it..."
    if ! docker start "$CONTAINER_NAME" >/dev/null; then
      echo "ERROR: failed to start existing container '$CONTAINER_NAME'." >&2
      exit 1
    fi
  fi
else
  # A different container publishing HOST_PORT would make `docker run` fail
  # with a confusing bind error; report it by name instead.
  port_owner="$(docker ps --filter "publish=${HOST_PORT}" --format '{{.Names}}' | head -n1)"
  if [[ -n "$port_owner" && "$port_owner" != "$CONTAINER_NAME" ]]; then
    echo "ERROR: host port ${HOST_PORT} is already published by container '$port_owner'." >&2
    echo "       Stop it or choose another port with OPENWEBUI_HOST_PORT=<port>." >&2
    exit 1
  fi

  echo "Creating container '$CONTAINER_NAME' from '$IMAGE'..."
  if ! docker run -d \
      -p "0.0.0.0:${HOST_PORT}:${CONTAINER_PORT}" \
      --add-host=host.docker.internal:host-gateway \
      -e "OPENAI_API_BASE_URLS=${API_BASE}" \
      -e "OPENAI_API_BASE_URL=${API_BASE}" \
      -e "OPENAI_API_KEYS=${SWISSAI_RESEARCH_API_KEY}" \
      -e "OPENAI_API_KEY=${SWISSAI_RESEARCH_API_KEY}" \
      -v "${VOLUME_NAME}:/app/backend/data" \
      --label "openwebui.launch-sig=$(launch_signature)" \
      --name "$CONTAINER_NAME" \
      --restart always \
      "$IMAGE" >/dev/null; then
    echo "ERROR: 'docker run' failed; container '$CONTAINER_NAME' was not started." >&2
    exit 1
  fi
fi

# --- Verify the container is running --------------------------------------
if container_running; then
  echo "Container '${CONTAINER_NAME}' is running."
  echo "Port-forwarding flag: -p 0.0.0.0:${HOST_PORT}:${CONTAINER_PORT} (listening on all interfaces)"
  print_url "Open WebUI address (starting - not ready yet):"
else
  echo "ERROR: container '$CONTAINER_NAME' is not running." >&2
  exit 1
fi

# --- Failure diagnostics ---------------------------------------------------
diagnose() {
  echo >&2
  echo "--- container state ---" >&2
  docker inspect -f \
    'running={{.State.Running}} restarting={{.State.Restarting}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' \
    "$CONTAINER_NAME" >&2 2>&1 || true
  echo "--- last container logs ---" >&2
  docker logs --tail 80 "$CONTAINER_NAME" >&2 2>&1 || true
}

# --- Wait until the web interface is actually ready -----------------------
# The container being up is NOT the same as the UI being usable: OpenWebUI
# still initializes its DB/volume and only then starts answering. Its /ready
# endpoint returns 200 once startup work, the DB ping and (if configured)
# Redis are all up; /health answers earlier, as soon as the port is open.
READY_URL="http://127.0.0.1:${HOST_PORT}/ready"
WAIT_TIMEOUT="${OPENWEBUI_WAIT_TIMEOUT:-300}"
WAIT_INTERVAL=2

probe_ready() {
  local code
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$READY_URL" 2>/dev/null || true)"
    [[ "$code" == "200" ]]
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null "$READY_URL" 2>/dev/null
  else
    # No HTTP client: only proves the TCP port is open, not full readiness.
    (exec 3<>"/dev/tcp/127.0.0.1/${HOST_PORT}") 2>/dev/null
  fi
}

echo
if [[ "${OPENWEBUI_NO_WAIT:-0}" == "1" ]]; then
  echo "OpenWebUI is starting - it needs a few seconds before the interface"
  echo "becomes active (first launch can take longer)."
  echo "Skipping the readiness wait (OPENWEBUI_NO_WAIT=1)."
else
  echo "OpenWebUI is starting - the interface is NOT active yet."
  echo "It usually needs ~5-15 s (the first start after an upgrade can take longer)."
  printf 'Waiting for it to become ready '
  ready=0
  elapsed=0
  restarts_before="$(container_restart_count)"
  while (( elapsed < WAIT_TIMEOUT )); do
    if probe_ready; then
      ready=1
      break
    fi
    if ! container_running; then
      echo
      echo "ERROR: container stopped while starting." >&2
      diagnose
      exit 1
    fi
    if [[ "$(container_restart_count)" != "$restarts_before" ]]; then
      echo
      echo "ERROR: container restarted while starting (crash loop)." >&2
      diagnose
      exit 1
    fi
    printf '.'
    sleep "$WAIT_INTERVAL"
    elapsed=$(( elapsed + WAIT_INTERVAL ))
  done
  echo
  if (( ready )); then
    echo "OpenWebUI is READY (after ~${elapsed}s)."
    print_url "Open WebUI is READY — click to open:"
  else
    echo "ERROR: not ready after ${WAIT_TIMEOUT}s." >&2
    diagnose
    echo >&2
    echo "Hints:" >&2
    echo "  - retry once with: OPENWEBUI_RESET=1 $0" >&2
    echo "  - follow the logs with: docker logs -f ${CONTAINER_NAME}" >&2
    exit 1
  fi
fi
