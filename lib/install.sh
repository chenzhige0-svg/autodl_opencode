#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # OC_INSTALLED_VERSION is read by callers/tests
# lib/install.sh - installation and upgrade of the OpenCode binary.
#
# Uses the official release artifacts (the same ones the official installer at
# https://opencode.ai/install downloads), but adds: bounded retry, atomic
# replacement and a run of the extracted binary before it is committed. An
# interrupted download therefore never leaves a "successful" install behind.

OC_RELEASE_BASE="${OPENCODE_RELEASE_BASE:-https://github.com/anomalyco/opencode/releases}"
OC_GITHUB_API="${OPENCODE_GITHUB_API:-https://api.github.com/repos/anomalyco/opencode/releases/latest}"
OC_INSTALL_METHOD="${OPENCODE_INSTALL_METHOD:-curl}"
OC_INSTALL_ATTEMPTS="${OPENCODE_INSTALL_ATTEMPTS:-3}"

install_marker_file() { printf '%s/install-state.json' "$OC_STATE_HOME"; }

install_write_marker() {
  local version="$1" method="$2" target="$3" bin="$4"
  local f; f="$(install_marker_file)"
  ensure_dir "$OC_STATE_HOME"
  {
    printf '{\n'
    printf '  "version": "%s",\n' "$(printf '%s' "$version" | tr -d '\r\n')"
    printf '  "method": "%s",\n' "$method"
    printf '  "target": "%s",\n' "$target"
    printf '  "binary": "%s",\n' "$bin"
    printf '  "installed_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '}\n'
  } | atomic_write "$f"
}

install_read_marker() {
  local f; f="$(install_marker_file)"
  [ -f "$f" ] || return 1
  sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$f" | head -1
}

# install_prereqs_for_method <method> -> prints space separated missing tools
install_prereqs_for_method() {
  local method="$1" missing=""
  case "$method" in
    curl)
      have_cmd curl || missing="$missing curl"
      have_cmd tar  || missing="$missing tar"
      ;;
    npm|pnpm|yarn)
      have_cmd node || missing="$missing node"
      have_cmd "$method" || missing="$missing $method"
      ;;
    bun)
      have_cmd bun || missing="$missing bun"
      ;;
  esac
  printf '%s' "$(trim "$missing")"
}

resolve_latest_version() {
  have_cmd curl || return 1
  local body tag
  body="$(curl -fsSL --max-time 20 "$OC_GITHUB_API" 2>/dev/null)" || return 1
  tag="$(printf '%s' "$body" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$tag" ] || return 1
  printf '%s' "$tag"
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------
# _oc_version_num <component>  -> numeric value of a dot-separated component
_oc_version_num() {
  local s="$1"
  s="${s//[!0-9]/}"
  [ -n "$s" ] || { printf '0'; return 0; }
  printf '%s' "$((10#$s))"
}

