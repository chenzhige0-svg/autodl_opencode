#!/usr/bin/env bash
# shellcheck shell=bash
# lib/path.sh - make the opencode binary discoverable and verify it really is.
#
# Three independent concerns are addressed:
#   1. current process PATH
#   2. new interactive/login shells (rc files, marker-managed, idempotent)
#   3. non-interactive shells / scripts (a stable system shim when root)

path_target_rcfiles() {
  local login_shell; login_shell="$(basename "$(detect_login_shell)")"
  case "$login_shell" in
    bash) printf '%s\n' "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" ;;
    zsh)  printf '%s\n' "$HOME/.zshrc" "${ZDOTDIR:-$HOME}/.zprofile" "$HOME/.profile" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
    ash|sh|dash) printf '%s\n' "$HOME/.profile" ;;
    *)    printf '%s\n' "$HOME/.profile" "$HOME/.bashrc" ;;
  esac
}

path_block_body() {
  local shell_name="$1"
  # shellcheck disable=SC2016  # $PATH must stay literal in the generated rc file
  case "$shell_name" in
    fish) printf 'fish_add_path %s' "$OC_HOME_INSTALL_DIR" ;;
    *)    printf 'export PATH="%s:$PATH"' "$OC_HOME_INSTALL_DIR" ;;
  esac
}

# path_configure_user_rc - write managed block into the login shell's rc files.
path_configure_user_rc() {
  local login_shell; login_shell="$(basename "$(detect_login_shell)")"
  local body; body="$(path_block_body "$login_shell")"
  local f configured=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */fish/config.fish)
        # Only create the fish config if fish is actually the login shell.
        [ "$login_shell" = "fish" ] || continue
        ;;
    esac
    upsert_managed_block "$f" "$body"
    configured=$((configured + 1))
  done <<EOF
$(path_target_rcfiles)
EOF
  # Also cover plain POSIX login for non-bash/zsh shells.
  if [ "$login_shell" != "fish" ] && [ "$login_shell" != "bash" ] && [ "$login_shell" != "zsh" ]; then
    upsert_managed_block "$HOME/.profile" "$(path_block_body sh)" >/dev/null 2>&1 || true
  fi
  log_debug "configured $configured rc file(s)"
  return 0
}

path_system_shim_path() { printf '/usr/local/bin/opencode'; }

# path_configure_system_shim - create /usr/local/bin/opencode -> real binary.
# Makes the CLI available to non-interactive shells without rc changes.
path_configure_system_shim() {
  local shim; shim="$(path_system_shim_path)"
  is_root || { log_debug "not root; skipping system shim"; return 1; }
  [ -d /usr/local/bin ] || { log_debug "/usr/local/bin missing; skipping shim"; return 1; }
  is_writable_dir /usr/local/bin || { log_warn "/usr/local/bin not writable"; return 1; }

  if [ -e "$shim" ] || [ -L "$shim" ]; then
    local cur; cur="$(readlink -f "$shim" 2>/dev/null || printf '')"
    if [ "$cur" = "$(readlink -f "$OC_BIN" 2>/dev/null || printf '%s' "$OC_BIN")" ]; then
      log_debug "system shim already points at $OC_BIN"
      return 0
    fi
    if [ "$cur" != "$OC_BIN" ] && [ -n "$cur" ]; then
      # A different opencode lives here. Don't clobber blindly.
      log_warn "existing $shim -> $cur (not overwriting automatically)"
      return 1
    fi
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "ln -sf $OC_BIN $shim"
    return 0
  fi
  ln -sf "$OC_BIN" "$shim" 2>/dev/null || { log_warn "could not create $shim"; return 1; }
  log_debug "system shim: $shim -> $OC_BIN"
  return 0
}

# --- verification -----------------------------------------------------------
path_current_resolution() { command -v opencode 2>/dev/null || true; }

path_shell_resolution() {
  local mode="$1" # interactive | noninteractive
  local sh; sh="$(detect_login_shell)"; [ -x "$sh" ] || sh="/bin/sh"
  if [ "$mode" = "noninteractive" ]; then
    # shellcheck disable=SC2016
    "$sh" -lc 'command -v opencode' 2>/dev/null | tail -1
  else
    # shellcheck disable=SC2016
    "$sh" -lic 'command -v opencode' 2>/dev/null | tail -1
  fi
}

path_list_conflicts() {
  find_opencode_binaries
}

# path_verify_report - prints machine readable lines and returns count of problems
path_verify_report() {
  local problems=0
  local cur shellint shellni shim
  cur="$(path_current_resolution)"
  shellint="$(path_shell_resolution interactive)"
  shellni="$(path_shell_resolution noninteractive)"
  shim="$(path_system_shim_path)"; [ -e "$shim" ] || shim=""

  printf 'current\t%s\n' "${cur:-missing}"
  printf 'interactive_shell\t%s\n' "${shellint:-missing}"
  printf 'noninteractive_shell\t%s\n' "${shellni:-missing}"
  printf 'system_shim\t%s\n' "${shim:-missing}"

  local n; n="$(path_list_conflicts | wc -l | tr -d ' ')"
  printf 'binary_count\t%s\n' "$n"
  path_list_conflicts | sed 's/^/binary\t/'

  [ -n "$cur" ] || problems=$((problems + 1))
  [ -n "$shellint" ] || problems=$((problems + 1))
  [ -n "$shellni" ] || problems=$((problems + 1))
  return "$problems"
}
