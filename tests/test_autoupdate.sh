#!/usr/bin/env bash
# tests/test_autoupdate.sh - opt-in shell-hook auto-update (on/off/status/run).
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; prepare_archive; source_libs
trap cleanup_sandbox EXIT

RC="$HOME/.bashrc"
STAMP="$OCDEPLOY_STATE_HOME/autoupdate.stamp"

export OC_MOCK_LATEST=9.9.9
run_setup install >/dev/null 2>&1

t_begin "autoupdate status starts disabled"
out="$(run_setup autoupdate status 2>&1)"
assert_contains "$out" "autoupdate: disabled"

t_begin "autoupdate on writes a managed block into the rc files"
run_setup autoupdate on >/dev/null 2>&1
assert_exit 0 "$?"
assert_file_exists "$RC"
assert_contains "$(cat "$RC")" "$OC_AUTO_MARK_BEGIN"
assert_contains "$(cat "$RC")" "autoupdate run"

t_begin "autoupdate on is idempotent"
run_setup autoupdate on >/dev/null 2>&1
n="$(grep -c -F "$OC_AUTO_MARK_BEGIN" "$RC")"
assert_eq "1" "$n" "expected exactly one managed block, found $n"

t_begin "autoupdate status reports enabled"
out="$(run_setup autoupdate status 2>&1)"
assert_contains "$out" "autoupdate: enabled"

t_begin "the PATH block and the autoupdate block coexist"
path_configure_user_rc >/dev/null 2>&1
assert_contains "$(cat "$RC")" "$OC_MARK_BEGIN"
assert_contains "$(cat "$RC")" "$OC_AUTO_MARK_BEGIN"

t_begin "autoupdate off removes only its own block"
run_setup autoupdate off >/dev/null 2>&1
assert_exit 0 "$?"
assert_not_contains "$(cat "$RC")" "$OC_AUTO_MARK_BEGIN"
assert_contains "$(cat "$RC")" "$OC_MARK_BEGIN"

t_begin "autoupdate off on a clean rc file is a no-op"
printf '# user config\n' >"$RC"
run_setup autoupdate off >/dev/null 2>&1
assert_exit 0 "$?"
assert_eq "# user config" "$(cat "$RC")"

t_begin "re-enabling after off restores exactly one block"
run_setup autoupdate on >/dev/null 2>&1
lines="$(grep -c -F "$OC_AUTO_MARK_BEGIN" "$RC")"
assert_eq "1" "$lines"

t_begin "dry-run does not create the stamp"
run_setup autoupdate run --dry-run >/dev/null 2>&1
assert_file_missing "$STAMP"

t_begin "autoupdate run stamps the check"
OC_MOCK_LATEST=9.9.9 run_setup autoupdate run >/dev/null 2>&1
assert_exit 0 "$?"
assert_file_exists "$STAMP"

t_begin "autoupdate run is throttled by the stamp (no second API call)"
before="$(wc -l <"$OC_MOCK_CURL_LOG" | tr -d ' ')"
OC_MOCK_LATEST=9.9.9 run_setup autoupdate run >/dev/null 2>&1
after="$(wc -l <"$OC_MOCK_CURL_LOG" | tr -d ' ')"
assert_eq "$before" "$after" "throttled run still queried the network"

t_begin "an elapsed interval triggers a new check"
touch -d '3 days ago' "$STAMP" 2>/dev/null || touch -t 202001010000 "$STAMP"
before="$(wc -l <"$OC_MOCK_CURL_LOG" | tr -d ' ')"
OC_MOCK_LATEST=9.9.9 run_setup autoupdate run >/dev/null 2>&1
after="$(wc -l <"$OC_MOCK_CURL_LOG" | tr -d ' ')"
[ "$after" -gt "$before" ] && t_pass || t_fail "stale stamp did not trigger a check"

t_begin "unknown autoupdate action is a usage error"
run_setup autoupdate bogus >/dev/null 2>&1
assert_exit 2 "$?"

t_summary
