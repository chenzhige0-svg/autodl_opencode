#!/usr/bin/env bash
# shellcheck shell=bash
# lib/config.sh - configuration persistence, restoration and safe generation.

OC_CONFIG_PY="${OCDEPLOY_ROOT}/scripts/oc_config.py"
OC_CONFIG_TEMPLATE="${OPENCODE_CONFIG_TEMPLATE:-$OCDEPLOY_ROOT/config/opencode.template.jsonc}"

config_python() {
  if have_cmd python3; then printf 'python3'; return 0; fi
  if have_cmd python; then printf 'python'; return 0; fi
  return 1
}

config_py() {
  local py; py="$(config_python)" || return 127
  "$py" "$OC_CONFIG_PY" "$@"
}

# config_locate -> path of the active config file (empty when none)
config_locate() {
  if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "$OPENCODE_CONFIG" ]; then
    printf '%s' "$OPENCODE_CONFIG"; return 0
  fi
  local c
  for c in "$OC_CONFIG_HOME/opencode.json" "$OC_CONFIG_HOME/opencode.jsonc" "$OC_DATA_HOME/opencode.jsonc"; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

config_validate_file() {
  local f="$1"
  if config_python >/dev/null; then
    config_py validate "$f"
  else
    # Fallback: very rough structural check.
    if head -c 1 "$f" 2>/dev/null | grep -q '[{[]'; then printf 'valid'; return 0; fi
    printf 'invalid (python unavailable; only structural check)'; return 1
  fi
}

# ---------------------------------------------------------------------------
# Oversight: persistence of config and data directories via symlinks
# ---------------------------------------------------------------------------
# Map of "live dir|store subdir label"
config_persist_pairs() {
  printf '%s|config\n' "$OC_CONFIG_HOME"
  printf '%s|data\n' "$OC_DATA_HOME"
}

config_persist_target() {
  local label="$1"
  persist_dir "$label"
}

# _persist_link_one <live> <target> <label>
_persist_link_one() {
  local live="$1" target="$2" label="$3"
  ensure_dir "$(dirname "$live")"

  if [ -L "$live" ]; then
    local cur; cur="$(readlink -f "$live" 2>/dev/null || printf '')"
    if [ "$cur" = "$target" ]; then
      log_debug "$label: already linked to persist store"
      return 0
    fi
    # Symlink to somewhere else: merge that data into the store, then relink.
    if [ -n "$cur" ] && [ -d "$cur" ]; then
      log_info "$label: merging existing symlinked data into persist store"
      _persist_merge_copy "$cur" "$target"
    fi
    if [ "$DRY_RUN" = "1" ]; then log_dry "relink $live -> $target"; return 0; fi
    rm -f "$live"
    ln -s "$target" "$live" || { log_error "$label: failed to relink $live"; return 1; }
    return 0
  fi

  if [ -d "$live" ]; then
    if [ -n "$(ls -A "$live" 2>/dev/null)" ]; then
      log_info "$label: found existing data at $live; merging into persist store"
      _persist_merge_copy "$live" "$target"
      backup_path "$live" "persist-merge-$label" >/dev/null || true
      if [ "$DRY_RUN" = "1" ]; then log_dry "move $live aside -> $live.oc-backup"; return 0; fi
      local aside="$live.oc-backup-$OC_TS"
      if ! mv "$live" "$aside"; then
        log_error "$label: could not move $live aside; aborting to avoid data loss"
        return 1
      fi
      log_info "$label: original preserved at $aside"
    else
      if [ "$DRY_RUN" = "1" ]; then log_dry "replace empty dir $live with symlink"; return 0; fi
      rmdir "$live" 2>/dev/null || true
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then log_dry "ln -s $target $live"; return 0; fi
  ln -s "$target" "$live" || { log_error "$label: failed to create symlink $live -> $target"; return 1; }
  log_ok "$label: persisted at $target"
  return 0
}

