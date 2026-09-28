#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # configuration contract shared across lib/*.sh
# lib/common.sh - core utilities: configuration, logging, redaction, dry-run,
# atomic writes, backups, locking and exit codes.
#
# This file is sourced by setup.sh and the test framework. It must not have
# side effects beyond defining functions and computing non-mutating defaults.

# ---------------------------------------------------------------------------
# Exit codes (stable contract for CI and callers)
# ---------------------------------------------------------------------------
OC_EXIT_OK=0
OC_EXIT_ERROR=1
OC_EXIT_USAGE=2
OC_EXIT_ENV=3          # environment/network problem
OC_EXIT_PARTIAL=4      # installed but action still required (e.g. auth)
OC_EXIT_VERIFY=5       # verification failed
OC_EXIT_UNSAFE=6       # can't repair safely, manual action required
OC_EXIT_LOCKED=7       # another instance holds the lock

# ---------------------------------------------------------------------------
# Project layout
# ---------------------------------------------------------------------------
_oc_resolve_root() {
  local src="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
  local dir
  dir="$(cd "$(dirname "$src")/.." 2>/dev/null && pwd)" || dir="$PWD"
  printf '%s' "$dir"
}
OCDEPLOY_ROOT="${OCDEPLOY_ROOT:-$(_oc_resolve_root)}"
export OCDEPLOY_ROOT

# ---------------------------------------------------------------------------
# User-tunable paths and defaults
# ---------------------------------------------------------------------------
: "${HOME:=$(printf '%s' ~)}"

OC_HOME_INSTALL_DIR="${OPENCODE_INSTALL_DIR:-$HOME/.opencode/bin}"
OC_BIN="${OPENCODE_BIN:-$OC_HOME_INSTALL_DIR/opencode}"
OC_CONFIG_HOME="${OPENCODE_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}"
OC_DATA_HOME="${OPENCODE_DATA_HOME:-$HOME/.local/share/opencode}"
OC_CACHE_HOME="${OPENCODE_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/opencode}"
OC_STATE_HOME="${OCDEPLOY_STATE_HOME:-$HOME/.local/state/opencode-autodl}"
OC_BACKUP_ROOT="${OCDEPLOY_BACKUP_DIR:-$OC_STATE_HOME/backups}"
OC_LOG_DIR="${OCDEPLOY_LOG_DIR:-$OC_STATE_HOME/logs}"

# Persistence store selection. Modes:
#   auto  - pick file storage, else data disk, else refuse
#   fs    - require /root/autodl-fs
#   tmp   - require /root/autodl-tmp
#   path  - require OPENCODE_PERSIST_DIR to be an existing mounted/writable dir
#   none  - disable persistence entirely
OC_PERSIST_MODE="${OPENCODE_PERSIST_MODE:-auto}"
OC_PERSIST_DIR="${OPENCODE_PERSIST_DIR:-}"

# AutoDL well-known paths
OC_AUTODL_TMP="${OC_AUTODL_TMP:-/root/autodl-tmp}"
OC_AUTODL_FS="${OC_AUTODL_FS:-/root/autodl-fs}"
OC_AUTODL_PUB="${OC_AUTODL_PUB:-/root/autodl-pub}"

# Managed shell block markers
OC_MARK_BEGIN="# >>> opencode-autodl >>>"
OC_MARK_END="# <<< opencode-autodl <<<"

# ---------------------------------------------------------------------------
# Global runtime flags (overridable by setup.sh argument parsing)
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
VERBOSE="${VERBOSE:-0}"
JSON_OUTPUT="${JSON_OUTPUT:-0}"
PERSIST_ENABLE="${PERSIST_ENABLE:-ask}"
NO_COLOR="${NO_COLOR:-}"

OC_VERSION="1.0.0"
OC_TS="$(date -u +%Y%m%dT%H%M%SZ)"
OC_RUN_ID="${OC_RUN_ID:-$OC_TS-$$}"
OC_LOG_FILE=""

# ---------------------------------------------------------------------------
# Colours (disabled when not a tty or NO_COLOR set)
# ---------------------------------------------------------------------------
_oc_setup_colors() {
  if [ -t 2 ] && [ -z "$NO_COLOR" ]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
  else
    C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
  fi
}
_oc_setup_colors

# ---------------------------------------------------------------------------
# Redaction - never let secrets reach stdout or the log file
# ---------------------------------------------------------------------------
oc_redact() {
  # Reads stdin, writes redacted text to stdout.
  sed -E \
    -e 's#(https?://)[^/@:[:space:]]+:[^/@[:space:]]+@#\1***:***@#g' \
    -e 's#(Bearer[[:space:]]+)[A-Za-z0-9._~+/-]{6,}#\1***#gI' \
    -e 's#\b(sk-[A-Za-z0-9_-]{4,})#***#g' \
    -e 's#\b(sk-ant-[A-Za-z0-9_-]{4,})#***#g' \
    -e 's#\b(ghp_[A-Za-z0-9]{4,})#***#g' \
    -e 's#\b(github_pat_[A-Za-z0-9_]{4,})#***#g' \
    -e 's#\b(xox[baprs]-[A-Za-z0-9-]{4,})#***#g' \
    -e 's#\b(AIza[0-9A-Za-z_-]{10,})#***#g' \
    -e 's#([?&](api[_-]?key|apikey|token|access[_-]?token|key|password|secret)=)[^&[:space:]]+#\1***#gI' \
    -e 's#((api[_-]?key|apikey|access[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|authorization)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?)[^"'"'"'&[:space:],}]+#\1***#gI'
}

