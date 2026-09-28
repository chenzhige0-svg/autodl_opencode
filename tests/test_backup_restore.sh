#!/usr/bin/env bash
# tests/test_backup_restore.sh - config backup/restore and credential separation.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; source_libs
trap cleanup_sandbox EXIT

mkdir -p "$OC_CONFIG_HOME"
printf '{"a":1}\n' >"$OC_CONFIG_HOME/opencode.json"
mkdir -p "$OC_DATA_HOME"
printf '{"secret":"token"}\n' >"$OC_DATA_HOME/auth.json"
chmod 644 "$OC_DATA_HOME/auth.json"

t_begin "backup without credentials contains config only"
dest="$(backup_run 0 0 2>/dev/null)"
assert_dir_exists "$dest/config"
assert_file_missing "$dest/credentials"
assert_file_exists "$dest/manifest.json"

t_begin "backup does not leak credentials by default"
assert_not_contains "$(cat "$dest/manifest.json")" '"has_credentials": true'

t_begin "backup with credentials separates them and restricts perms"
dest2="$(backup_run 1 0 2>/dev/null)"
assert_file_exists "$dest2/credentials/auth.json"
assert_eq "600" "$(stat -c '%a' "$dest2/credentials/auth.json")"
assert_contains "$(cat "$dest2/manifest.json")" '"has_credentials": true'

t_begin "restore recovers the original config content"
printf '{"a":2}\n' >"$OC_CONFIG_HOME/opencode.json"
restore_run "$dest" 0 >/dev/null 2>&1
assert_eq '{"a":1}' "$(cat "$OC_CONFIG_HOME/opencode.json")"

t_begin "restore preserves the current config before overwriting"
found="$(find "$OCDEPLOY_BACKUP_DIR" -name 'config-before-restore' -type d 2>/dev/null | wc -l | tr -d ' ')"
[ "$found" -ge 1 ] && t_pass || t_fail "no pre-restore backup found"

t_begin "restore skips credentials unless requested"
printf '{"old":"x"}\n' >"$OC_DATA_HOME/auth.json"
restore_run "$dest2" 0 >/dev/null 2>&1
assert_contains "$(cat "$OC_DATA_HOME/auth.json")" '"old"'

t_begin "restore with credentials overwrites and restricts perms"
restore_run "$dest2" 1 >/dev/null 2>&1
assert_contains "$(cat "$OC_DATA_HOME/auth.json")" '"secret"'
assert_eq "600" "$(stat -c '%a' "$OC_DATA_HOME/auth.json")"

t_summary
