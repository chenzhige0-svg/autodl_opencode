#!/usr/bin/env bash
# tests/test_cli.sh - command line contract: help, version, exit codes.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env
trap cleanup_sandbox EXIT

t_begin "--help exits 0 and prints usage"
out="$(run_setup --help 2>&1)"; rc=$?
assert_exit 0 "$rc"
assert_contains "$out" "USAGE:"

t_begin "--version prints the toolkit version"
out="$(run_setup --version 2>&1)"
assert_contains "$out" "opencode-autodl"

t_begin "unknown command exits with usage error (2)"
run_setup bogus >/dev/null 2>&1
assert_exit 2 "$?"

t_begin "unknown option exits with usage error (2)"
run_setup --nope >/dev/null 2>&1
assert_exit 2 "$?"

t_begin "status runs without error"
run_setup status >/dev/null 2>&1
assert_exit 0 "$?"

t_summary
