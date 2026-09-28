#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # OC_HTTP_* are exposed to callers/diagnostics
# lib/net.sh - network diagnostics, proxy sanity, and bounded retries.
#
# Design rules:
#   * Distinguish DNS / TCP / TLS / HTTP-status / proxy failures. Do not treat
#     every failure as "just retry".
#   * Never disable TLS verification to work around a problem.
#   * Retries are bounded with exponential backoff.

oc_proxy_vars() { printf '%s\n' HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy ALL_PROXY all_proxy; }

net_proxy_report() {
  local v
  for v in $(oc_proxy_vars); do
    local val="${!v:-}"
    [ -n "$val" ] && printf '%s\t%s\n' "$v" "$(oc_redact_string "$val")"
  done
}

# net_proxy_sanity -> 0 if proxy env looks usable, 1 if a problem is detected.
# Prints a reason on failure.
net_proxy_sanity() {
  local lower="${HTTP_PROXY:-${http_proxy:-}}"
  local hp="${HTTPS_PROXY:-${https_proxy:-}}"
  local np="${NO_PROXY:-${no_proxy:-}}"

  if [ -n "$lower" ] || [ -n "$hp" ]; then
    # Proxy must be a URL.
    for p in "$lower" "$hp"; do
      [ -z "$p" ] && continue
      case "$p" in
        http://*|https://*|socks5://*|socks://*) ;;
        *) printf 'proxy value is not a valid URL: %s' "$(oc_redact_string "$p")"; return 1 ;;
      esac
    done
    if [ -n "$hp" ] || [ -n "$lower" ]; then
      case ",$np," in
        *,localhost,*|*,127.0.0.1,*) ;;
        *) printf 'NO_PROXY does not include localhost/127.0.0.1 (risk of local server loop)'; return 1 ;;
      esac
    fi
  fi
  return 0
}

# net_dns_resolve <host> -> 0 if resolvable
net_dns_resolve() {
  local host="$1"
  if have_cmd getent; then
    getent hosts "$host" >/dev/null 2>&1 && return 0
  fi
  if have_cmd host; then
    host "$host" >/dev/null 2>&1 && return 0
  fi
  if have_cmd nslookup; then
    nslookup "$host" >/dev/null 2>&1 && return 0
  fi
  if have_cmd ping; then
    ping -c 1 -W 2 "$host" >/dev/null 2>&1 && return 0
  fi
  if have_cmd curl; then
    curl -s -o /dev/null --max-time 5 "https://$host" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# net_classify_curl_exit <exit_code> -> category
net_classify_curl_exit() {
  case "$1" in
    0)  printf 'ok' ;;
    6)  printf 'dns' ;;
    5|7) printf 'connect' ;;
    28) printf 'timeout' ;;
    35|51|60|58|66|77|90) printf 'tls' ;;
    56|55) printf 'reset' ;;
    47) printf 'redirect' ;;
    *)  printf 'curl' ;;
  esac
}

# http_probe <url> [max_time]
# Sets globals: OC_HTTP_STATUS OC_HTTP_EXIT OC_HTTP_CATEGORY OC_HTTP_MS
# Returns 0 when the endpoint is considered reachable.
http_probe() {
  local url="$1" t="${2:-15}"
  OC_HTTP_STATUS=""; OC_HTTP_EXIT=""; OC_HTTP_CATEGORY=""; OC_HTTP_MS=""
  if ! have_cmd curl; then
    OC_HTTP_CATEGORY="no-curl"
    return 1
  fi
  local out
  out="$(curl -sS -o /dev/null -L --max-time "$t" -w '%{http_code} %{time_total}' "$url" 2>/dev/null)"
  local rc=$?
  OC_HTTP_EXIT="$rc"
  if [ "$rc" -ne 0 ]; then
    OC_HTTP_CATEGORY="$(net_classify_curl_exit "$rc")"
    return 1
  fi
  OC_HTTP_STATUS="${out%% *}"
  OC_HTTP_MS="${out##* }"
  case "$OC_HTTP_STATUS" in
    2*|3*) OC_HTTP_CATEGORY="ok"; return 0 ;;
    401|403) OC_HTTP_CATEGORY="http_auth"; return 0 ;;  # reachable, needs auth
    404) OC_HTTP_CATEGORY="http_404"; return 1 ;;
    429) OC_HTTP_CATEGORY="http_429"; return 1 ;;
    5*)  OC_HTTP_CATEGORY="http_5xx"; return 1 ;;
    *)   OC_HTTP_CATEGORY="http_other"; return 1 ;;
  esac
}

net_endpoint_category_human() {
  case "$1" in
    ok)          printf 'reachable' ;;
    dns)         printf 'DNS resolution failed' ;;
    connect)     printf 'connection refused/unreachable' ;;
    timeout)     printf 'connection timed out' ;;
    tls)         printf 'TLS/SSL handshake or certificate failure' ;;
    reset)       printf 'connection reset by peer' ;;
    http_auth)   printf 'reachable (authentication required)' ;;
    http_404)    printf 'endpoint not found (HTTP 404)' ;;
    http_429)    printf 'rate limited (HTTP 429)' ;;
    http_5xx)    printf 'server error (HTTP 5xx)' ;;
    http_other)  printf 'unexpected HTTP status' ;;
    no-curl)     printf 'curl is not available' ;;
    *)           printf 'network error' ;;
  esac
}

# with_retry <attempts> <base_delay_seconds> <cmd...>
# Exponential backoff: delay, 2*delay, 4*delay ... bounded by attempts.
with_retry() {
  local attempts="$1" base="$2"; shift 2
  local n=1 delay="$base" rc=0
  while :; do
    if [ "$DRY_RUN" = "1" ]; then
      log_dry "retry-wrapped: $(oc_cmd_str "$@")"
      return 0
    fi
    if "$@"; then return 0; fi
    rc=$?
    if [ "$n" -ge "$attempts" ]; then
      log_debug "command failed after $n attempts: $(oc_cmd_str "$@")"
      return "$rc"
    fi
    log_debug "attempt $n/$attempts failed (rc=$rc); retrying in ${delay}s"
    sleep "$delay" 2>/dev/null || true
    delay=$((delay * 2))
    n=$((n + 1))
  done
}

# net_quick_summary -> prints "cat|detail" lines for the doctor.
net_quick_summary() {
  local targets="$OC_NET_TARGETS"
  : "${targets:=github|https://github.com|install|https://opencode.ai/install|npm|https://registry.npmjs.org}"
  local name url
  local OLDIFS="$IFS"
  IFS='|'
  # shellcheck disable=SC2086
  set -- $targets
  IFS="$OLDIFS"
  while [ $# -ge 2 ]; do
    name="$1"; url="$2"; shift 2
    if http_probe "$url" 12; then
      printf '%s\tok\t%s\n' "$name" "${OC_HTTP_STATUS:-?}"
    else
      printf '%s\t%s\t%s\n' "$name" "$OC_HTTP_CATEGORY" "${OC_HTTP_STATUS:-rc=${OC_HTTP_EXIT:-?}}"
    fi
  done
}
