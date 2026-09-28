#!/usr/bin/env bash
# shellcheck shell=bash
# tests/helpers.sh - sandbox setup shared by the test suites.

PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$PROJECT/tests"
MOCKS="$TESTS_DIR/mocks"
OCDEPLOY_ROOT="$PROJECT"
export PROJECT TESTS_DIR MOCKS OCDEPLOY_ROOT

make_sandbox() {
  SBX="$(mktemp -d "${TMPDIR:-/tmp}/oc-test.XXXXXX")" || exit 1
  mkdir -p "$SBX/home" "$SBX/state" "$SBX/bin" "$SBX/mnt/autodl-tmp" "$SBX/mnt/autodl-fs"
  chmod +x "$MOCKS/curl" "$MOCKS/opencode" 2>/dev/null || true
  export SBX
}

sandbox_env() {
  export HOME="$SBX/home"
  export OCDEPLOY_STATE_HOME="$SBX/state"
  export OCDEPLOY_BACKUP_DIR="$SBX/state/backups"
  export OCDEPLOY_LOG_DIR="$SBX/state/logs"
  export OPENCODE_INSTALL_DIR="$SBX/home/.opencode/bin"
  export OPENCODE_BIN="$SBX/home/.opencode/bin/opencode"
  export OPENCODE_CONFIG_HOME="$SBX/home/.config/opencode"
  export OPENCODE_DATA_HOME="$SBX/home/.local/share/opencode"
  export OPENCODE_CACHE_HOME="$SBX/home/.cache/opencode"
  export OPENCODE_INSTALL_METHOD=curl
  export OPENCODE_INSTALL_ATTEMPTS=1
  export OCDEPLOY_LOGIN_SHELL=/bin/bash
  export OC_MOCK_CURL_LOG="$SBX/curl.log"
  export OCDEPLOY_TEST_MOUNTS=""
  unset OC_MOCK_CURL_FAIL OC_MOCK_CURL_ARCHIVE OC_MOCK_CURL_STATUS OC_MOCK_CURL_EXIT OPENCODE_LIVE_TEST 2>/dev/null || true
  export PATH="$SBX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  # Only expose the curl mock on PATH; keep the opencode mock out of PATH so
  # that "discover the installed binary" checks stay meaningful.
  cp "$MOCKS/curl" "$SBX/bin/curl" 2>/dev/null || true
  chmod +x "$SBX/bin/curl" 2>/dev/null || true
  : >"$OC_MOCK_CURL_LOG"
}

run_setup() { bash "$PROJECT/setup.sh" "$@"; }

source_libs() {
  . "$PROJECT/lib/common.sh"
  . "$PROJECT/lib/detect.sh"
  . "$PROJECT/lib/mount.sh"
  . "$PROJECT/lib/net.sh"
  . "$PROJECT/lib/install.sh"
  . "$PROJECT/lib/path.sh"
  . "$PROJECT/lib/config.sh"
  . "$PROJECT/lib/doctor.sh"
  . "$PROJECT/lib/repair.sh"
  . "$PROJECT/lib/verify.sh"
  . "$PROJECT/lib/backup.sh"
}

prepare_archive() {
  local dir="$SBX/arch"
  mkdir -p "$dir"
  cp "$MOCKS/opencode" "$dir/opencode"
  chmod +x "$dir/opencode"
  tar -czf "$SBX/opencode.tar.gz" -C "$dir" opencode
  export OC_MOCK_CURL_ARCHIVE="$SBX/opencode.tar.gz"
}

# Mark the sandbox "mounts" as mounted / unmounted via the test hooks.
mark_fs_mounted()   { export OCDEPLOY_TEST_MOUNTS="$SBX/mnt/autodl-fs"; }
mark_tmp_mounted()  { export OCDEPLOY_TEST_MOUNTS="$SBX/mnt/autodl-tmp"; }
unmount_all()       { export OCDEPLOY_TEST_MOUNTS=""; export OCDEPLOY_TEST_UNMOUNTED="$SBX/mnt/autodl-fs:$SBX/mnt/autodl-tmp"; }

# Point the AutoDL paths at the sandbox and select a store mode.
use_sandbox_autodl_paths() {
  export OC_AUTODL_TMP="$SBX/mnt/autodl-tmp"
  export OC_AUTODL_FS="$SBX/mnt/autodl-fs"
}

cleanup_sandbox() {
  [ "${OC_TEST_KEEP:-0}" = "1" ] && { printf 'kept sandbox: %s\n' "$SBX"; return 0; }
  [ -n "${SBX:-}" ] && rm -rf "$SBX"
}
