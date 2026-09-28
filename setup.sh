#!/usr/bin/env bash
# shellcheck shell=bash
# setup.sh - unified entrypoint for the AutoDL OpenCode deployment toolkit.
#
# Commands: install | doctor | repair | verify | backup | restore | update |
#           persist | unpersist | config | status | help
#
set -o pipefail

_oc_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCDEPLOY_ROOT="$_oc_here"
export OCDEPLOY_ROOT

# shellcheck source=lib/common.sh
. "$OCDEPLOY_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$OCDEPLOY_ROOT/lib/detect.sh"
# shellcheck source=lib/mount.sh
. "$OCDEPLOY_ROOT/lib/mount.sh"
# shellcheck source=lib/net.sh
. "$OCDEPLOY_ROOT/lib/net.sh"
# shellcheck source=lib/install.sh
. "$OCDEPLOY_ROOT/lib/install.sh"
# shellcheck source=lib/path.sh
. "$OCDEPLOY_ROOT/lib/path.sh"
# shellcheck source=lib/config.sh
. "$OCDEPLOY_ROOT/lib/config.sh"
# shellcheck source=lib/doctor.sh
. "$OCDEPLOY_ROOT/lib/doctor.sh"
# shellcheck source=lib/repair.sh
. "$OCDEPLOY_ROOT/lib/repair.sh"
# shellcheck source=lib/verify.sh
. "$OCDEPLOY_ROOT/lib/verify.sh"
# shellcheck source=lib/backup.sh
. "$OCDEPLOY_ROOT/lib/backup.sh"

usage() {
  cat <<EOF
opencode-autodl $OC_VERSION - deploy and recover OpenCode on AutoDL instances

USAGE:
  ./setup.sh [global options] [command] [command options]

COMMANDS (no command runs a safe 'deploy' flow):
  deploy              detect, install if missing, configure, verify  (default)
  install             install OpenCode if not already present
  doctor              diagnose the environment (read-only)
  repair              apply safe automatic fixes
  verify              verify the deployment
  backup              back up configuration (optionally credentials)
  restore <dir>       restore configuration from a backup
  update [version]    explicitly upgrade OpenCode
  persist             move config/data into the persistent store
  unpersist           move config/data back to local directories
  config              create/merge config from environment variables
  status              one-line status summary
  help                show this help

GLOBAL OPTIONS:
  -n, --dry-run       show what would happen; change nothing
  -y, --yes           assume yes for confirmations
  -v, --verbose       verbose output
      --json          also emit structured JSON events on stderr
      --no-color      disable coloured output
  -h, --help          show this help
      --version       print the toolkit version

INSTALL / PERSIST OPTIONS:
      --method M      install method: curl|npm|bun|pnpm|auto (default curl)
      --opencode-version V   install/upgrade to a specific version
      --force         reinstall even if a healthy install exists
      --persist M     persistence mode: auto|fs|tmp|path|none (default auto)
      --persist-dir D explicit persistence directory (with --persist path)
  -c, --config FILE   use an explicit config template file

CONFIG OVERRIDES (env vars, applied only when set):
  OPENCODE_MODEL, OPENCODE_SMALL_MODEL, OPENCODE_PROVIDER,
  OPENCODE_BASE_URL, OPENCODE_API_KEY_ENV, OPENCODE_AUTOUPDATE

EXIT CODES:
  0 ok | 1 error | 2 usage | 3 environment/network | 4 needs authentication
  5 verification failed | 6 manual action required | 7 locked
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CMD=""
CMD_ARGS=()
RESTORE_DIR=""
INSTALL_VERSION=""
BACKUP_WITH_CREDENTIALS=0
BACKUP_ARCHIVE=0
FORCE_INSTALL=0

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -v|--verbose) VERBOSE=1 ;;
      --json) JSON_OUTPUT=1 ;;
      --no-color) NO_COLOR=1 ;;
      -h|--help) usage; exit "$OC_EXIT_OK" ;;
      --version) printf 'opencode-autodl %s\n' "$OC_VERSION"; exit "$OC_EXIT_OK" ;;
      --method) shift; OC_INSTALL_METHOD="${1:-}"; [ -n "$OC_INSTALL_METHOD" ] || die "--method requires a value" "$OC_EXIT_USAGE" ;;
      --opencode-version) shift; INSTALL_VERSION="${1:-}"; [ -n "$INSTALL_VERSION" ] || die "--opencode-version requires a value" "$OC_EXIT_USAGE" ;;
      --force) FORCE_INSTALL=1 ;;
      --persist) shift; OC_PERSIST_MODE="${1:-}"; [ -n "$OC_PERSIST_MODE" ] || die "--persist requires a value" "$OC_EXIT_USAGE" ;;
      --persist-dir) shift; OC_PERSIST_DIR="${1:-}"; [ -n "$OC_PERSIST_DIR" ] || die "--persist-dir requires a value" "$OC_EXIT_USAGE" ;;
      -c|--config) shift; OC_CONFIG_TEMPLATE="${1:-}"; [ -n "$OC_CONFIG_TEMPLATE" ] || die "--config requires a value" "$OC_EXIT_USAGE" ;;
      --with-credentials) BACKUP_WITH_CREDENTIALS=1 ;;
      --archive) BACKUP_ARCHIVE=1 ;;
      -*) die "unknown option: $1 (see --help)" "$OC_EXIT_USAGE" ;;
      *)
        if [ -z "$CMD" ]; then CMD="$1"; else CMD_ARGS+=("$1"); fi
        ;;
    esac
    shift
  done
  # positional args after command
  case "$CMD" in
    restore) RESTORE_DIR="${CMD_ARGS[0]:-}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Environment summary (also used by deploy)
