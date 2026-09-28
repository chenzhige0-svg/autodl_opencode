#!/usr/bin/env bash
# tests/test_idempotency.sh - repeated runs must not reinstall or destroy state.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; prepare_archive; source_libs
trap cleanup_sandbox EXIT

run_setup install >/dev/null 2>&1

t_begin "config file is preserved across runs"
mkdir -p "$OPENCODE_CONFIG_HOME"
printf '{"user_marker":"keep"}\n' >"$OPENCODE_CONFIG_HOME/opencode.json"
before="$(cat "$OPENCODE_CONFIG_HOME/opencode.json")"

: >"$OC_MOCK_CURL_LOG"
t_begin "second install does not re-download"
run_setup install >/dev/null 2>&1
assert_eq "0" "$(wc -l <"$OC_MOCK_CURL_LOG" | tr -d ' ')"

t_begin "second install leaves binary healthy"
assert_eq "ok" "$(install_status)"

t_begin "existing config untouched by deploy without overrides"
run_setup deploy -y >/dev/null 2>&1
assert_eq "$before" "$(cat "$OPENCODE_CONFIG_HOME/opencode.json")"

t_begin "repeated deploy is idempotent (still ok)"
run_setup deploy -y >/dev/null 2>&1
assert_eq "ok" "$(install_status)"
assert_eq "9.9.9" "$("$OPENCODE_BIN" --version 2>/dev/null)"

t_summary
