#!/usr/bin/env bash
# tests/test_detect.sh - unit tests for detection and mount primitives.
. "$(dirname "${BASH_SOURCE[0]}")/framework.sh"
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

make_sandbox; sandbox_env; source_libs
trap cleanup_sandbox EXIT

t_begin "os_pretty is non-empty"
v="$(detect_os_pretty)"; [ -n "$v" ] && t_pass || t_fail "empty os"
t_begin "arch maps to x64 or arm64"
a="$(oc_arch)"; case "$a" in x64|arm64) t_pass ;; *) t_fail "unexpected arch: $a" ;; esac
t_begin "install target starts with linux/darwin"
tg="$(oc_install_target)"; case "$tg" in linux-*|darwin-*) t_pass ;; *) t_fail "target=$tg" ;; esac
t_begin "user and home detected"
[ -n "$(detect_user)" ] && [ -n "$(detect_home)" ] && t_pass || t_fail "no user/home"

t_begin "real directory is not a mount point"
assert_ne 0 "$(path_is_mounted "$SBX/home" && echo 0 || echo 1)"
t_begin "test hook marks a directory as mounted"
mark_fs_mounted
assert_eq 0 "$(path_is_mounted "$SBX/mnt/autodl-fs" && echo 0 || echo 1)"
t_begin "test hook marks a directory as unmounted"
unmount_all
assert_eq 1 "$(path_is_mounted "$SBX/mnt/autodl-fs" && echo 0 || echo 1)"

t_begin "disk availability is numeric"
av="$(oc_disk_avail_kb "$SBX")"
case "$av" in ''|*[!0-9]*) t_fail "non-numeric: $av" ;; *) t_pass ;; esac

t_begin "detect_autodl is yes/no"
case "$(detect_autodl)" in yes|no) t_pass ;; *) t_fail "bad value" ;; esac

t_summary