# ---------------------------------------------------------------------------
print_env_summary() {
  log_step "Environment"
  log_info "os:       $(detect_os_pretty) ($(detect_arch_raw), kernel $(detect_kernel))"
  log_info "user:     $(detect_user) (uid $(detect_uid))  home: $HOME"
  log_info "shell:    $(detect_login_shell)"
  log_info "opencode: $(install_status) $([ -n "$(resolve_in_path opencode || true)" ] && printf 'at %s' "$(resolve_in_path opencode)" || printf 'not on PATH')"
  if [ "$(detect_autodl)" = "yes" ]; then
    log_info "autodl:   detected"
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_install() {
  local status; status="$(install_status)"
  print_env_summary
  case "$status" in
    ok)
      if [ "$FORCE_INSTALL" = "1" ]; then
        log_step "Healthy install present; --force given, reinstalling"
        install_opencode "$INSTALL_VERSION"
      else
        local ver; ver="$(opencode_version_at "$(resolve_in_path opencode)")"
        log_ok "OpenCode already installed (v$ver); skipping install"
        return 0
      fi
      ;;
    broken)
      log_warn "existing install appears broken; running repair instead of a blind reinstall"
      repair_binary || true
      ;;
    missing)
      install_opencode "$INSTALL_VERSION" || return $?
      ;;
  esac
  # Make sure it is reachable, but do not clobber unrelated shells on install.
  if [ -z "$(path_current_resolution)" ] || [ -z "$(path_shell_resolution noninteractive)" ]; then
    path_configure_user_rc || true
    if is_root; then path_configure_system_shim || true; fi
  fi
  [ "$DRY_RUN" = "1" ] || verify_binary || true
  return 0
}

cmd_update() {
  local version="${CMD_ARGS[0]:-$INSTALL_VERSION}"
  [ -n "$version" ] || version="latest"
  upgrade_opencode "$version"
}

cmd_doctor() {
  print_env_summary
  doctor_run
}

cmd_repair() {
  print_env_summary
  repair_run
}

cmd_verify() {
  verify_run
}

cmd_backup() {
  backup_run "$BACKUP_WITH_CREDENTIALS" "$BACKUP_ARCHIVE"
}

cmd_restore() {
  restore_run "$RESTORE_DIR" "$BACKUP_WITH_CREDENTIALS"
}

cmd_config() {
  log_step "Configuration"
  config_generate
}

cmd_persist() {
  log_step "Persistence"
  if ! persist_select_store; then
    log_error "no usable persistence store (mode=$OC_PERSIST_MODE)"
    log_info "  - fs:   $OC_AUTODL_FS (network file storage, cross-instance)"
    log_info "  - tmp:  $OC_AUTODL_TMP (instance data disk)"
    log_info "the directory must be an actual mount and writable"
    return "$OC_EXIT_UNSAFE"
  fi
  log_info "store: $OC_PERSIST_STORE [$(persist_tier_of "$OC_PERSIST_STORE")]"
  log_info "durability: $(persist_tier_description "$OC_PERSIST_TIER")"
  config_persistence_apply
}

cmd_unpersist() {
  log_step "Reverting persistence"
  config_persistence_remove
}

