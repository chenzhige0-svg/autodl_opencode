#!/usr/bin/env bash
# shellcheck shell=bash
# lib/doctor.sh - diagnostics. Read-only: never mutates the system.

OC_FINDINGS=()
OC_DOCTOR_ERRORS=0
OC_DOCTOR_WARNINGS=0

# add_finding <level> <id> <message> <autofix:yes|no> <hint>
add_finding() {
  local level="$1" id="$2" msg="$3" fix="${4:-no}" hint="${5:-}"
  OC_FINDINGS+=("$level|$id|$msg|$fix|$hint")
  case "$level" in
    error) OC_DOCTOR_ERRORS=$((OC_DOCTOR_ERRORS + 1)) ;;
    warn)  OC_DOCTOR_WARNINGS=$((OC_DOCTOR_WARNINGS + 1)) ;;
  esac
  oc_event "finding" "level=$level" "id=$id" "message=$msg" "autofix=$fix"
}

_doctor_reset() { OC_FINDINGS=(); OC_DOCTOR_ERRORS=0; OC_DOCTOR_WARNINGS=0; }

doctor_report_findings() {
  local line level id msg fix hint
  for line in "${OC_FINDINGS[@]}"; do
    IFS='|' read -r level id msg fix hint <<EOF
$line
EOF
    case "$level" in
      ok)    log_ok   "$id $msg" ;;
      info)  log_info "$id $msg" ;;
      warn)  log_warn "$id $msg${hint:+ -- $hint}" ;;
      error) log_error "$id $msg${hint:+ -- $hint}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
doctor_checks_env() {
  add_finding info ENV001 "$(detect_os_pretty) | kernel $(detect_kernel) | $(detect_arch_raw)" no ""
  local who; who="$(detect_user)"
  if is_root; then
    add_finding info ENV002 "running as $who (uid $(detect_uid)); HOME=$HOME" no ""
  else
    add_finding warn ENV002 "running as $who (uid $(detect_uid)); system-level fixes unavailable" no "some repairs require root"
  fi

  local method="$OC_INSTALL_METHOD"
  local missing; missing="$(install_prereqs_for_method "$method")"
  if [ -n "$missing" ]; then
    add_finding error ENV003 "missing tools for '$method' install:$missing" yes "'./setup.sh repair' can install them"
  else
    add_finding ok ENV003 "required tools present for '$method' install" no ""
  fi

  local avail; avail="$(oc_disk_avail_kb "$HOME")"
  if [ -n "$avail" ]; then
    local mb=$((avail / 1024))
    if [ "$avail" -lt 204800 ]; then
      add_finding error ENV004 "low disk space at \$HOME: ${mb}MB free" no "free space before installing"
    elif [ "$avail" -lt 1048576 ]; then
      add_finding warn ENV004 "disk space at \$HOME: ${mb}MB free" no ""
    else
      add_finding ok ENV004 "disk space at \$HOME: $((mb / 1024))GB free" no ""
    fi
  fi

  if [ -e "$OC_AUTODL_TMP" ]; then
    if path_is_mounted "$OC_AUTODL_TMP"; then
      add_finding ok ENV005 "data disk mounted: $OC_AUTODL_TMP ($(mount_source "$OC_AUTODL_TMP"))" no ""
    else
      add_finding warn ENV005 "$OC_AUTODL_TMP exists but is NOT a real mount point" no "check the instance data disk in the AutoDL console"
    fi
  fi
  if [ -e "$OC_AUTODL_FS" ]; then
    if path_is_mounted "$OC_AUTODL_FS"; then
      add_finding ok ENV006 "file storage mounted: $OC_AUTODL_FS ($(mount_source "$OC_AUTODL_FS"))" no ""
    else
      add_finding warn ENV006 "$OC_AUTODL_FS exists but is NOT a real mount point" no "initialize file storage for this region and reboot"
    fi
  fi
}

