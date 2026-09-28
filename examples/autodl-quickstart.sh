#!/usr/bin/env bash
# examples/autodl-quickstart.sh
#
# One-command deployment wrapper for a fresh AutoDL instance.
#
# Usage:
#   bash examples/autodl-quickstart.sh
#
# Customise the exports below for your provider/model before running. Never
# commit real API keys: reference them through an environment variable name
# (OPENCODE_API_KEY_ENV) so OpenCode stores "{env:VAR}" in the config.

set -u

# --- locate the toolkit (this file lives in examples/) ---------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

# --- persistence: prefer cross-instance file storage -----------------------
export OPENCODE_PERSIST_MODE="${OPENCODE_PERSIST_MODE:-auto}"

# --- install method --------------------------------------------------------
# curl needs no Node.js and is the most reliable on AutoDL.
export OPENCODE_INSTALL_METHOD="${OPENCODE_INSTALL_METHOD:-curl}"

# --- optional config overrides (uncomment and edit) ------------------------
# export OPENCODE_MODEL="anthropic/claude-sonnet-4-5"
# export OPENCODE_PROVIDER="anthropic"
# export OPENCODE_BASE_URL="https://api.anthropic.com/v1"
# export OPENCODE_API_KEY_ENV="ANTHROPIC_API_KEY"

# --- accelerate GitHub in mainland-China regions (optional) ----------------
if [ -r /etc/network_turbo ]; then
  # shellcheck disable=SC1091
  . /etc/network_turbo || true
fi

exec bash "$ROOT/setup.sh" "$@"