# oc_version_cmp <a> <b> -> prints -1 (a older), 0 (same) or 1 (a newer).
# Compares dotted numeric components; a pre-release suffix only contributes its
# digits, which is enough to order v1.0.180 / v1.0.180-beta.2 consistently.
oc_version_cmp() {
  local a="${1#v}" b="${2#v}"
  [ "$a" = "$b" ] && { printf '0'; return 0; }
  local IFS='.'
  # shellcheck disable=SC2206  # intentional word splitting on '.'
  local av=($a) bv=($b)
  local n=${#av[@]} i x y
  [ "${#bv[@]}" -gt "$n" ] && n="${#bv[@]}"
  for ((i = 0; i < n; i++)); do
    x="$(_oc_version_num "${av[i]:-0}")"
    y="$(_oc_version_num "${bv[i]:-0}")"
    if [ "$x" -lt "$y" ]; then printf -- '-1'; return 0; fi
    if [ "$x" -gt "$y" ]; then printf '1'; return 0; fi
  done
  printf '0'
}

# installed_version -> version of the binary the user actually runs (or empty)
installed_version() {
  local bin
  bin="$(resolve_in_path opencode 2>/dev/null || true)"
  [ -n "$bin" ] || bin="$OC_BIN"
  opencode_version_at "$bin" 2>/dev/null || true
}

# update_check [version|latest] -> 0 = current, OC_EXIT_UPDATE = newer exists
# Read-only: asks the GitHub API what the newest tag is and compares.
update_check() {
  local pin="${1:-}" current latest cmp
  current="$(installed_version)"
  if [ -z "$current" ]; then
    log_error "OpenCode is not installed or not executable (expected at $OC_BIN)"
    return "$OC_EXIT_ENV"
  fi
  if [ -n "$pin" ] && [ "$pin" != "latest" ]; then
    latest="${pin#v}"
  else
    if ! latest="$(resolve_latest_version)"; then
      log_error "could not query the latest release from $OC_GITHUB_API"
      log_info "hint: if you are in mainland China, try 'source /etc/network_turbo' then re-run"
      return "$OC_EXIT_ENV"
    fi
  fi
  cmp="$(oc_version_cmp "$current" "$latest")"
  case "$cmp" in
    0) log_ok "up to date: v$current"; return 0 ;;
    -1)
      log_info "update available: v$current -> v$latest"
      return "$OC_EXIT_UPDATE"
      ;;
    *)
      log_warn "installed v$current is newer than the published release v$latest"
      log_info "nothing to do (use 'update v$current --force' to reinstall it)"
      return 0
      ;;
  esac
}

# install_release_direct <version|latest> <method-label>
install_release_direct() {
  local version="$1" method="${2:-curl}"
  local os arch target filename url tmp extract
  os="$(oc_os)"; arch="$(oc_arch)"
  case "$os" in
    linux|darwin) ;;
    *) log_error "direct download supports linux/darwin; detected '$os'"; return "$OC_EXIT_ENV" ;;
  esac
  [ "$arch" != "unknown" ] || { log_error "unsupported CPU architecture: $(detect_arch_raw)"; return "$OC_EXIT_ENV"; }

  target="$(oc_install_target)"
  if [ "$os" = "linux" ]; then
    filename="opencode-$target.tar.gz"
  else
    filename="opencode-$target.zip"
  fi

  if [ -z "$version" ] || [ "$version" = "latest" ]; then
    url="$OC_RELEASE_BASE/latest/download/$filename"
  else
    version="${version#v}"
    url="$OC_RELEASE_BASE/download/v$version/$filename"
  fi

  log_info "target: $target"
  log_info "download: $url"

  if [ "$DRY_RUN" = "1" ]; then
    log_dry "would download $url"
    log_dry "would validate the extracted binary and atomically install it to $OC_BIN"
    OC_INSTALLED_VERSION="(dry-run)"
    return 0
  fi

  oc_tmp_init >/dev/null
  tmp="$OC_TMPDIR"
  local archive="$tmp/$filename"
  extract="$tmp/extract"
  ensure_dir "$extract"

  _do_download() {
    curl -fSL --connect-timeout 20 --max-time 600 -o "$archive" "$url"
  }
  if ! with_retry "$OC_INSTALL_ATTEMPTS" 3 _do_download; then
    log_error "download failed after $OC_INSTALL_ATTEMPTS attempts"
    log_info "hint: if you are in mainland China, try 'source /etc/network_turbo' then re-run"
    return "$OC_EXIT_ENV"
  fi
  [ -s "$archive" ] || { log_error "downloaded archive is empty"; return "$OC_EXIT_ENV"; }

  if [ "$os" = "linux" ]; then
    if ! tar -xzf "$archive" -C "$extract" 2>/dev/null; then
      log_error "failed to extract archive (corrupt download?)"
      return "$OC_EXIT_ENV"
    fi
  else
    if ! unzip -q "$archive" -d "$extract" 2>/dev/null; then
      log_error "failed to extract archive (corrupt download?)"
      return "$OC_EXIT_ENV"
    fi
  fi

  local newbin="$extract/opencode"
  [ -f "$newbin" ] || { log_error "archive did not contain an 'opencode' binary"; return "$OC_EXIT_ENV"; }

  # Validate the new binary BEFORE committing it.
  local newver
  if ! newver="$(opencode_version_at "$newbin")"; then
    chmod +x "$newbin" 2>/dev/null || true
    if ! newver="$(opencode_version_at "$newbin")"; then
      log_error "downloaded binary failed to execute; refusing to install it"
      return "$OC_EXIT_ENV"
    fi
  fi
  log_info "validated downloaded binary: v$newver"

  ensure_dir "$OC_HOME_INSTALL_DIR"
  local staged="$OC_HOME_INSTALL_DIR/.opencode.new.$$"
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "install v$newver -> $OC_BIN"
  else
    cp -f "$newbin" "$staged" || { log_error "cannot stage binary in $OC_HOME_INSTALL_DIR"; return "$OC_EXIT_ENV"; }
    chmod 755 "$staged" || true
    if ! mv -f "$staged" "$OC_BIN"; then
      rm -f "$staged"
      log_error "failed to move binary into place at $OC_BIN"
      return "$OC_EXIT_ENV"
    fi
  fi
  install_write_marker "$newver" "$method" "$target" "$OC_BIN"
  OC_INSTALLED_VERSION="$newver"
  return 0
}

