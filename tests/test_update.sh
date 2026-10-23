#!/usr/bin/env bash
# tests/test_update.sh - version comparison, 'update --check', no-op upgrades.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; prepare_archive; source_libs
trap cleanup_sandbox EXIT

t_begin "version comparison orders numeric components (1.0.9 < 1.0.180)"
assert_eq "-1" "$(oc_version_cmp 1.0.9 1.0.180)"
assert_eq "1" "$(oc_version_cmp 1.0.180 1.0.9)"
assert_eq "0" "$(oc_version_cmp v1.0.180 1.0.180)"
assert_eq "-1" "$(oc_version_cmp 1.0 1.0.1)"
assert_eq "1" "$(oc_version_cmp 2.0.0 1.9.9)"

downloads() {
  local n
  n="$(grep -c -- ' -o ' "$OC_MOCK_CURL_LOG" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

export OC_MOCK_LATEST=9.9.9
run_setup install >/dev/null 2>&1

t_begin "'update --check' exits 0 when already on the latest release"
OC_MOCK_LATEST=9.9.9 run_setup update --check >/dev/null 2>&1
assert_exit 0 "$?"

t_begin "'update --check' exits 10 when a newer release exists"
OC_MOCK_LATEST=9.9.10 run_setup update --check >/dev/null 2>&1
assert_exit 10 "$?"

t_begin "'update --check' reports the available version"
out="$(OC_MOCK_LATEST=9.9.10 run_setup update --check 2>&1)"
assert_contains "$out" "v9.9.9 -> v9.9.10"

t_begin "'update --check' fails cleanly when the API is unreachable"
out="$(OPENCODE_GITHUB_API=https://example.invalid/releases/latest run_setup update --check 2>&1)"; rc=$?
assert_exit 3 "$rc" "expected environment error, got $rc: $out"

t_begin "update to the current version downloads nothing"
before="$(downloads)"
OC_MOCK_LATEST=9.9.9 run_setup update >/dev/null 2>&1
assert_exit 0 "$?"
assert_eq "$before" "$(downloads)" "a no-op update re-downloaded the release"

t_begin "update says it is already up to date"
out="$(OC_MOCK_LATEST=9.9.9 run_setup update 2>&1)"
assert_contains "$out" "already on the latest release"

t_begin "--force re-downloads even when the version matches"
before="$(downloads)"
OC_MOCK_LATEST=9.9.9 run_setup update --force >/dev/null 2>&1
assert_exit 0 "$?"
[ "$(downloads)" -gt "$before" ] && t_pass || t_fail "--force did not download"

t_begin "update to a newer release downloads and reinstalls"
before="$(downloads)"
out="$(OC_MOCK_LATEST=9.9.10 run_setup update 2>&1)"; rc=$?
assert_exit 0 "$rc" "update failed: $out"
[ "$(downloads)" -gt "$before" ] && t_pass || t_fail "newer release was not downloaded"
assert_contains "$out" "9.9.9 -> v9.9.10"

t_begin "update does not downgrade when the install is newer"
out="$(OC_MOCK_LATEST=9.9.8 run_setup update 2>&1)"; rc=$?
assert_exit 0 "$rc" "update should be a no-op, got $rc: $out"
assert_contains "$out" "not downgrading"

t_begin "explicit older version is still honoured as a pin"
out="$(run_setup update 9.9.7 2>&1)"; rc=$?
assert_exit 0 "$rc" "pinned update failed: $out"
assert_contains "$out" "target: v9.9.7"

t_begin "dry-run update changes nothing"
before="$(downloads)"
OC_MOCK_LATEST=9.9.11 run_setup update --dry-run >/dev/null 2>&1
assert_exit 0 "$?"
assert_eq "$before" "$(downloads)" "dry-run downloaded a release"

t_summary
