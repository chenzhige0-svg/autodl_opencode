#!/usr/bin/env bash
# shellcheck shell=bash
# lib/backup.sh - backup and restore of configuration and (optionally) credentials.
#
# Ordinary config backups and sensitive credential backups are kept in separate
# subdirectories so they can be handled, transferred and permissioned
# differently. Credentials are never included unless explicitly requested.

backup_manifest_path() { printf '%s/manifest.json' "$1"; }

backup_run() {
  local include_creds="${1:-0}" archive="${2:-0}"
  local dest="$OC_BACKUP_ROOT/$OC_TS"
  ensure_dir "$OC_BACKUP_ROOT"
  while [ -e "$dest" ]; do dest="$OC_BACKUP_ROOT/$OC_TS-$RANDOM"; done

  if [ "$DRY_RUN" = "1" ]; then
    log_dry "create backup at $dest (credentials: $include_creds)"
    printf '%s' "$dest"
    return 0
  fi

  ensure_dir "$dest/config"
  local have_config=0
  if [ -d "$OC_CONFIG_HOME" ]; then
    cp -aL "$OC_CONFIG_HOME/." "$dest/config/" 2>/dev/null && have_config=1
  fi
  # A custom config file outside the config dir.
  local cfg
  if cfg="$(config_locate 2>/dev/null)"; then
    case "$cfg" in
      "$OC_CONFIG_HOME"/*) : ;;
      *)
        ensure_dir "$dest/custom-config"
        cp -f "$cfg" "$dest/custom-config/" 2>/dev/null || true
        ;;
    esac
  fi

  local have_creds=0
  if [ "$include_creds" = "1" ] && [ -f "$OC_DATA_HOME/auth.json" ]; then
    ensure_dir "$dest/credentials"
    if cp -f "$OC_DATA_HOME/auth.json" "$dest/credentials/auth.json" 2>/dev/null; then
      chmod 700 "$dest/credentials" 2>/dev/null || true
      chmod 600 "$dest/credentials/auth.json" 2>/dev/null || true
      have_creds=1
      log_warn "credentials included in this backup: $dest/credentials (keep it private)"
    fi
  fi

  {
    printf '{\n'
    printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "host": "%s",\n' "$(hostname 2>/dev/null || printf unknown)"
    printf '  "home": "%s",\n' "$HOME"
    printf '  "config_home": "%s",\n' "$OC_CONFIG_HOME"
    printf '  "has_config": %s,\n' "$([ "$have_config" = 1 ] && printf true || printf false)"
    printf '  "has_credentials": %s,\n' "$([ "$have_creds" = 1 ] && printf true || printf false)"
    printf '  "persist_tier": "%s"\n' "${OC_PERSIST_TIER:-none}"
    printf '}\n'
  } >"$(backup_manifest_path "$dest")"
  chmod 600 "$(backup_manifest_path "$dest")" 2>/dev/null || true

  log_ok "backup created: $dest"

  if [ "$archive" = "1" ]; then
    if have_cmd tar; then
      local tarball="$dest.tar.gz"
      if (cd "$OC_BACKUP_ROOT" && tar czf "$(basename "$tarball")" "$(basename "$dest")"); then
        # The archive may contain config (and, when requested, credentials).
        chmod 600 "$tarball" 2>/dev/null || true
        log_ok "archive: $tarball"
      else
        log_warn "failed to create archive"
      fi
    else
      log_warn "tar unavailable; skipping archive"
    fi
  fi

  printf '%s' "$dest"
}

backup_list() {
  [ -d "$OC_BACKUP_ROOT" ] || { log_info "no backups at $OC_BACKUP_ROOT"; return 0; }
  find "$OC_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

# restore_run <backup_dir> [include_creds]
restore_run() {
  local src="$1" want_creds="${2:-0}"
  [ -n "$src" ] || die "restore requires a backup directory" "$OC_EXIT_USAGE"
  src="${src%/}"
  if [ ! -d "$src" ]; then
    for cand in "$OC_BACKUP_ROOT/$src" "$PWD/$src"; do
      [ -d "$cand" ] && { src="$cand"; break; }
    done
  fi
  [ -d "$src" ] || die "backup directory not found: $src" "$OC_EXIT_USAGE"

  local manifest; manifest="$(backup_manifest_path "$src")"
  if [ ! -f "$manifest" ]; then
    log_warn "no manifest.json in $src; proceeding cautiously"
  fi

  log_step "Restoring from $src"
  if [ -d "$src/config" ]; then
    if [ -d "$OC_CONFIG_HOME" ] && [ -n "$(ls -A "$OC_CONFIG_HOME" 2>/dev/null)" ]; then
      backup_path "$OC_CONFIG_HOME" "config-before-restore" >/dev/null || true
    fi
    ensure_dir "$OC_CONFIG_HOME"
    if [ "$DRY_RUN" = "1" ]; then
      log_dry "restore config into $OC_CONFIG_HOME"
    else
      cp -a "$src/config/." "$OC_CONFIG_HOME/" || { log_error "config restore failed"; return "$OC_EXIT_ERROR"; }
      log_ok "config restored into $OC_CONFIG_HOME"
    fi
  else
    log_warn "backup contains no config/"
  fi

  if [ -f "$src/custom-config/opencode.json" ] || [ -f "$src/custom-config/opencode.jsonc" ]; then
    ensure_dir "$OC_CONFIG_HOME"
    cp -n "$src/custom-config/"* "$OC_CONFIG_HOME/" 2>/dev/null || true
    log_ok "custom config merged into $OC_CONFIG_HOME"
  fi

  if [ -f "$src/credentials/auth.json" ]; then
    if [ "$want_creds" = "1" ]; then
      ensure_dir "$OC_DATA_HOME"
      if [ "$DRY_RUN" = "1" ]; then
        log_dry "restore credentials -> $OC_DATA_HOME/auth.json"
      else
        cp -f "$src/credentials/auth.json" "$OC_DATA_HOME/auth.json"
        chmod 600 "$OC_DATA_HOME/auth.json" 2>/dev/null || true
        log_ok "credentials restored"
      fi
    else
      log_warn "backup contains credentials but --with-credentials was not given; skipped"
    fi
  fi
  return 0
}
