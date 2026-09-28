#!/usr/bin/env bash
# shellcheck shell=bash
# lib/detect.sh - read-only environment detection primitives.
# All functions here are non-mutating and safe to run as an unprivileged user.

# --- OS / platform ----------------------------------------------------------
detect_os_pretty() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [ -n "${PRETTY_NAME:-}" ]; then printf '%s' "$PRETTY_NAME"; return 0; fi
    if [ -n "${NAME:-}" ]; then printf '%s %s' "$NAME" "${VERSION:-}"; return 0; fi
  fi
  uname -s 2>/dev/null || printf 'unknown'
}

detect_kernel() { uname -r 2>/dev/null || printf 'unknown'; }
detect_arch_raw() { uname -m 2>/dev/null || printf 'unknown'; }
detect_os_id() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s' "${ID:-unknown}"
  else
    printf 'unknown'
  fi
}

detect_user() { id -un 2>/dev/null || printf '%s' "${USER:-unknown}"; }
detect_home() { printf '%s' "$HOME"; }
detect_uid() { id -u 2>/dev/null || printf '1'; }
detect_login_shell() {
  if [ -n "${OCDEPLOY_LOGIN_SHELL:-}" ]; then
    printf '%s' "$OCDEPLOY_LOGIN_SHELL"; return 0
  fi
  if have_cmd getent; then
    local sh; sh="$(getent passwd "$(detect_user)" 2>/dev/null | awk -F: '{print $7}')"
    [ -n "$sh" ] && { printf '%s' "$sh"; return; }
  fi
  printf '%s' "${SHELL:-/bin/sh}"
}
detect_current_shell() { basename "${SHELL:-/bin/sh}" 2>/dev/null || printf 'sh'; }

# --- AutoDL -----------------------------------------------------------------
# Detect an AutoDL container by well-known artefacts. Never trust a single
# signal: directories may exist without being mounted.
detect_autodl() {
  local hits=0
  [ -e /etc/network_turbo ] && hits=$((hits + 1))
  [ -d "$OC_AUTODL_TMP" ] && hits=$((hits + 1))
  [ -d "$OC_AUTODL_FS" ] && hits=$((hits + 1))
  [ -d "$OC_AUTODL_PUB" ] && hits=$((hits + 1))
  ls -d /etc/autodl* /usr/local/bin/autodl* >/dev/null 2>&1 && hits=$((hits + 1))
  [ "$hits" -ge 2 ] && printf 'yes' || printf 'no'
}

autodl_network_turbo_available() { [ -r /etc/network_turbo ]; }

# --- Tools ------------------------------------------------------------------
# tool_version <cmd> -> prints "path<TAB>version" or empty
tool_version() {
  local cmd="$1" path ver=""
  path="$(command -v "$cmd" 2>/dev/null)" || return 1
  case "$cmd" in
    curl)    ver="$(curl --version 2>/dev/null | head -1)" ;;
    wget)    ver="$(wget --version 2>/dev/null | head -1)" ;;
    git)     ver="$(git --version 2>/dev/null)" ;;
    tar)     ver="$(tar --version 2>/dev/null | head -1)" ;;
    unzip)   ver="$(unzip -v 2>/dev/null | head -1)" ;;
    node)    ver="node $(node --version 2>/dev/null)" ;;
    npm)     ver="npm $(npm --version 2>/dev/null)" ;;
    bun)     ver="bun $(bun --version 2>/dev/null)" ;;
    pnpm)    ver="pnpm $(pnpm --version 2>/dev/null)" ;;
    python3) ver="$(python3 --version 2>&1)" ;;
    *)       ver="$("$cmd" --version 2>/dev/null | head -1)" ;;
  esac
  printf '%s\t%s' "$path" "$ver"
}

detect_tools_report() {
  local t
  for t in curl wget git tar unzip ca-certificates node npm bun pnpm python3; do
    if [ "$t" = "ca-certificates" ]; then
      if [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ]; then
        printf 'ca-certificates\tpresent\tpresent\n'
      else
        printf 'ca-certificates\tmissing\tmissing\n'
      fi
      continue
    fi
    if line="$(tool_version "$t")"; then
      printf '%s\n' "$t\t$line"
    else
      printf '%s\tmissing\tmissing\n' "$t"
    fi
  done
}

# --- Disk -------------------------------------------------------------------
# disk_report <path> -> "size_kb avail_kb use_percent fstype mountpoint"
disk_report() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $2, $4, $5, $1}'
}

oc_disk_avail_kb() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

# --- OpenCode discovery -----------------------------------------------------
# find_opencode_binaries -> one absolute path per line, de-duplicated
find_opencode_binaries() {
  local seen="" dir p
  # PATH entries
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    p="$dir/opencode"
    if [ -x "$p" ]; then
      case ":$seen:" in *":$p:"*) ;; *) printf '%s\n' "$p"; seen="$seen:$p" ;; esac
    fi
  done <<EOF
$(printf '%s' "$PATH" | tr ':' '\n')
EOF
  # Well-known install locations
  for p in \
    "$OC_HOME_INSTALL_DIR/opencode" \
    "$HOME/.opencode/bin/opencode" \
    "$HOME/.local/bin/opencode" \
    "$HOME/.bun/bin/opencode" \
    "/usr/local/bin/opencode" \
    "/usr/bin/opencode" \
    "/root/.opencode/bin/opencode" \
    "/root/.local/bin/opencode"; do
    if [ -x "$p" ]; then
      case ":$seen:" in *":$p:"*) ;; *) printf '%s\n' "$p"; seen="$seen:$p" ;; esac
    fi
  done
}

# opencode_version_at <path> -> prints version or empty
opencode_version_at() {
  local bin="$1" out
  [ -x "$bin" ] || return 1
  if have_cmd timeout; then
    out="$(timeout 20 "$bin" --version 2>/dev/null)" || return 1
  else
    out="$("$bin" --version 2>/dev/null)" || return 1
  fi
  out="$(printf '%s' "$out" | tr -d '\r' | head -1)"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# detect_install_method <bin> -> curl|npm|bun|pnpm|brew|unknown
detect_install_method() {
  local bin="$1" real
  real="$(readlink -f "$bin" 2>/dev/null || printf '%s' "$bin")"
  case "$real" in
    */.opencode/bin/*) printf 'curl' ;;
    */.bun/*)          printf 'bun' ;;
    */lib/node_modules/*|*/node_modules/*) printf 'npm' ;;
    */pnpm/*)          printf 'pnpm' ;;
    */Cellar/*|*/homebrew/*) printf 'brew' ;;
    /usr/bin/*|/usr/local/bin/*) printf 'system' ;;
    *) printf 'unknown' ;;
  esac
}

# resolve_in_path <cmd> -> absolute path or empty
resolve_in_path() { command -v "$1" 2>/dev/null || true; }

# Check whether a login/interactive shell can see the opencode binary.
# new_shell_can_find_opencode [shell] -> prints PATH-resolved location or empty
new_shell_can_find_opencode() {
  local sh="${1:-$(detect_login_shell)}"
  [ -x "$sh" ] || sh="/bin/sh"
  # shellcheck disable=SC2016
  "$sh" -lic 'command -v opencode' 2>/dev/null | tail -1
}

# Non-interactive shell (scripts, ssh command execution)
new_noninteractive_shell_can_find_opencode() {
  local sh="${1:-/bin/sh}"
  [ -x "$sh" ] || sh="/bin/sh"
  # shellcheck disable=SC2016
  "$sh" -lc 'command -v opencode' 2>/dev/null | tail -1
}
