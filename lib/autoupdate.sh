#!/usr/bin/env bash
# shellcheck shell=bash
# lib/autoupdate.sh - keep the installed OpenCode on the latest release.
#
# Auto-update is opt-in. 'autoupdate on' writes a single marker-managed line
# into the login shell's rc files:
#
#     "<repo>/setup.sh" autoupdate run >/dev/null 2>&1 &
#
# Each new shell therefore schedules a *cheap* check in the background. The check
# is throttled by a stamp file (~/.local/state/opencode-autodl/autoupdate.stamp)
# to at most $OC_AUTOUPDATE_INTERVAL seconds (24h by default), and it only
# downloads when the published release differs from the installed version (see
# upgrade_opencode in lib/install.sh, which compares versions before fetching).
#
# A shell hook is used instead of cron/systemd on purpose: AutoDL containers
# usually have neither a running cron daemon nor systemd, and the system disk is
# reset on every image change, which would drop a crontab anyway.

autoupdate_stamp_file() { printf '%s/autoupdate.stamp' "$OC_STATE_HOME"; }
autoupdate_log_file() { printf '%s/autoupdate.log' "$OC_LOG_DIR"; }

autoupdate_interval_minutes() {
  local minutes=$((OC_AUTOUPDATE_INTERVAL / 60))
  [ "$minutes" -ge 1 ] || minutes=1
  printf '%s' "$minutes"
}

# autoupdate_due -> 0 when the last check is older than the interval
autoupdate_due() {
  local f
  f="$(autoupdate_stamp_file)"
  [ -f "$f" ] || return 0
  [ -n "$(find "$f" -mmin +"$(autoupdate_interval_minutes)" 2>/dev/null || true)" ]
}

autoupdate_block_body() {
  # shellcheck disable=SC2016  # written verbatim into the user's rc file
  printf '"%s" autoupdate run >/dev/null 2>&1 &' "$OCDEPLOY_ROOT/setup.sh"
}

autoupdate_target_rcfiles() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$f"
  done <<EOF
$(path_target_rcfiles)
EOF
}

autoupdate_enable() {
  local f body count=0
  body="$(autoupdate_block_body)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    upsert_managed_block "$f" "$body" "$OC_AUTO_MARK_BEGIN" "$OC_AUTO_MARK_END" || return 1
    count=$((count + 1))
  done <<EOF
$(autoupdate_target_rcfiles)
EOF
  if [ "$count" = "0" ]; then
    log_error "no rc file to configure (unknown login shell)"
    return "$OC_EXIT_ENV"
  fi
  log_ok "autoupdate enabled in $count rc file(s); checked at most every $(autoupdate_interval_minutes)m"
  log_info "the first check runs on the next interactive shell; force one now with 'autoupdate run'"
}

autoupdate_disable() {
  local f count=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if managed_block_present "$f" "$OC_AUTO_MARK_BEGIN"; then
      remove_managed_block "$f" "$OC_AUTO_MARK_BEGIN" "$OC_AUTO_MARK_END" || return 1
      count=$((count + 1))
    fi
  done <<EOF
$(autoupdate_target_rcfiles)
EOF
  log_ok "autoupdate disabled ($count rc file(s) cleaned)"
}

autoupdate_status() {
  local f enabled=0 stamp last="never"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    managed_block_present "$f" "$OC_AUTO_MARK_BEGIN" && enabled=1
  done <<EOF
$(autoupdate_target_rcfiles)
EOF
  stamp="$(autoupdate_stamp_file)"
  [ -f "$stamp" ] && last="$(cat "$stamp" 2>/dev/null || printf 'unknown')"
  printf 'autoupdate: %s\n' "$([ "$enabled" = "1" ] && printf enabled || printf disabled)"
  printf 'interval:   %sm\n' "$(autoupdate_interval_minutes)"
  printf 'last check: %s\n' "$last"
  printf 'log:        %s\n' "$(autoupdate_log_file)"
}

# autoupdate_run - the throttled worker invoked by the shell rc block.
# Safe to call at every shell start: it exits immediately when the interval has
# not elapsed, and the update itself is a no-op when the version already matches.
autoupdate_run() {
  local stamp
  if ! autoupdate_due; then
    log_debug "autoupdate: checked less than $(autoupdate_interval_minutes)m ago; skipping"
    return 0
  fi
  stamp="$(autoupdate_stamp_file)"
  ensure_dir "$(dirname "$stamp")"
  # Stamp before updating: a network failure must not retry on every shell start.
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | atomic_write "$stamp" || true
  log_step "autoupdate: checking for a newer OpenCode release"
  upgrade_opencode latest
}