oc_redact_string() { printf '%s' "$1" | oc_redact; }

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
oc_log_init() {
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  mkdir -p "$OC_LOG_DIR" 2>/dev/null || true
  OC_LOG_FILE="$OC_LOG_DIR/opencode-autodl-$OC_TS.log"
  : >"$OC_LOG_FILE" 2>/dev/null || OC_LOG_FILE=""
}

_oc_log_sink() {
  local level="$1"; shift
  local rendering="$1"; shift
  local msg="$*"
  local red
  red="$(oc_redact_string "$msg")"

  case "$level" in
    ERROR) printf '%s%s%s\n' "$C_RED" "$rendering" "$C_RESET" >&2 ;;
    WARN)  printf '%s%s%s\n' "$C_YELLOW" "$rendering" "$C_RESET" >&2 ;;
    DEBUG) if [ "$VERBOSE" = "1" ]; then printf '%s%s%s\n' "$C_DIM" "$rendering" "$C_RESET" >&2; fi ;;
    OK)    printf '%s%s%s\n' "$C_GREEN" "$rendering" "$C_RESET" >&2 ;;
    INFO)  printf '%s\n' "$rendering" >&2 ;;
    *)     printf '%s\n' "$rendering" >&2 ;;
  esac

  if [ -n "$OC_LOG_FILE" ]; then
    printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$red" >>"$OC_LOG_FILE" 2>/dev/null || true
  fi
}

log_info()  { _oc_log_sink INFO  "  $*"; }
log_ok()    { _oc_log_sink OK    "  [ok] $*"; }
log_warn()  { _oc_log_sink WARN  "  [warn] $*"; }
log_error() { _oc_log_sink ERROR "  [error] $*"; }
log_debug() { if [ "$VERBOSE" = "1" ]; then _oc_log_sink DEBUG "  [debug] $*"; fi; }
log_step()  { _oc_log_sink INFO  "${C_BOLD}$*${C_RESET}"; }
log_dry()   { _oc_log_sink WARN  "  [dry-run] $*"; }

