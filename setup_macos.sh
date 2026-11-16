#!/usr/bin/env bash
# setup_macos.sh: make sure colima and docker are installed, colima is running,
# and docker is using the colima context.
set -euo pipefail

# 1. Homebrew is required
if ! command -v brew >/dev/null 2>&1; then
  echo "Error: Homebrew is not installed." >&2
  echo "Please install it from https://brew.sh and then re-run this script." >&2
  exit 1
fi

# 2. Install colima if it's missing
if command -v colima >/dev/null 2>&1; then
  echo "colima is already installed."
else
  echo "colima not found. Installing it with Homebrew..."
  brew install colima
fi

# 3. Install the docker CLI if it's missing
if command -v docker >/dev/null 2>&1; then
  echo "docker is already installed."
else
  echo "docker not found. Installing it with Homebrew..."
  brew install docker
fi

# 4. Start colima if it isn't running
if colima status >/dev/null 2>&1; then
  echo "colima is already running."
else
  echo "Starting colima..."
  colima start
fi

# 5. Make sure docker uses the colima context
current_context="$(docker context show 2>/dev/null || echo "")"
if [[ "$current_context" == "colima" ]]; then
  echo "docker context is already set to colima."
else
  echo "Switching docker context from '${current_context:-<none>}' to 'colima'..."
  docker context use colima
fi

# 6. Reminder
echo
echo "Reminder: run 'colima stop' when you're done."
