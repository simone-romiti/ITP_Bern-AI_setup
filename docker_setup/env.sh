#!/usr/bin/env bash
# Shared helper: load the Swiss AI API key from <repo>/.env.
# Sourced by run-openwebui.sh and docker_setup/run-opencode.sh.
#
# The key lives in exactly one place: <repo>/.env (gitignored). It is parsed
# as plain KEY=value text (not executed), so a broken .env cannot run code.

load_api_key() {
  local root="${1:?load_api_key: repository root argument is required}"
  local env_file="$root/.env"
  local value=""

  if [[ -f "$env_file" ]]; then
    value="$(sed -nE \
      's/^[[:space:]]*(export[[:space:]]+)?SWISSAI_RESEARCH_API_KEY[[:space:]]*=[[:space:]]*//p' \
      "$env_file" | tail -n 1)"
    # Trim CR, inline comment, surrounding blanks and one layer of quotes.
    value="${value%$'\r'}"
    value="$(printf '%s' "$value" | sed -E \
      "s/[[:space:]]+#.*\$//; s/^[[:space:]]+//; s/[[:space:]]+\$//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/")"
  fi

  # Fall back to an already-exported variable if .env has no key.
  if [[ -z "$value" ]]; then
    value="${SWISSAI_RESEARCH_API_KEY:-}"
  fi

  if [[ -z "$value" ]]; then
    {
      echo "ERROR: SWISSAI_RESEARCH_API_KEY is not set."
      echo
      echo "Set it once in $env_file:"
      echo "    cp \"$root/.env.example\" \"$root/.env\""
      echo "    \$EDITOR \"$env_file\"     # SWISSAI_RESEARCH_API_KEY=your-key"
      echo
      echo "(.env is gitignored - never commit it.)"
    } >&2
    return 1
  fi

  export SWISSAI_RESEARCH_API_KEY="$value"
}