cmd_status() {
  local status ver tier
  status="$(install_status)"
  ver="$(opencode_version_at "$(resolve_in_path opencode || printf '%s' "$OC_BIN")" 2>/dev/null || printf 'n/a')"
  printf 'opencode: %s (%s)\n' "$status" "$ver"
  printf 'config:   %s\n' "$(config_locate 2>/dev/null || printf 'none')"
  printf 'auth:     %s\n' "$([ -f "$OC_DATA_HOME/auth.json" ] && printf present || printf 'not configured')"
  if persist_select_store; then
    tier="$(persist_tier_of "$OC_PERSIST_STORE")"
    printf 'persist:  %s (%s)\n' "$OC_PERSIST_STORE" "$tier"
  else
    printf 'persist:  none\n'
  fi
  printf 'path:     %s\n' "$(path_current_resolution || printf 'not on PATH')"
}

# ---------------------------------------------------------------------------
# Default deploy flow
# ---------------------------------------------------------------------------
cmd_deploy() {
  log_step "opencode-autodl deploy ($OC_VERSION)"
  print_env_summary

  # 1. dependencies
  local missing; missing="$(install_prereqs_for_method "$OC_INSTALL_METHOD")"
  if [ -n "$missing" ]; then
    log_warn "missing required tools for '$OC_INSTALL_METHOD' install:$missing"
    if [ "$ASSUME_YES" = "1" ] || confirm "Install missing tools now?"; then
      repair_dependencies || true
    fi
  fi

  # 2. install if needed
  local status; status="$(install_status)"
  if [ "$status" = "missing" ]; then
    install_opencode "$INSTALL_VERSION" || log_error "install did not complete"
  elif [ "$status" = "broken" ]; then
    log_warn "existing install is broken; attempting local repair"
    repair_binary || true
  else
    log_ok "OpenCode already installed; leaving it in place (use 'update' to upgrade)"
  fi

  # 3. config
  config_generate || log_warn "config generation skipped"

  # 4. persistence
  if [ "$OC_PERSIST_MODE" != "none" ]; then
    if persist_select_store; then
      local enable=0
      if [ "$ASSUME_YES" = "1" ]; then
        enable=1
      elif [ "$OC_PERSIST_MODE" = "fs" ] || [ "$OC_PERSIST_MODE" = "tmp" ] || [ "$OC_PERSIST_MODE" = "path" ]; then
        enable=1
      elif confirm "Persist OpenCode config/data to $OC_PERSIST_STORE [$(persist_tier_of "$OC_PERSIST_STORE")]?"; then
        enable=1
      fi
      if [ "$enable" = "1" ]; then
        config_persistence_apply || log_warn "persistence setup encountered a problem"
      else
        log_info "persistence skipped by user"
      fi
    else
      log_warn "no mounted persistence store found; config remains on the system disk"
      log_info "on AutoDL: data disk=$OC_AUTODL_TMP, file storage=$OC_AUTODL_FS (must be initialized in the console)"
    fi
  fi

  # 5. PATH
  if [ -z "$(path_current_resolution)" ] || [ -z "$(path_shell_resolution noninteractive)" ]; then
    log_step "Fixing PATH so 'opencode' is always found"
    path_configure_user_rc || true
    if is_root; then path_configure_system_shim || true; fi
  fi

  # 6. verify
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "would verify the deployment"
    log_step "Result"
    log_info "dry-run complete; no changes were made"
    return 0
  fi
  verify_run
  local vrc=$?

  log_step "Result"
  case "$vrc" in
    0) log_ok "deployment complete and verified" ;;
    "$OC_EXIT_PARTIAL") log_warn "deployment complete; authentication still required" ;;
    *) log_error "deployment finished with problems; run './setup.sh doctor'" ;;
  esac
  return "$vrc"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  oc_log_init

  local lock_rc=0
  oc_lock_acquire || lock_rc=$?
  if [ "$lock_rc" -ne 0 ]; then
    exit "$lock_rc"
  fi
  trap 'oc_lock_release; _oc_tmp_cleanup' EXIT INT TERM

  local rc=0
  case "${CMD:-deploy}" in
    deploy|"")      cmd_deploy; rc=$? ;;
    install)        cmd_install; rc=$? ;;
    doctor)         cmd_doctor; rc=$? ;;
    repair)         cmd_repair; rc=$? ;;
    verify)         cmd_verify; rc=$? ;;
    backup)         cmd_backup; rc=$? ;;
    restore)        cmd_restore; rc=$? ;;
    update|upgrade) cmd_update; rc=$? ;;
    persist)        cmd_persist; rc=$? ;;
    unpersist)      cmd_unpersist; rc=$? ;;
    config)         cmd_config; rc=$? ;;
    status)         cmd_status; rc=$? ;;
    help)           usage; rc=$? ;;
    *)              log_error "unknown command: $CMD"; usage; rc="$OC_EXIT_USAGE" ;;
  esac
  oc_event "done" "command=${CMD:-deploy}" "exit=$rc" "log=${OC_LOG_FILE:-none}"
  return "$rc"
}

main "$@"
