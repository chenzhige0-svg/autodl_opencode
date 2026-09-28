#!/usr/bin/env bash
# shellcheck disable=SC2034  # OC_PERSIST_* are consumed by sourced libraries
# tests/test_mount_persist.sh - mount-aware persistence selection and symlinking.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; source_libs
use_sandbox_autodl_paths
trap cleanup_sandbox EXIT

unmount_all
t_begin "auto mode refuses when nothing is mounted"
assert_ne 0 "$(persist_select_store && echo 0 || echo 1)"

t_begin "fs mode refuses an unmounted directory"
OC_PERSIST_MODE=fs
assert_ne 0 "$(persist_select_store && echo 0 || echo 1)"
assert_file_missing "$OC_AUTODL_FS/opencode"

t_begin "no fake directory is created for an unmounted store"
assert_file_missing "$OC_AUTODL_FS/opencode"

t_begin "auto mode selects file storage when mounted"
OC_PERSIST_MODE=auto; mark_fs_mounted
persist_select_store; rc=$?
assert_eq 0 "$rc"
assert_eq "fs" "$OC_PERSIST_TIER"
assert_eq "$OC_AUTODL_FS" "$OC_PERSIST_STORE"

t_begin "auto mode falls back to the data disk"
unmount_all; mark_tmp_mounted
persist_select_store; rc=$?
assert_eq 0 "$rc"
assert_eq "tmp" "$OC_PERSIST_TIER"

t_begin "path mode requires an explicit existing directory"
OC_PERSIST_MODE=path; OC_PERSIST_DIR="$SBX/does-not-exist"
assert_ne 0 "$(persist_select_store && echo 0 || echo 1)"

t_begin "applying persistence symlinks and preserves existing data"
mark_fs_mounted; OC_PERSIST_MODE=auto
persist_select_store
mkdir -p "$OC_CONFIG_HOME"
printf '{"user":1}\n' >"$OC_CONFIG_HOME/opencode.json"
config_persistence_apply >/dev/null 2>&1
[ -L "$OC_CONFIG_HOME" ] && t_pass || t_fail "config dir is not a symlink"
assert_contains "$(cat "$OC_CONFIG_HOME/opencode.json")" '"user":1'
assert_file_exists "$OC_PERSIST_STORE/opencode/config/opencode.json"

t_begin "data directory is persisted too"
assert_eq "linked" "$(config_persistence_status | awk -F'\t' '$1=="data"{print $2}')"

t_begin "applying persistence twice is idempotent"
config_persistence_apply >/dev/null 2>&1
assert_contains "$(cat "$OC_CONFIG_HOME/opencode.json")" '"user":1'

t_begin "unpersist restores a real local directory"
config_persistence_remove >/dev/null 2>&1
[ ! -L "$OC_CONFIG_HOME" ] && [ -d "$OC_CONFIG_HOME" ] && t_pass || t_fail "not restored to a real dir"
assert_contains "$(cat "$OC_CONFIG_HOME/opencode.json")" '"user":1'

t_summary
