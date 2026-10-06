#!/usr/bin/env bash
# tests/test_preset.sh - non-secret config presets (config/presets/<name>.jsonc).
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; source_libs
trap cleanup_sandbox EXIT

cfg="$OPENCODE_CONFIG_HOME/opencode.json"

t_begin "deepseek preset validates as JSONC"
assert_cmd_status 0 config_validate_file "$PROJECT/config/presets/deepseek.jsonc"

t_begin "preset resolves from OPENCODE_PRESET"
resolved="$(OPENCODE_PRESET=deepseek config_preset_file 2>/dev/null)"
assert_eq "$PROJECT/config/presets/deepseek.jsonc" "$resolved"

t_begin "unsafe preset name is rejected"
if OPENCODE_PRESET='../etc/passwd' config_preset_file >/dev/null 2>&1; then
  t_fail "unsafe preset name was accepted"
else
  t_pass
fi

t_begin "fresh config uses the deepseek preset"
export OPENCODE_PRESET=deepseek
config_generate >/dev/null 2>&1
assert_file_exists "$cfg"
assert_contains "$(cat "$cfg")" "deepseek/deepseek-flash"
assert_contains "$(cat "$cfg")" '"reasoningEffort": "max"'
unset OPENCODE_PRESET

t_begin "preset merges into existing config (keeps user keys, no prompt)"
printf '{\n  "custom_key": "keepme",\n  "model": "a/b"\n}\n' >"$cfg"
export OPENCODE_PRESET=deepseek
config_generate >/dev/null 2>&1
merged="$(cat "$cfg")"
assert_contains "$merged" "keepme"
assert_contains "$merged" "deepseek/deepseek-flash"
unset OPENCODE_PRESET

t_begin "--preset flag applies on the command line"
printf '{\n  "model": "a/b"\n}\n' >"$cfg"
run_setup config --preset deepseek >/dev/null 2>&1
assert_contains "$(cat "$cfg")" "deepseek/deepseek-flash"

t_begin "explicit env override wins over the preset"
printf '{\n  "model": "a/b"\n}\n' >"$cfg"
export OPENCODE_PRESET=deepseek OPENCODE_MODEL="x/y" ASSUME_YES=1
config_generate >/dev/null 2>&1
assert_eq "x/y" "$(config_py get "$cfg" model)"
unset OPENCODE_PRESET OPENCODE_MODEL ASSUME_YES

t_begin "unknown preset leaves an existing config untouched"
printf '{"user_marker":"keep"}\n' >"$cfg"
before="$(cat "$cfg")"
export OPENCODE_PRESET="does-not-exist"
config_generate >/dev/null 2>&1
assert_eq "$before" "$(cat "$cfg")"
unset OPENCODE_PRESET

t_summary
