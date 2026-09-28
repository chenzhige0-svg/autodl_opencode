#!/usr/bin/env bash
# tests/test_path.sh - PATH repair, managed blocks, conflict detection.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; prepare_archive; source_libs
trap cleanup_sandbox EXIT

run_setup install >/dev/null 2>&1

t_begin "managed block written to bash_profile"
assert_contains "$(cat "$HOME/.bash_profile" 2>/dev/null)" "opencode-autodl"

t_begin "managed block is idempotent (single occurrence)"
run_setup repair >/dev/null 2>&1
n="$(grep -c 'opencode-autodl >>>' "$HOME/.bash_profile" 2>/dev/null || true)"
assert_eq "1" "$n"

t_begin "new interactive login shell resolves opencode"
res="$(HOME="$HOME" bash -lic 'command -v opencode' 2>/dev/null | tail -1)"
assert_contains "$res" ".opencode/bin/opencode"

t_begin "non-interactive login shell resolves opencode"
res="$(HOME="$HOME" bash -lc 'command -v opencode' 2>/dev/null | tail -1)"
assert_contains "$res" ".opencode/bin/opencode"

t_begin "no false conflict with a single install"
c="$(path_list_conflicts | grep -c . || true)"
assert_eq "1" "$c"

t_begin "second install path is detected as a conflict"
cp "$MOCKS/opencode" "$SBX/bin/opencode"; chmod +x "$SBX/bin/opencode"
c="$(path_list_conflicts | grep -c . || true)"
assert_eq "2" "$c"

t_summary
