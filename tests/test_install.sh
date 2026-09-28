#!/usr/bin/env bash
# tests/test_install.sh - fresh install, version validation, marker, upgrade.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; prepare_archive; source_libs
trap cleanup_sandbox EXIT

t_begin "fresh install exits 0"
out="$(run_setup install 2>&1)"; rc=$?
assert_exit 0 "$rc" "install failed: $out"

t_begin "binary exists and is executable"
assert_file_exists "$OPENCODE_BIN"
[ -x "$OPENCODE_BIN" ] && t_pass || t_fail "binary not executable"

t_begin "installed binary reports expected version"
assert_eq "9.9.9" "$("$OPENCODE_BIN" --version 2>/dev/null)"

t_begin "install marker written with matching version"
assert_file_exists "$OCDEPLOY_STATE_HOME/install-state.json"
assert_eq "9.9.9" "$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$OCDEPLOY_STATE_HOME/install-state.json")"

t_begin "install-state reports ok"
assert_eq "ok" "$(install_status)"

t_begin "upgrade to same release stays healthy"
out="$(run_setup update 2>&1)"; rc=$?
assert_exit 0 "$rc" "update failed: $out"
assert_eq "9.9.9" "$("$OPENCODE_BIN" --version 2>/dev/null)"

t_summary