install_via_package_manager() {
  local method="$1" version="$2" pkg="opencode-ai"
  local spec="$pkg"
  [ -n "$version" ] && [ "$version" != "latest" ] && spec="$pkg@${version#v}"
  case "$method" in
    npm)  _do() { npm install -g "$spec"; } ;;
    pnpm) _do() { pnpm add -g "$spec"; } ;;
    bun)  _do() { bun install -g "$spec"; } ;;
    *)    log_error "unsupported package manager: $method"; return "$OC_EXIT_USAGE" ;;
  esac
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "would run: $method install -g $spec"
    OC_INSTALLED_VERSION="(dry-run)"
    return 0
  fi
  if ! with_retry "$OC_INSTALL_ATTEMPTS" 3 _do; then
    log_error "package manager install failed ($method)"
    return "$OC_EXIT_ENV"
  fi
  local resolved; resolved="$(resolve_in_path opencode)"
  [ -n "$resolved" ] || { log_error "package manager reported success but 'opencode' is not on PATH"; return "$OC_EXIT_ENV"; }
  local ver; ver="$(opencode_version_at "$resolved" || true)"
  install_write_marker "${ver:-unknown}" "$method" "$(oc_install_target)" "$resolved"
  OC_INSTALLED_VERSION="${ver:-unknown}"
  return 0
}

# install_opencode [version]
install_opencode() {
  local version="${1:-}"
  local method="$OC_INSTALL_METHOD"

  if [ "$method" = "auto" ]; then
    if have_cmd bun; then method="bun"; elif have_cmd npm; then method="npm"; else method="curl"; fi
  fi

  local missing; missing="$(install_prereqs_for_method "$method")"
  if [ -n "$missing" ]; then
    log_error "missing tools required for '$method' install: $missing"
    log_info "run './setup.sh repair' to attempt installing required dependencies"
    return "$OC_EXIT_ENV"
  fi

  # Space check (need roughly 150 MB for download + extraction).
  local avail; avail="$(oc_disk_avail_kb "$HOME")"
  if [ -n "$avail" ] && [ "$avail" -lt 204800 ]; then
    log_error "insufficient free space at \$HOME (need >= 200MB, have $((avail/1024))MB)"
    return "$OC_EXIT_ENV"
  fi

  log_step "Installing OpenCode (method: $method)"
  case "$method" in
    curl) install_release_direct "$version" curl ;;
    npm|pnpm|bun|yarn) install_via_package_manager "$method" "$version" ;;
    *) log_error "unknown install method: $method"; return "$OC_EXIT_USAGE" ;;
  esac
}