# Copy live/. into target/ without overwriting existing store files.
_persist_merge_copy() {
  local src="$1" target="$2"
  ensure_dir "$target"
  if [ "$DRY_RUN" = "1" ]; then log_dry "merge $src -> $target (no clobber)"; return 0; fi
  if have_cmd rsync; then
    rsync -a --ignore-existing "$src/" "$target/" 2>/dev/null || cp -rn "$src/." "$target/" 2>/dev/null || true
  else
    cp -rn "$src/." "$target/" 2>/dev/null || cp -rn "$src/"* "$target/" 2>/dev/null || true
  fi
}

config_persistence_apply() {
  local pairs live label target rc=0
  pairs="$(config_persist_pairs)"
  while IFS='|' read -r live label; do
    [ -n "$live" ] || continue
    target="$(config_persist_target "$label")" || { log_warn "no persist store for $label"; rc=1; continue; }
    ensure_dir "$target"
    _persist_link_one "$live" "$target" "$label" || rc=1
  done <<EOF
$pairs
EOF
  return "$rc"
}

config_persistence_status() {
  local pairs live label target cur state
  pairs="$(config_persist_pairs)"
  while IFS='|' read -r live label; do
    [ -n "$live" ] || continue
    target="$(config_persist_target "$label" 2>/dev/null || printf '')"
    if [ -L "$live" ]; then
      cur="$(readlink -f "$live" 2>/dev/null || printf '')"
      if [ "$cur" = "$target" ]; then state="linked"; else state="wrong-target:$cur"; fi
    elif [ -d "$live" ]; then
      state="local-dir"
    else
      state="absent"
    fi
    printf '%s\t%s\t%s\n' "$label" "$state" "${target:-none}"
  done <<EOF
$pairs
EOF
}

config_persistence_remove() {
  local pairs live label cur
  pairs="$(config_persist_pairs)"
  while IFS='|' read -r live label; do
    [ -L "$live" ] || continue
    cur="$(readlink -f "$live" 2>/dev/null || printf '')"
    local target; target="$(config_persist_target "$label" 2>/dev/null || printf '')"
    if [ -n "$target" ] && [ "$cur" = "$target" ]; then
      if [ "$DRY_RUN" = "1" ]; then log_dry "restore $live from $target"; continue; fi
      local restore="$live.oc-restore-$OC_TS"
      if cp -a "$target" "$restore" 2>/dev/null; then
        rm -f "$live"
        mv "$restore" "$live"
        log_ok "$label: restored to local directory $live (store copy kept)"
      else
        log_error "$label: failed to copy back from store; leaving symlink in place"
      fi
    fi
  done <<EOF
$pairs
EOF
}

# ---------------------------------------------------------------------------
# Config generation / overrides
# ---------------------------------------------------------------------------
# Build a JSON object with the overrides explicitly requested via environment.
config_build_overrides_json() {
  local out="$1"
  {
    printf '{\n'
    local first=1
    _emit() {
      local key="$1" val="$2" type="$3"
      [ -n "$val" ] || return 0
      if [ "$first" = "1" ]; then first=0; else printf ',\n'; fi
      if [ "$type" = "raw" ]; then
        printf '  "%s": %s' "$key" "$val"
      else
        printf '  "%s": "%s"' "$key" "$val"
      fi
    }
    _emit "model" "${OPENCODE_MODEL:-}" str
    _emit "small_model" "${OPENCODE_SMALL_MODEL:-}" str
    if [ -n "${OPENCODE_AUTOUPDATE:-}" ]; then
      case "${OPENCODE_AUTOUPDATE}" in
        false|0|no) _emit "autoupdate" "false" raw ;;
        true|1|yes) _emit "autoupdate" "true" raw ;;
        notify) _emit "autoupdate" '"notify"' raw ;;
      esac
    fi
    # Provider block
    if [ -n "${OPENCODE_PROVIDER:-}" ]; then
      [ "$first" = "1" ] && first=0 || printf ',\n'
      printf '  "provider": {\n    "%s": { "options": {' "$OPENCODE_PROVIDER"
      local pfirst=1
      if [ -n "${OPENCODE_BASE_URL:-}" ]; then
        printf ' "baseURL": "%s"' "$OPENCODE_BASE_URL"; pfirst=0
      fi
      if [ -n "${OPENCODE_API_KEY_ENV:-}" ]; then
        [ "$pfirst" = "1" ] || printf ','
        printf ' "apiKey": "{env:%s}"' "$OPENCODE_API_KEY_ENV"
      fi
      printf ' } }\n  }'
    fi
    printf '\n}\n'
  } >"$out"
  # Validate the JSON we just produced.
  if config_python >/dev/null; then
    config_py validate "$out" >/dev/null 2>&1 || { log_warn "generated overrides are not valid JSON"; return 1; }
  fi
  return 0
}

