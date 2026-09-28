#!/usr/bin/env bash
# shellcheck shell=bash
# lib/verify.sh - post-deployment verification with meaningful exit codes.

OC_VERIFY_FAILS=0
OC_VERIFY_NEEDS_AUTH=0

_v_fail() { log_error "$1"; OC_VERIFY_FAILS=$((OC_VERIFY_FAILS + 1)); oc_event "verify_fail" "message=$1"; }
_v_ok()   { log_ok "$1"; }
_v_info() { log_info "$1"; }

verify_binary() {
  local status; status="$(install_status)"
  if [ "$status" != "ok" ]; then
    _v_fail "opencode binary is not runnable (status: $status)"
    return 1
  fi
  local bin ver; bin="$(resolve_in_path opencode || true)"; [ -n "$bin" ] || bin="$OC_BIN"
  ver="$(opencode_version_at "$bin")" || { _v_fail "could not read opencode version"; return 1; }
  _v_ok "binary runs: v$ver ($bin)"
  local marker; marker="$(install_read_marker 2>/dev/null || true)"
  if [ -n "$marker" ] && [ "$marker" != "$ver" ]; then
    log_warn "install marker ($marker) != running version ($ver)"
  fi
  return 0
}

verify_paths() {
  local cur shellint shellni
  cur="$(path_current_resolution)"
  shellint="$(path_shell_resolution interactive)"
  shellni="$(path_shell_resolution noninteractive)"
  [ -n "$cur" ] && _v_ok "resident command: $cur" || _v_fail "opencode not on the current PATH"
  [ -n "$shellint" ] && _v_ok "new interactive shell: $shellint" || _v_fail "new interactive shell cannot find opencode"
  [ -n "$shellni" ] && _v_ok "non-interactive shell: $shellni" || _v_fail "non-interactive shell cannot find opencode"
}

verify_config() {
  local cfg
  if ! cfg="$(config_locate)"; then
    _v_info "no config file present (opencode can still run with defaults)"
    return 0
  fi
  local res
  if res="$(config_validate_file "$cfg")"; then
    _v_ok "config valid: $cfg"
  else
    _v_fail "config invalid: $res"
  fi
}

verify_persistence() {
  [ "$OC_PERSIST_MODE" = "none" ] && return 0
  if persist_select_store; then
    local label state target
    while IFS=$'\t' read -r label state target; do
      case "$state" in
        linked) _v_ok "persist $label -> $target" ;;
        local-dir) log_warn "persist $label is local (not persisted)" ;;
        absent) : ;;
        *) log_warn "persist $label state: $state" ;;
      esac
    done <<EOF
$(config_persistence_status)
EOF
  fi
  return 0
}

verify_auth() {
  local auth="$OC_DATA_HOME/auth.json"
  if [ -f "$auth" ]; then
    _v_ok "credentials present (auth state: configured)"
  else
    OC_VERIFY_NEEDS_AUTH=1
    log_warn "no credentials yet: deployment succeeded, authentication still required"
    _v_info "run 'opencode auth login' or '/connect' inside the TUI"
  fi
}

# Optional, explicitly opt-in live check (may incur provider cost).
verify_live() {
  [ "${OPENCODE_LIVE_TEST:-0}" = "1" ] || return 0
  log_warn "OPENCODE_LIVE_TEST=1: issuing a real model request (provider charges may apply)"
  local bin; bin="$(resolve_in_path opencode || true)"; [ -n "$bin" ] || bin="$OC_BIN"
  local out
  if have_cmd timeout; then
    out="$(timeout 180 "$bin" run "Reply with the single word: pong" 2>&1)" || { _v_fail "live model request failed"; return 1; }
  else
    out="$("$bin" run "Reply with the single word: pong" 2>&1)" || { _v_fail "live model request failed"; return 1; }
  fi
  if printf '%s' "$out" | grep -qi 'pong'; then
    _v_ok "live model request returned a response"
  else
    log_warn "live request completed but response was unexpected"
    log_debug "response: $(oc_redact_string "$out" | head -c 200)"
  fi
  return 0
}

verify_run() {
  OC_VERIFY_FAILS=0; OC_VERIFY_NEEDS_AUTH=0
  log_step "Verification"
  verify_binary || true
  verify_paths || true
  verify_config || true
  verify_persistence || true
  verify_auth || true
  verify_live || true

  if [ "$OC_VERIFY_FAILS" -gt 0 ]; then
    log_error "verification failed with $OC_VERIFY_FAILS problem(s)"
    return "$OC_EXIT_VERIFY"
  fi
  if [ "$OC_VERIFY_NEEDS_AUTH" = "1" ]; then
    log_warn "verification partial: installed and working, authentication pending"
    return "$OC_EXIT_PARTIAL"
  fi
  log_ok "verification passed"
  return 0
}
