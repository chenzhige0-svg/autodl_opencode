#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2086  # package lists are intentionally word-split
# lib/repair.sh - bounded, safe automatic repairs.
#
# Every repair is explicitly scoped. When a repair cannot be proven safe it is
# skipped and a manual instruction is reported instead of guessing.

OC_REPAIR_DONE=()
OC_REPAIR_SKIPPED=()
OC_REPAIR_FAILED=()

_repair_record() { # <result> <id> <message>
  case "$1" in
    fixed)   OC_REPAIR_DONE+=("$2: $3") ;;
    skipped) OC_REPAIR_SKIPPED+=("$2: $3") ;;
    failed)  OC_REPAIR_FAILED+=("$2: $3") ;;
  esac
  oc_event "repair" "result=$1" "id=$2" "message=$3"
}

pkg_manager() {
  if have_cmd apt-get; then printf 'apt'; return 0; fi
  if have_cmd dnf; then printf 'dnf'; return 0; fi
  if have_cmd yum; then printf 'yum'; return 0; fi
  if have_cmd pacman; then printf 'pacman'; return 0; fi
  if have_cmd apk; then printf 'apk'; return 0; fi
  if have_cmd zypper; then printf 'zypper'; return 0; fi
  return 1
}

# Wait (bounded) for an apt/dpkg lock holder instead of deleting lock files.
pkg_wait_lock() {
  local max="${1:-120}" waited=0 holders
  while [ "$waited" -lt "$max" ]; do
    holders=""
    if have_cmd fuser; then
      holders="$(fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null || true)"
    fi
    if [ -z "$holders" ] && have_cmd pgrep; then
      holders="$(pgrep -x 'apt-get|apt|dpkg' 2>/dev/null || true)"
    fi
    if [ -z "$holders" ]; then return 0; fi
    if [ "$waited" = "0" ]; then
      log_info "waiting for package manager lock (held by: $holders)"
    fi
    sleep 5; waited=$((waited + 5))
  done
  log_warn "package manager still locked after ${max}s; not deleting lock files"
  return 1
}

pkg_install() {
  local pkgs="$*" mgr
  mgr="$(pkg_manager)" || { log_error "no supported package manager found"; return 1; }
  if ! is_root; then log_error "installing packages requires root"; return 1; fi
  case "$mgr" in
    apt)
      pkg_wait_lock 120 || return 1
      run apt-get update -y || true
      run apt-get install -y --no-install-recommends $pkgs
      ;;
    dnf)    run dnf install -y $pkgs ;;
    yum)    run yum install -y $pkgs ;;
    pacman) run pacman -S --noconfirm --needed $pkgs ;;
    apk)    run apk add --no-cache $pkgs ;;
    zypper) run zypper --non-interactive install $pkgs ;;
  esac
}

# Map a tool name to the package that provides it.
pkg_name_for_tool() {
  local mgr="$1" tool="$2"
  case "$tool" in
    ca-certificates) printf 'ca-certificates' ;;
    curl|wget|git|tar|unzip|nodejs) printf '%s' "$tool" ;;
    node) printf 'nodejs' ;;
    *) printf '%s' "$tool" ;;
  esac
}

repair_dependencies() {
  local method="$OC_INSTALL_METHOD"
  local missing; missing="$(install_prereqs_for_method "$method")"
  [ -n "$missing" ] || { _repair_record fixed DEP001 "all required tools present"; return 0; }
  if ! is_root; then
    _repair_record skipped DEP001 "missing tools:$missing (need root)"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "install missing tools:$missing"
    _repair_record fixed DEP001 "would install:$missing"
    return 0
  fi
  if ! confirm "Install missing tools ($missing) with the system package manager?"; then
    _repair_record skipped DEP001 "dependency install declined by user"
    return 0
  fi
  local mgr pkgs=""
  mgr="$(pkg_manager || true)"
  local t
  for t in $missing; do
    pkgs="$pkgs $(pkg_name_for_tool "$mgr" "$t")"
  done
  if pkg_install $pkgs; then
    _repair_record fixed DEP001 "installed:$missing"
  else
    _repair_record failed DEP001 "failed to install:$missing"
    return 1
  fi
}

repair_path() {
  local cur shellint shellni
  cur="$(path_current_resolution)"
  shellint="$(path_shell_resolution interactive)"
  shellni="$(path_shell_resolution noninteractive)"
  if [ -n "$cur" ] && [ -n "$shellint" ] && [ -n "$shellni" ]; then
    _repair_record fixed PATH001 "PATH already correct in all shells"
    return 0
  fi
  log_step "Repairing PATH"
  path_configure_user_rc || true
  if is_root; then
    path_configure_system_shim || true
  fi
  if [ -n "$DRY_RUN" ] || [ "$DRY_RUN" = "1" ]; then
    _repair_record fixed PATH001 "PATH configuration updated"
    return 0
  fi
  # Re-verify.
  local ni; ni="$(path_shell_resolution noninteractive)"
  if [ -n "$ni" ]; then
    _repair_record fixed PATH001 "PATH fixed; non-interactive shell resolves $ni"
  else
    _repair_record failed PATH001 "PATH still not resolvable in a fresh non-interactive shell"
  fi
}

