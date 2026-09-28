#!/usr/bin/env bash
# tests/test_dryrun.sh - --dry-run must not mutate the system.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; source_libs; prepare_archive
trap cleanup_sandbox EXIT

t_begin "install --dry-run exits 0"
run_setup install --dry-run >/dev/null 2>&1
assert_exit 0 "$?"

t_begin "install --dry-run writes no binary"
assert_file_missing "$OPENCODE_BIN"

t_begin "install --dry-run writes no marker"
assert_file_missing "$OCDEPLOY_STATE_HOME/install-state.json"

t_begin "install --dry-run performs no download"
assert_eq "0" "$(wc -l <"$OC_MOCK_CURL_LOG" | tr -d ' ')"

t_begin "config --dry-run creates no config file"
export OPENCODE_MODEL="dry/run-model"
run_setup config --dry-run >/dev/null 2>&1
assert_file_missing "$OPENCODE_CONFIG_HOME/opencode.json"
unset OPENCODE_MODEL

t_begin "deploy --dry-run makes no changes and exits 0"
run_setup deploy --dry-run -y >/dev/null 2>&1
assert_exit 0 "$?"
assert_file_missing "$OPENCODE_BIN"
assert_file_missing "$OPENCODE_CONFIG_HOME/opencode.json"

t_begin "backup --dry-run creates no backup"
run_setup backup --dry-run >/dev/null 2>&1
n="$(find "$OCDEPLOY_BACKUP_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "0" "${n:-0}"

t_summary