config_generate() {
  local existing; existing="$(config_locate || true)"
  oc_tmp_init >/dev/null
  local overrides="$OC_TMPDIR/overrides.json"
  config_build_overrides_json "$overrides" || overrides=""
  local has_overrides=0
  [ -s "$overrides" ] && grep -q ':' "$overrides" && has_overrides=1

  if [ -z "$existing" ]; then
    log_step "Creating initial OpenCode config"
    ensure_dir "$OC_CONFIG_HOME"
    local dest="$OC_CONFIG_HOME/opencode.json"
    if [ "$DRY_RUN" = "1" ]; then log_dry "write $dest"; return 0; fi
    if config_python >/dev/null && [ -f "$OC_CONFIG_TEMPLATE" ]; then
      if [ "$has_overrides" = "1" ]; then
        config_py merge "$OC_CONFIG_TEMPLATE" "$overrides" "$dest" || return 1
      else
        config_py normalize "$OC_CONFIG_TEMPLATE" "$dest" || return 1
      fi
    else
      config_generate_minimal "$dest"
    fi
    log_ok "created $dest"
    return 0
  fi

  log_info "existing config: $existing"
  if [ "$has_overrides" != "1" ]; then
    log_info "no explicit overrides requested; leaving existing config untouched"
    return 0
  fi

  # Merge: existing wins, then the requested overrides are applied on top.
  local tmpout="$OC_TMPDIR/merged.json"
  if config_python >/dev/null; then
    config_py merge "$existing" "$overrides" "$tmpout" || { log_error "config merge failed"; return 1; }
  else
    log_warn "python3 unavailable; cannot safely merge overrides into existing config"
    return 1
  fi

  if diff -q "$existing" "$tmpout" >/dev/null 2>&1; then
    log_info "overrides already present; config unchanged"
    return 0
  fi
  log_info "planned config changes:"
  diff -u "$existing" "$tmpout" 2>/dev/null | sed 's/^/    /' >&2 || true
  if ! confirm "Apply these config changes to $existing?"; then
    log_warn "config changes skipped by user"
    return 0
  fi
  backup_path "$existing" "config-before-merge" >/dev/null || true
  if [ "$DRY_RUN" = "1" ]; then log_dry "apply merged config to $existing"; return 0; fi
  cp -f "$tmpout" "$existing" || { log_error "failed to apply merged config"; return 1; }
  log_ok "config updated: $existing"
  return 0
}

config_generate_minimal() {
  local dest="$1"
  {
    printf '{\n'
    # shellcheck disable=SC2016  # literal JSON schema URL, no expansion wanted
    printf '  "$schema": "https://opencode.ai/config.json"'
    [ -n "${OPENCODE_MODEL:-}" ] && printf ',\n  "model": "%s"' "$OPENCODE_MODEL"
    [ -n "${OPENCODE_SMALL_MODEL:-}" ] && printf ',\n  "small_model": "%s"' "$OPENCODE_SMALL_MODEL"
    if [ -n "${OPENCODE_PROVIDER:-}" ]; then
      printf ',\n  "provider": {\n    "%s": {\n      "options": {\n' "$OPENCODE_PROVIDER"
      local pf=1
      if [ -n "${OPENCODE_BASE_URL:-}" ]; then printf '        "baseURL": "%s"' "$OPENCODE_BASE_URL"; pf=0; fi
      if [ -n "${OPENCODE_API_KEY_ENV:-}" ]; then
        [ "$pf" = "1" ] || printf ',\n'
        printf '        "apiKey": "{env:%s}"' "$OPENCODE_API_KEY_ENV"
      fi
      printf '\n      }\n    }\n  }'
    fi
    printf '\n}\n'
  } | atomic_write "$dest"
}