repair_auth_perms() {
  local auth="$OC_DATA_HOME/auth.json"
  [ -f "$auth" ] || return 0
  local perms; perms="$(stat -c '%a' "$auth" 2>/dev/null || printf '')"
  case "$perms" in
    600|400) return 0 ;;
    "")
      # Some filesystems (e.g. network storage) cannot report/apply unix modes.
      _repair_record skipped CFG005 "cannot inspect permissions on $auth (non-unix fs?)"
      return 0
      ;;
  esac
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "chmod 600 $auth"
  else
    chmod 600 "$auth" 2>/dev/null || { _repair_record skipped CFG005 "chmod failed on $auth"; return 0; }
  fi
  _repair_record fixed CFG005 "restricted credentials file to 600"
}

repair_config_file() {
  local cfg
  if ! cfg="$(config_locate)"; then
    _repair_record fixed CFG001 "no config file to repair"
    return 0
  fi
  if config_validate_file "$cfg" >/dev/null 2>&1; then
    _repair_record fixed CFG002 "config already valid"
    return 0
  fi
  log_step "Repairing invalid config: $cfg"
  backup_path "$cfg" "config-invalid" >/dev/null || true

  if ! config_python >/dev/null; then
    _repair_record skipped CFG002 "python3 unavailable; cannot safely rewrite the config"
    return 0
  fi

  local tmp; oc_tmp_init >/dev/null; tmp="$OC_TMPDIR/repaired.json"
  if config_py normalize "$cfg" "$tmp" >/dev/null 2>&1 && config_py validate "$tmp" >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      log_dry "rewrite $cfg (comments/trailing commas normalized)"
    else
      if cp -f "$tmp" "$cfg"; then
        _repair_record fixed CFG002 "normalized config in place (backup kept)"
      else
        _repair_record failed CFG002 "failed to write repaired config"
      fi
    fi
    return 0
  fi

  # Could not normalize: quarantine and fall back to the newest good backup.
  local aside="$cfg.oc-invalid-$OC_TS"
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "move aside $cfg -> $aside"
  else
    mv "$cfg" "$aside" 2>/dev/null || true
    log_warn "invalid config moved to $aside"
  fi
  if config_generate >/dev/null 2>&1; then
    _repair_record fixed CFG002 "invalid config quarantined at $aside; regenerated a minimal config"
  else
    _repair_record failed CFG002 "invalid config quarantined at $aside; could not regenerate"
  fi
}

repair_cache() {
  local cleared=0
  if [ -d "$OC_CACHE_HOME" ]; then
    local aside="$OC_CACHE_HOME.oc-cache-$OC_TS"
    if [ "$DRY_RUN" = "1" ]; then
      log_dry "move cache aside: $OC_CACHE_HOME -> $aside"
    else
      mv "$OC_CACHE_HOME" "$aside" 2>/dev/null || true
    fi
    cleared=1
  fi
  if [ "$cleared" = "1" ]; then
    _repair_record fixed CFG006 "cache moved aside (safe to regenerate)"
  else
    _repair_record fixed CFG006 "no cache to clear"
  fi
}

repair_binary() {
  local status; status="$(install_status)"
  case "$status" in
    ok)
      _repair_record fixed OC001 "binary already healthy"
      ;;
    missing)
      log_step "Installing missing binary"
      if install_opencode ""; then
        _repair_record fixed OC001 "installed opencode"
      else
        _repair_record failed OC001 "install failed"
        return 1
      fi
      ;;
    broken)
      log_step "Binary is broken; attempting local repair before reinstall"
      repair_cache
      if opencode_version_at "$OC_BIN" >/dev/null 2>&1; then
        _repair_record fixed OC001 "binary recovered after cache clear"
        return 0
      fi
      if have_cmd ldd && [ -x "$OC_BIN" ]; then
        local missing_libs
        missing_libs="$(ldd "$OC_BIN" 2>/dev/null | grep -i 'not found' || true)"
        if [ -n "$missing_libs" ]; then
          _repair_record skipped OC001 "missing shared libraries: $missing_libs -- manual install required on this distro"
          return 0
        fi
      fi
      backup_path "$OC_BIN" "binary-broken" >/dev/null || true
      if install_opencode ""; then
        _repair_record fixed OC001 "reinstalled a validated binary"
      else
        _repair_record failed OC001 "reinstall failed"
        return 1
      fi
      ;;
  esac
}

repair_persistence() {
  if [ "$OC_PERSIST_MODE" = "none" ]; then
    _repair_record skipped PERSIST001 "persistence disabled"
    return 0
  fi
  if ! persist_select_store; then
    _repair_record skipped PERSIST001 "no mounted persist store; refusing to create a fake one"
    return 0
  fi
  config_persistence_apply || { _repair_record failed PERSIST002 "could not link dirs into store"; return 1; }
  _repair_record fixed PERSIST002 "config/data linked into $OC_PERSIST_STORE"
}

repair_run() {
  OC_REPAIR_DONE=(); OC_REPAIR_SKIPPED=(); OC_REPAIR_FAILED=()
  log_step "Automatic repair"
  repair_dependencies || true
  repair_path || true
  repair_binary || true
  repair_config_file || true
  repair_auth_perms || true
  repair_persistence || true

  log_step "Repair summary"
  local x
  for x in "${OC_REPAIR_DONE[@]}";    do log_ok   "$x"; done
  for x in "${OC_REPAIR_SKIPPED[@]}"; do log_warn "$x"; done
  for x in "${OC_REPAIR_FAILED[@]}";  do log_error "$x"; done

  if [ "${#OC_REPAIR_FAILED[@]}" -gt 0 ]; then return "$OC_EXIT_ERROR"; fi
  if [ "${#OC_REPAIR_SKIPPED[@]}" -gt 0 ]; then return "$OC_EXIT_UNSAFE"; fi
  return 0
}