doctor_checks_network() {
  if ! have_cmd curl; then
    add_finding error NET000 "curl is not available; network checks skipped" yes ""
    return 0
  fi
  local reason
  if ! reason="$(net_proxy_sanity)"; then
    add_finding warn NET001 "proxy configuration problem: $reason" no "fix proxy env vars; ensure NO_PROXY has localhost,127.0.0.1"
  else
    add_finding ok NET001 "proxy environment looks sane" no ""
  fi

  if http_probe "https://api.github.com" 12; then
    add_finding ok NET002 "GitHub API reachable (HTTP ${OC_HTTP_STATUS})" no ""
  else
    add_finding warn NET002 "GitHub API unreachable: $(net_endpoint_category_human "$OC_HTTP_CATEGORY")" no "try 'source /etc/network_turbo' on AutoDL, then re-run"
  fi

  if http_probe "https://opencode.ai/install" 12; then
    add_finding ok NET003 "opencode.ai reachable (HTTP ${OC_HTTP_STATUS})" no ""
  else
    add_finding warn NET003 "opencode.ai unreachable: $(net_endpoint_category_human "$OC_HTTP_CATEGORY")" no "check DNS/proxy"
  fi
}

doctor_checks_path() {
  local cur shellint shellni
  cur="$(path_current_resolution)"
  shellint="$(path_shell_resolution interactive)"
  shellni="$(path_shell_resolution noninteractive)"

  if [ -n "$cur" ]; then
    add_finding ok PATH001 "opencode on current PATH: $cur" no ""
  else
    add_finding warn PATH001 "opencode is NOT on the current process PATH" yes "run './setup.sh repair'"
  fi
  if [ -n "$shellint" ]; then
    add_finding ok PATH002 "new interactive shell resolves: $shellint" no ""
  else
    add_finding warn PATH002 "a new interactive shell cannot find opencode" yes "run './setup.sh repair'"
  fi
  if [ -n "$shellni" ]; then
    add_finding ok PATH003 "non-interactive shell resolves: $shellni" no ""
  else
    add_finding warn PATH003 "non-interactive shell cannot find opencode" yes "run './setup.sh repair' (creates a system shim when root)"
  fi

  local bins n
  bins="$(path_list_conflicts)"
  n="$(printf '%s\n' "$bins" | grep -c . || true)"
  if [ "${n:-0}" -gt 1 ]; then
    add_finding warn PATH004 "multiple opencode binaries found:" no "$(printf '%s' "$bins" | tr '\n' ' ')"
  elif [ "${n:-0}" = "1" ]; then
    add_finding ok PATH004 "single opencode binary: $(printf '%s' "$bins" | head -1)" no ""
  fi
}

doctor_checks_opencode() {
  local status bin ver marker
  status="$(install_status)"
  bin="$(resolve_in_path opencode || true)"; [ -n "$bin" ] || bin="$OC_BIN"

  case "$status" in
    ok)
      ver="$(opencode_version_at "$bin")"
      add_finding ok OC001 "OpenCode installed: v$ver ($bin)" no ""
      marker="$(install_read_marker 2>/dev/null || true)"
      if [ -n "$marker" ] && [ "$marker" != "$ver" ]; then
        add_finding warn OC002 "install marker ($marker) differs from binary ($ver)" no "marker will be refreshed on next install"
      else
        add_finding ok OC002 "install marker in sync" no ""
      fi
      ;;
    broken)
      add_finding error OC001 "opencode binary at $bin exists but fails to run" yes "attempt local repair; reinstall only if needed"
      ;;
    missing)
      add_finding warn OC001 "OpenCode is not installed" yes "run './setup.sh install'"
      ;;
  esac
}

