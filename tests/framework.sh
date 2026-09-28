#!/usr/bin/env bash
# shellcheck shell=bash
# tests/framework.sh - minimal dependency-free test framework.
# (bash 4+, no bats required).

T_PASS=0
T_FAIL=0
T_SKIP=0
T_CURRENT=""
T_SUITE="$(basename "${BASH_SOURCE[1]:-test}" .sh)"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  TC_G=$'\033[32m'; TC_R=$'\033[31m'; TC_Y=$'\033[33m'; TC_D=$'\033[2m'; TC_0=$'\033[0m'
else
  TC_G=""; TC_R=""; TC_Y=""; TC_D=""; TC_0=""
fi

t_begin() { T_CURRENT="$1"; }
t_pass() { T_PASS=$((T_PASS + 1)); printf '  %sok%s   %s\n' "$TC_G" "$TC_0" "$T_CURRENT"; }
t_fail() { T_FAIL=$((T_FAIL + 1)); printf '  %sFAIL%s %s\n       %s\n' "$TC_R" "$TC_0" "$T_CURRENT" "$1"; }
t_skip() { T_SKIP=$((T_SKIP + 1)); printf '  %sskip%s %s (%s)\n' "$TC_Y" "$TC_0" "$T_CURRENT" "$1"; }

assert_eq() { # expected actual [msg]
  if [ "$1" = "$2" ]; then t_pass; else t_fail "${3:-expected '$1' got '$2'}"; fi
}
assert_ne() {
  if [ "$1" != "$2" ]; then t_pass; else t_fail "${3:-values should differ ('$1')}"; fi
}
assert_contains() { # haystack needle
  case "$1" in *"$2"*) t_pass ;; *) t_fail "${3:-expected to contain '$2' in: $1}" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) t_fail "${3:-should not contain '$2'}" ;; *) t_pass ;; esac
}
assert_file_exists() {
  if [ -e "$1" ]; then t_pass; else t_fail "${2:-missing file: $1}"; fi
}
assert_file_missing() {
  if [ ! -e "$1" ]; then t_pass; else t_fail "${2:-file should not exist: $1}"; fi
}
assert_dir_exists() {
  if [ -d "$1" ]; then t_pass; else t_fail "${2:-missing dir: $1}"; fi
}
assert_exit() { # expected actual
  if [ "$1" = "$2" ]; then t_pass; else t_fail "${3:-expected exit $1 got $2}"; fi
}

# assert_cmd_status <expected> <cmd...>
assert_cmd_status() {
  local expected="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" = "$expected" ]; then t_pass; else t_fail "expected rc=$expected got rc=$rc; output: $out"; fi
}

t_summary() {
  printf '%s\n' "${TC_D}--- $T_SUITE: $T_PASS passed, $T_FAIL failed, $T_SKIP skipped ---${TC_0}"
  if [ -n "${T_SUMMARY_FILE:-}" ]; then
    printf '%s %s %s %s\n' "$T_SUITE" "$T_PASS" "$T_FAIL" "$T_SKIP" >>"$T_SUMMARY_FILE"
  fi
  [ "$T_FAIL" -eq 0 ]
}
