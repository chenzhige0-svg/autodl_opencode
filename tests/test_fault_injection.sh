#!/usr/bin/env bash
# tests/test_fault_injection.sh - induced failures must degrade safely.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; source_libs
trap cleanup_sandbox EXIT

# --- 1. download failure ---------------------------------------------------
t_begin "failed download exits non-zero"
export OC_MOCK_CURL_FAIL=1 OC_MOCK_CURL_FAIL_EXIT=28
run_setup install >/dev/null 2>&1
assert_ne 0 "$?"

t_begin "failed download leaves no binary behind"
assert_file_missing "$OPENCODE_BIN"

t_begin "failed download is not marked as a successful install"
assert_file_missing "$OCDEPLOY_STATE_HOME/install-state.json"

t_begin "retry is bounded (single attempt with attempts=1)"
n="$(grep -c '' "$OC_MOCK_CURL_LOG" 2>/dev/null || echo 0)"
assert_eq "1" "$n"

# --- 2. broken binary is repaired locally then reinstalled -----------------
sandbox_env; prepare_archive
t_begin "broken binary recovers via repair"
mkdir -p "$OPENCODE_INSTALL_DIR"
printf '#!/bin/sh\nexit 1\n' >"$OPENCODE_BIN"; chmod +x "$OPENCODE_BIN"
assert_eq "broken" "$(install_status)"
run_setup repair >/dev/null 2>&1
assert_eq "9.9.9" "$("$OPENCODE_BIN" --version 2>/dev/null)"

# --- 3. missing credentials -> partial result, not failure -----------------
sandbox_env; prepare_archive
run_setup install >/dev/null 2>&1
export PATH="$OPENCODE_INSTALL_DIR:$PATH"
t_begin "verify reports 'needs authentication' (exit 4)"
run_setup verify >/dev/null 2>&1
assert_exit 4 "$?"

t_begin "installing credentials flips verify to success"
mkdir -p "$OC_DATA_HOME"
printf '{"test":{"type":"api"}}\n' >"$OC_DATA_HOME/auth.json"
chmod 600 "$OC_DATA_HOME/auth.json"
run_setup verify >/dev/null 2>&1
assert_exit 0 "$?"

# --- 4. unmounted store must be refused ------------------------------------
sandbox_env; use_sandbox_autodl_paths; unmount_all
t_begin "persist refuses an unmounted file storage"
export OC_PERSIST_MODE=fs
run_setup persist >/dev/null 2>&1
assert_ne 0 "$?"

t_begin "refused persist did not fabricate a store directory"
assert_file_missing "$OC_AUTODL_FS/opencode"

# --- 5. corrupt config is detected by doctor -------------------------------
sandbox_env
mkdir -p "$OC_CONFIG_HOME"
printf '{ this is not json ]\n' >"$OC_CONFIG_HOME/opencode.json"
t_begin "doctor flags an invalid config (CFG002)"
out="$(run_setup doctor 2>&1)"
assert_contains "$out" "CFG002"

t_begin "doctor returns non-zero when a real error is present"
run_setup doctor >/dev/null 2>&1
assert_exit 1 "$?"

t_begin "doctor exits clean once the config is valid"
printf '{"model":"a/b"}\n' >"$OC_CONFIG_HOME/opencode.json"
run_setup doctor >/dev/null 2>&1
assert_exit 0 "$?"

t_summary