doctor_checks_config() {
  local cfg
  if cfg="$(config_locate)"; then
    add_finding ok CFG001 "config file: $cfg" no ""
    local res
    if res="$(config_validate_file "$cfg")"; then
      add_finding ok CFG002 "config is valid ($res)" no ""
    else
      add_finding error CFG002 "config is invalid: $res" yes "back up and repair the config file"
    fi
    if config_python >/dev/null; then
      local model provider
      model="$(config_py get "$cfg" model 2>/dev/null || true)"
      provider="$(config_py get "$cfg" provider 2>/dev/null || true)"
      if [ -n "$model" ]; then
        add_finding ok CFG003 "default model: $model" no ""
      elif [ -n "$provider" ] && [ "$provider" != "{}" ]; then
        add_finding info CFG003 "providers configured but no default model set" no "set 'model' in opencode.json"
      else
        add_finding warn CFG003 "no model/provider configured" no "run '/connect' in the TUI or set OPENCODE_MODEL"
      fi
    fi
  else
    add_finding warn CFG001 "no opencode config file found" yes "run './setup.sh config' to create one"
  fi

  local auth="$OC_DATA_HOME/auth.json"
  if [ -f "$auth" ]; then
    add_finding ok CFG004 "credentials file present: $auth" no ""
    local perms
    perms="$(stat -c '%a' "$auth" 2>/dev/null || printf '')"
    case "$perms" in
      600|400) add_finding ok CFG005 "credentials file permissions $perms" no "" ;;
      "")      : ;;
      *)       add_finding warn CFG005 "credentials file permissions are $perms (recommend 600)" yes "chmod 600" ;;
    esac
  else
    add_finding info CFG004 "no credentials found (auth not completed)" no "run 'opencode auth login' or /connect; deployment is still successful"
  fi

  if [ -d "$OC_CACHE_HOME" ] && ! is_writable_dir "$OC_CACHE_HOME"; then
    add_finding warn CFG006 "cache dir not writable: $OC_CACHE_HOME" yes "fix ownership/permissions or clear cache"
  else
    add_finding ok CFG006 "cache dir ok" no ""
  fi
}

doctor_checks_persistence() {
  if [ "$OC_PERSIST_MODE" = "none" ]; then
    add_finding info PERSIST001 "persistence disabled (mode=none)" no ""
    return 0
  fi
  if persist_select_store; then
    add_finding ok PERSIST001 "persist store: $OC_PERSIST_STORE [$(persist_tier_of "$OC_PERSIST_STORE")] - $(persist_tier_description "$OC_PERSIST_TIER")" no ""
    local line label state target
    while IFS=$'\t' read -r label state target; do
      case "$state" in
        linked) add_finding ok PERSIST002 "$label dir linked -> $target" no "" ;;
        local-dir) add_finding warn PERSIST002 "$label is a local directory (not persisted)" yes "run './setup.sh persist' to move it into the store" ;;
        absent) add_finding info PERSIST002 "$label not created yet" no "" ;;
        wrong-target:*) add_finding warn PERSIST002 "$label links to an unexpected target (${state#wrong-target:})" yes "run './setup.sh repair' to relink" ;;
      esac
    done <<EOF
$(config_persistence_status)
EOF
  else
    if [ -e "$OC_AUTODL_FS" ] && ! path_is_mounted "$OC_AUTODL_FS"; then
      add_finding warn PERSIST001 "$OC_AUTODL_FS not mounted; refusing to persist" no "initialize file storage in the AutoDL console, then reboot"
    elif [ -e "$OC_AUTODL_TMP" ] && ! path_is_mounted "$OC_AUTODL_TMP"; then
      add_finding warn PERSIST001 "$OC_AUTODL_TMP not mounted; refusing to persist" no "check the instance data disk"
    else
      add_finding info PERSIST001 "no AutoDL persist store available (config stays on the system disk)" no "use --persist fs|tmp or OPENCODE_PERSIST_MODE"
    fi
  fi
}

doctor_run() {
  _doctor_reset
  log_step "Environment"
  doctor_checks_env
  log_step "Network"
  doctor_checks_network
  log_step "PATH and discovery"
  doctor_checks_path
  log_step "OpenCode installation"
  doctor_checks_opencode
  log_step "Configuration and credentials"
  doctor_checks_config
  log_step "Persistence"
  doctor_checks_persistence
  doctor_report_findings

  log_step "Summary"
  log_info "errors: $OC_DOCTOR_ERRORS   warnings: $OC_DOCTOR_WARNINGS"
  oc_event "doctor_summary" "errors=$OC_DOCTOR_ERRORS" "warnings=$OC_DOCTOR_WARNINGS"
  [ "$OC_DOCTOR_ERRORS" -eq 0 ]
}
