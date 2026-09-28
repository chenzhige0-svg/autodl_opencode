#!/usr/bin/env bash
# tests/test_config.sh - JSONC validation, generation, safe merge/repair.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; source_libs
trap cleanup_sandbox EXIT

t_begin "JSONC template validates"
assert_cmd_status 0 config_validate_file "$PROJECT/config/opencode.template.jsonc"

t_begin "generation creates a config using OPENCODE_MODEL"
export OPENCODE_MODEL="test/provider-model"
config_generate >/dev/null 2>&1
cfg="$OPENCODE_CONFIG_HOME/opencode.json"
assert_file_exists "$cfg"
assert_contains "$(cat "$cfg")" "test/provider-model"

t_begin "existing config is not clobbered when no overrides requested"
unset OPENCODE_MODEL
printf '{\n  "custom_key": "keepme"\n}\n' >"$cfg"
config_generate >/dev/null 2>&1
assert_contains "$(cat "$cfg")" "keepme"

t_begin "explicit overrides merge while preserving user keys"
export OPENCODE_MODEL="new/model"
export ASSUME_YES=1
config_generate >/dev/null 2>&1
merged="$(cat "$cfg")"
assert_contains "$merged" "keepme"
assert_contains "$merged" "new/model"
unset ASSUME_YES

t_begin "invalid JSON is repaired or quarantined safely"
printf '{ "model": }\n' >"$cfg"
repair_config_file >/dev/null 2>&1
assert_cmd_status 0 config_validate_file "$cfg"

t_begin "quarantine copy of the invalid config exists"
qcount="$(find "$OPENCODE_CONFIG_HOME" -name 'opencode.json*.oc-invalid-*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$qcount" -ge 1 ] && t_pass || t_fail "no quarantined invalid config found"

t_begin "jsonc with comments validates"
printf '{\n  // comment\n  "model": "a/b",\n}\n' >"$OC_CONFIG_HOME/test.jsonc"
assert_cmd_status 0 config_validate_file "$OC_CONFIG_HOME/test.jsonc"

t_begin "python merge helper respects override precedence"
printf '{"a":{"x":1,"y":2}}\n' >"$SBX/base.json"
printf '{"a":{"y":9}}\n' >"$SBX/ovr.json"
config_py merge "$SBX/base.json" "$SBX/ovr.json" "$SBX/out.json" >/dev/null 2>&1
assert_eq "9" "$(config_py get "$SBX/out.json" a.y)"
assert_eq "1" "$(config_py get "$SBX/out.json" a.x)"

t_summary
