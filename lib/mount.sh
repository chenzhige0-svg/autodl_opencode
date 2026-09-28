#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # OC_PERSIST_* are read by callers in lib/*.sh
# lib/mount.sh - real mount detection and persistence store selection.
#
# Critical rule (from the requirements): a directory existing is NOT proof that
# a data disk / file storage is mounted. We must verify the mount itself before
# we write persistent data, otherwise a plain directory on the system disk could
# masquerade as durable storage and be silently lost on image reset.

# path_is_mounted <dir> -> 0 when <dir> is a mount point / distinct fs
path_is_mounted() {
  local d="$1" canon parent
  [ -d "$d" ] || return 1

  # Test hook: colon separated list of paths treated as mounted.
  if [ -n "${OCDEPLOY_TEST_MOUNTS:-}" ]; then
    local IFS=':' p
    for p in $OCDEPLOY_TEST_MOUNTS; do
      [ "$p" = "$d" ] && return 0
    done
  fi
  # Test hook: colon separated list of paths treated as NOT mounted.
  if [ -n "${OCDEPLOY_TEST_UNMOUNTED:-}" ]; then
    local IFS=':' p
    for p in $OCDEPLOY_TEST_UNMOUNTED; do
      [ "$p" = "$d" ] && return 1
    done
  fi

  canon="$(cd "$d" 2>/dev/null && pwd -P)" || canon="$d"

  if have_cmd mountpoint; then
    mountpoint -q -- "$canon" 2>/dev/null && return 0
  fi
  if have_cmd findmnt; then
    if findmnt -rn --mountpoint "$canon" >/dev/null 2>&1; then return 0; fi
    if findmnt -rn -M "$canon" >/dev/null 2>&1; then return 0; fi
  fi
  # /proc/self/mountinfo (space-escaped field 5 is the mount point)
  if [ -r /proc/self/mountinfo ]; then
    awk -v t="$canon" '{ gsub(/\\040/," ",$5); if ($5==t) {found=1; exit} } END{exit !found}' \
      /proc/self/mountinfo && return 0
  fi
  # Fallback heuristic: a different device id than the parent means a mount
  # boundary exists at (or below) this directory.
  parent="$(dirname "$canon")"
  if [ "$canon" != "/" ] && [ "$parent" != "$canon" ]; then
    local dd dp
    dd="$(stat -c %d "$canon" 2>/dev/null || printf '')"
    dp="$(stat -c %d "$parent" 2>/dev/null || printf '')"
    if [ -n "$dd" ] && [ -n "$dp" ] && [ "$dd" != "$dp" ]; then
      return 0
    fi
  fi
  return 1
}

mount_source() {
  local d="$1" canon
  canon="$(cd "$d" 2>/dev/null && pwd -P)" || canon="$d"
  if have_cmd findmnt; then
    findmnt -rno SOURCE,FSTYPE --mountpoint "$canon" 2>/dev/null && return 0
  fi
  df -P "$canon" 2>/dev/null | awk 'NR==2 {print $1, $6}'
}

# persist_tier_of <dir> -> fs|tmp|external|unknown
persist_tier_of() {
  local d="$1"
  case "$d" in
    "$OC_AUTODL_FS"|"$OC_AUTODL_FS"/*) printf 'fs' ;;
    "$OC_AUTODL_TMP"|"$OC_AUTODL_TMP"/*) printf 'tmp' ;;
    /root/autodl-fs*|/root/autodl-tmp*) printf 'autodl' ;;
    *) printf 'external' ;;
  esac
}

# Validate a candidate store. Sets nothing; returns 0 when usable.
persist_store_usable() {
  local d="$1" need_mount="${2:-yes}"
  [ -n "$d" ] || return 1
  [ -d "$d" ] || return 1
  if [ "$need_mount" = "yes" ] && ! path_is_mounted "$d"; then
    return 1
  fi
  is_writable_dir "$d" || return 1
  return 0
}

# persist_select_store -> sets OC_PERSIST_TIER and OC_PERSIST_STORE.
# Returns 0 when a usable store was found, 1 otherwise.
persist_select_store() {
  OC_PERSIST_TIER=""
  OC_PERSIST_STORE=""
  local mode="$OC_PERSIST_MODE" dir=""
  case "$mode" in
    none)
      return 1
      ;;
    fs)
      dir="${OC_PERSIST_DIR:-$OC_AUTODL_FS}"
      if persist_store_usable "$dir" yes; then
        OC_PERSIST_TIER="fs"; OC_PERSIST_STORE="$dir"; return 0
      fi
      log_warn "persistence mode=fs but '$dir' is not a mounted writable directory"
      return 1
      ;;
    tmp)
      dir="${OC_PERSIST_DIR:-$OC_AUTODL_TMP}"
      if persist_store_usable "$dir" yes; then
        OC_PERSIST_TIER="tmp"; OC_PERSIST_STORE="$dir"; return 0
      fi
      log_warn "persistence mode=tmp but '$dir' is not a mounted writable directory"
      return 1
      ;;
    path)
      if [ -z "$OC_PERSIST_DIR" ]; then
        log_warn "persistence mode=path requires OPENCODE_PERSIST_DIR"
        return 1
      fi
      if persist_store_usable "$OC_PERSIST_DIR" no; then
        OC_PERSIST_TIER="$(persist_tier_of "$OC_PERSIST_DIR")"; OC_PERSIST_STORE="$OC_PERSIST_DIR"; return 0
      fi
      log_warn "persistence path '$OC_PERSIST_DIR' is not a writable directory"
      return 1
      ;;
    auto|*)
      # Prefer cross-instance file storage, then instance-local data disk.
      if persist_store_usable "$OC_AUTODL_FS" yes; then
        OC_PERSIST_TIER="fs"; OC_PERSIST_STORE="$OC_AUTODL_FS"; return 0
      fi
      if persist_store_usable "$OC_AUTODL_TMP" yes; then
        OC_PERSIST_TIER="tmp"; OC_PERSIST_STORE="$OC_AUTODL_TMP"; return 0
      fi
      return 1
      ;;
  esac
}

# persist_dir <name> -> "$store/opencode/<name>" (caller must have selected)
persist_dir() {
  [ -n "$OC_PERSIST_STORE" ] || return 1
  printf '%s/opencode/%s' "$OC_PERSIST_STORE" "$1"
}

# Short human description of what a persistence tier survives.
persist_tier_description() {
  case "$1" in
    fs)       printf 'cross-instance file storage (survives release; same region)' ;;
    tmp)      printf 'instance data disk (survives restart and image reset; lost on release)' ;;
    external) printf 'external path (durability depends on the underlying storage)' ;;
    *)        printf 'unknown' ;;
  esac
}