# repair_or_install <version> - install if missing; report broken install state.
install_status() {
  # Prints one of: missing | ok | broken
  local bin; bin="$(resolve_in_path opencode)"
  [ -n "$bin" ] || bin="$OC_BIN"
  if [ ! -x "$bin" ]; then printf 'missing'; return 0; fi
  if opencode_version_at "$bin" >/dev/null 2>&1; then printf 'ok'; else printf 'broken'; fi
}

# upgrade_opencode <version|latest>
#
# 'latest' is resolved through the GitHub API first so the current version can be
# compared with the published one. When they match, nothing is downloaded: an
# idempotent update is free and safe to run from a timer or a login hook.
upgrade_opencode() {
  local version="${1:-latest}"
  local bin; bin="$(resolve_in_path opencode)"
  [ -n "$bin" ] || bin="$OC_BIN"
  local old; old="$(opencode_version_at "$bin" 2>/dev/null || printf 'unknown')"

  if [ -z "$version" ] || [ "$version" = "latest" ]; then
    local target=""
    target="$(resolve_latest_version 2>/dev/null || true)"
    if [ -n "$target" ]; then
      if [ "$FORCE_INSTALL" != "1" ] && [ "$old" != "unknown" ]; then
        case "$(oc_version_cmp "$old" "$target")" in
          0)
            log_ok "already on the latest release (v$old); nothing to do"
            OC_INSTALLED_VERSION="$old"
            return 0
            ;;
          1)
            log_warn "installed v$old is newer than the published release v$target; not downgrading"
            log_info "use 'update $old --force' to reinstall it anyway"
            return 0
            ;;
        esac
      fi
      log_step "Upgrading OpenCode ($old -> v$target)"
      version="$target"
    else
      log_step "Upgrading OpenCode (current: $old)"
      log_warn "could not resolve the latest release; falling back to the 'latest' download pointer"
    fi
  else
    version="${version#v}"
    log_step "Upgrading OpenCode (current: $old, target: v$version)"
  fi

  local method; method="$(detect_install_method "$bin")"
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "upgrade opencode to ${version:-latest} via $method"
    return 0
  fi
  case "$method" in
    npm|bun|pnpm)
      install_via_package_manager "$method" "$version"
      ;;
    *)
      install_release_direct "$version" "curl" || return $?
      ;;
  esac
  local new; new="$(opencode_version_at "$OC_BIN" 2>/dev/null || opencode_version_at "$(resolve_in_path opencode)" 2>/dev/null || printf 'unknown')"
  log_ok "opencode upgraded: $old -> $new"
}

# install_official_script - run the official installer (fallback / fidelity mode)
install_official_script() {
  local version="${1:-}"
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "would run the official installer from https://opencode.ai/install --no-modify-path"
    return 0
  fi
  local tmp; oc_tmp_init >/dev/null; tmp="$OC_TMPDIR"
  local installer="$tmp/install.sh"
  if ! with_retry "$OC_INSTALL_ATTEMPTS" 3 curl -fsSL --connect-timeout 20 --max-time 120 -o "$installer" https://opencode.ai/install; then
    log_error "could not download the official installer"
    return "$OC_EXIT_ENV"
  fi
  local args=(--no-modify-path)
  [ -n "$version" ] && args+=(--version "$version")
  log_info "running official installer (this script manages PATH itself)"
  if [ "$DRY_RUN" = "1" ]; then
    log_dry "VERSION=$version bash $installer --no-modify-path"
    return 0
  fi
  VERSION="$version" bash "$installer" "${args[@]}" || return "$OC_EXIT_ENV"
}
