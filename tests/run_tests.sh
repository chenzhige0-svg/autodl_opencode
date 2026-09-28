#!/usr/bin/env bash
# tests/run_tests.sh - run every tests/test_*.sh suite and aggregate results.
set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

T_SUMMARY_FILE="$(mktemp "${TMPDIR:-/tmp}/oc-test-summary.XXXXXX")"
export T_SUMMARY_FILE

suites=0; failed_suites=0
for t in "$TESTS_DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  name="$(basename "$t")"
  printf '\n=== %s ===\n' "$name"
  bash "$t"
  rc=$?
  suites=$((suites + 1))
  if [ "$rc" -ne 0 ]; then failed_suites=$((failed_suites + 1)); fi
done

pass=0; fail=0; skip=0
if [ -s "$T_SUMMARY_FILE" ]; then
  while read -r _suite p f s; do
    pass=$((pass + p)); fail=$((fail + f)); skip=$((skip + s))
  done <"$T_SUMMARY_FILE"
fi
rm -f "$T_SUMMARY_FILE"

printf '\n========================================\n'
printf 'TOTAL: %d assertions passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
printf 'SUITES: %d run, %d failed\n' "$suites" "$failed_suites"
printf '========================================\n'

[ "$fail" -eq 0 ] && [ "$failed_suites" -eq 0 ]