# Structured event log (JSONL) appended to the same log file.
oc_event() {
  local event="$1"; shift
  local fields=""
  while [ $# -gt 0 ]; do
    local kv="$1"; shift
    local k="${kv%%=*}"; local v="${kv#*=}"
    v="$(oc_redact_string "$v")"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    fields="$fields,\"$k\":\"$v\""
  done
  local line
  line="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"run\":\"$OC_RUN_ID\",\"event\":\"$event\"$fields}"
  if [ -n "$OC_LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$OC_LOG_FILE" 2>/dev/null || true
  fi
  if [ "$JSON_OUTPUT" = "1" ]; then
    printf '%s\n' "$line" >&2
  fi
}

die() {
  local code="${2:-$OC_EXIT_ERROR}"
  log_error "$1"
  oc_event "fatal" "message=$1" "exit=$code"
  exit "$code"
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; }

is_writable_dir() {
  local d="$1"
  [ -d "$d" ] || return 1
  [ -w "$d" ] || return 1
  return 0
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Render a command line safely for display (uses printf %q).
oc_cmd_str() {
  local out="" a
  for a in "$@"; do
    out="$out$(printf '%q ' "$a")"
  done
  printf '%s' "${out% }"
}

# ---------------------------------------------------------------------------
# Dry-run aware command execution
# ---------------------------------------------------------------------------
run() {
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "$(oc_cmd_str "$@")"
    return 0
  fi
  log_debug "exec: $(oc_cmd_str "$@")"
  "$@"
}

ensure_dir() {
  local d="$1"
  if [ -d "$d" ]; then return 0; fi
  run mkdir -p "$d"
}

# confirm <prompt>; returns 0 when proceeding
confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" = "1" ] || [ "$DRY_RUN" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then
    log_warn "non-interactive session; assuming 'no' for: $prompt (use --yes to accept)"
    return 1
  fi
  local reply
  printf '%s [y/N] ' "$prompt" >&2
  read -r reply || return 1
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Atomic file writes and backups
# ---------------------------------------------------------------------------
# atomic_write <target> : content on stdin
atomic_write() {
  local target="$1"
  local dir; dir="$(dirname "$target")"
  ensure_dir "$dir"
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "write file $target"
    cat >/dev/null
    return 0
  fi
  local tmp
  tmp="$(mktemp "${dir}/.oc-tmp.XXXXXX")" || return 1
  cat >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
}

# backup_path <path> [label] -> prints backup location (or empty on dry-run/no-op)
backup_path() {
  local src="$1"
  local label="${2:-backup}"
  [ -e "$src" ] || { printf ''; return 0; }
  local dest="$OC_BACKUP_ROOT/$OC_TS/$label"
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "backup $src -> $dest"
    printf '%s' "$dest"
    return 0
  fi
  ensure_dir "$dest"
  cp -a "$src" "$dest/" 2>/dev/null || {
    log_warn "failed to back up $src"
    printf ''
    return 1
  }
  log_debug "backed up $src -> $dest"
  printf '%s' "$dest"
}

# ---------------------------------------------------------------------------
# Locking (prevents concurrent modifying runs)
# ---------------------------------------------------------------------------
_oc_lock_dir() { printf '%s' "$OC_STATE_HOME/lock"; }

oc_lock_acquire() {
  local lock; lock="$(_oc_lock_dir)"
  if [ "$DRY_RUN" = "1" ]; then log_dry "acquire lock $lock"; return 0; fi
  ensure_dir "$OC_STATE_HOME"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
    printf '%s\n' "$OC_RUN_ID" >"$lock/run" 2>/dev/null || true
    return 0
  fi
  # lock exists - inspect for staleness
  local owner=""
  [ -f "$lock/pid" ] && owner="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    log_error "another opencode-autodl run is in progress (pid $owner)"
    return "$OC_EXIT_LOCKED"
  fi
  log_warn "removing stale lock (pid ${owner:-unknown} no longer running)"
  rm -rf "$lock" 2>/dev/null || true
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
    return 0
  fi
  log_error "could not acquire lock at $lock"
  return "$OC_EXIT_LOCKED"
}

oc_lock_release() {
  local lock; lock="$(_oc_lock_dir)"
  [ "$DRY_RUN" = "1" ] && return 0
  rm -rf "$lock" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Temporary workspace with cleanup trap
# ---------------------------------------------------------------------------
OC_TMPDIR=""
_oc_tmp_cleanup() {
  if [ -n "$OC_TMPDIR" ] && [ -d "$OC_TMPDIR" ]; then rm -rf "$OC_TMPDIR" 2>/dev/null || true; fi
}
oc_tmp_init() {
  if [ -z "$OC_TMPDIR" ]; then
    OC_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-autodl.XXXXXX")" || die "cannot create temp dir"
    # Only arm the cleanup trap in the main shell. Command substitution runs in
    # a subshell whose EXIT trap would otherwise delete the directory as soon as
    # the substitution returns.
    if [ "${BASHPID:-$$}" = "$$" ]; then
      trap '_oc_tmp_cleanup' EXIT INT TERM
    fi
  fi
  printf '%s' "$OC_TMPDIR"
}

# ---------------------------------------------------------------------------
# Managed shell config block
# ---------------------------------------------------------------------------
# upsert_managed_block <file> <body>  - idempotent, backed up, marker-delimited
upsert_managed_block() {
  local file="$1" body="$2"
  local tmp
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "update managed block in $file"
    return 0
  fi
  if [ -e "$file" ]; then backup_path "$file" "shell-$(basename "$file")" >/dev/null || true; fi
  ensure_dir "$(dirname "$file")"
  tmp="$(mktemp "$(dirname "$file")/.oc-tmp.XXXXXX")" || return 1
  if [ -f "$file" ]; then
    awk -v b="$OC_MARK_BEGIN" -v e="$OC_MARK_END" '
      $0==b {skip=1; next}
      $0==e {skip=0; next}
      skip!=1 {print}
    ' "$file" >"$tmp"
  else
    : >"$tmp"
  fi
  {
    printf '\n%s\n' "$OC_MARK_BEGIN"
    printf '%s\n' "$body"
    printf '%s\n' "$OC_MARK_END"
  } >>"$tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  log_debug "managed block written to $file"
}

managed_block_present() {
  local file="$1"
  [ -f "$file" ] && grep -Fq "$OC_MARK_BEGIN" "$file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Platform helpers
# ---------------------------------------------------------------------------
oc_os() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'darwin' ;;
    Linux) printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) printf 'unknown' ;;
  esac
}

oc_arch() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64) printf 'x64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) printf 'unknown' ;;
  esac
}

oc_install_target() {
  local os arch target
  os="$(oc_os)"; arch="$(oc_arch)"
  target="$os-$arch"
  if [ "$arch" = "x64" ] && [ "$os" = "linux" ] && ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
    target="$target-baseline"
  fi
  if [ "$os" = "linux" ] && { [ -f /etc/alpine-release ] || { have_cmd ldd && ldd --version 2>&1 | grep -qi musl; }; }; then
    target="$target-musl"
  fi
  printf '%s' "$target"
}

oc_read_version_file() {
  local f="$1"
  [ -f "$f" ] || return 1
  tr -d '[:space:]' <"$f"
}

oc_write_version_file() {
  local f="$1" v="$2"
  printf '%s\n' "$v" | atomic_write "$f"
}
