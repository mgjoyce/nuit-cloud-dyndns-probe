#!/bin/sh
# Detects this host's public IP and reports it to nuit-cloud on a loop, as
# one named probe — every hostname assigned to that probe in the portal
# gets updated from this single report. Deliberately POSIX sh + curl, no
# language runtime — this runs wherever it's deployed (a home router's
# network, a small VM, anywhere), independent of the rest of the nuit-cloud
# stack, so it stays as small and portable as the job actually requires.
#
# Two tokens, two very different lifecycles: DYNDNS_UPDATE_TOKEN
# authenticates the routine report-ip call above and can become invalid for
# reasons entirely outside this script's control (an operator rotates it,
# or the database it was issued against gets reset). DYNDNS_BOOTSTRAP_TOKEN
# exists so THIS script can recover from exactly that on its own — call
# back with it, get a fresh update token, keep going — with no assumption
# that whoever's operating this probe has shell/SSH access to wherever it's
# actually running (a home router behind NAT very often allows neither).
# The bootstrap token is optional: without one, a 401 just logs and waits,
# same as before this existed.
set -eu

: "${NUIT_CLOUD_API_URL:?NUIT_CLOUD_API_URL is required, e.g. https://nuit-cloud.example.com}"
: "${DYNDNS_PROBE_NAME:?DYNDNS_PROBE_NAME is required, e.g. home-network — must already be registered in the portal}"

if [ -z "${DYNDNS_UPDATE_TOKEN:-}" ] && [ -z "${DYNDNS_BOOTSTRAP_TOKEN:-}" ]; then
  echo "At least one of DYNDNS_UPDATE_TOKEN or DYNDNS_BOOTSTRAP_TOKEN is required." >&2
  echo "Registering a probe in the portal gives you both — see README.md." >&2
  exit 1
fi

# Where the current update token is persisted once self-heal has replaced
# it at least once — must be on a volume that survives a container restart,
# or every self-heal is forgotten the moment this container is recreated
# and the stale env var value takes over again. See README.md.
TOKEN_STATE_FILE="${TOKEN_STATE_FILE:-/data/update-token}"
# Which build this is (baked in by the image build; `dev` for a local one). Sent with every call home so the platform can
# show it next to the probe — see README.md. Purely informational: the server ignores a value it does not like.
PROBE_VERSION="${PROBE_VERSION:-dev}"

# ipify is used here purely as a "what does the internet see as my source
# IP" echo — nuit-cloud never talks to it, and no data beyond an empty GET
# request leaves this container toward it.
IP_ECHO_URL="${IP_ECHO_URL:-https://api.ipify.org}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-300}"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1"
}

# A persisted token (from a past self-heal) normally beats the
# DYNDNS_UPDATE_TOKEN baked into this container's env — it's the newer of
# the two. The exception: an operator who redeploys with a *different*
# DYNDNS_UPDATE_TOKEN (e.g. right after rotating it in the portal) has just
# said what they want, and a stale persisted value from before that must not
# silently override it — with no bootstrap token in the env to recover with,
# that would leave the probe stuck at 401 forever. So the env token last
# adopted is remembered next to the state file (TOKEN_SEED_FILE); a
# different one discards the persisted token and wins.
TOKEN_SEED_FILE="${TOKEN_STATE_FILE}.seed"
if [ -n "${DYNDNS_UPDATE_TOKEN:-}" ] && [ "$(cat "$TOKEN_SEED_FILE" 2>/dev/null || true)" != "$DYNDNS_UPDATE_TOKEN" ]; then
  rm -f "$TOKEN_STATE_FILE"
  # Non-fatal: an unwritable state directory just means self-heals won't
  # survive a restart, which is already documented (see README.md).
  printf '%s' "$DYNDNS_UPDATE_TOKEN" > "$TOKEN_SEED_FILE" 2>/dev/null || log "could not record $TOKEN_SEED_FILE — is $(dirname "$TOKEN_STATE_FILE") writable?" >&2
fi

if [ -s "$TOKEN_STATE_FILE" ]; then
  update_token="$(cat "$TOKEN_STATE_FILE")"
else
  update_token="${DYNDNS_UPDATE_TOKEN:-}"
fi

# Calls refresh-token with the bootstrap token, persists and prints the new
# update token on success. Returns non-zero (printing nothing) on any
# failure — an unreachable server, a wrong/missing bootstrap token, or a
# response that doesn't parse — so callers never mistake silence for a
# real token. Response is always exactly `{"updateToken":"..."}` (see
# RefreshTokenResponse), so a plain sed extraction is reliable here without
# reaching for a JSON parser this script otherwise has no need for.
refresh_token() {
  if [ -z "${DYNDNS_BOOTSTRAP_TOKEN:-}" ]; then
    return 1
  fi

  response="$(curl -fsS -X POST \
    -H "Authorization: Bearer $DYNDNS_BOOTSTRAP_TOKEN" \
    -H "X-Probe-Version: $PROBE_VERSION" \
    "$NUIT_CLOUD_API_URL/api/dyndns-probes/$DYNDNS_PROBE_NAME/refresh-token" 2>/dev/null || true)"
  if [ -z "$response" ]; then
    return 1
  fi

  new_token="$(echo "$response" | sed -n 's/.*"updateToken":"\([^"]*\)".*/\1/p')"
  if [ -z "$new_token" ]; then
    return 1
  fi

  echo "$new_token" > "$TOKEN_STATE_FILE"
  echo "$new_token"
  return 0
}

# No update token at all yet (deployed with only a bootstrap token) — mint
# one before the first report attempt instead of guaranteeing a 401.
if [ -z "$update_token" ]; then
  log "no update token yet — fetching one with the bootstrap token"
  if fetched="$(refresh_token)"; then
    update_token="$fetched"
    log "fetched an initial update token"
  else
    log "could not fetch an initial update token — check DYNDNS_BOOTSTRAP_TOKEN" >&2
  fi
fi

while true; do
  ip="$(curl -fsS "$IP_ECHO_URL" 2>/dev/null || true)"

  if [ -z "$ip" ]; then
    log "could not detect public IP from $IP_ECHO_URL" >&2
  elif [ -z "$update_token" ]; then
    log "no update token available — check DYNDNS_UPDATE_TOKEN/DYNDNS_BOOTSTRAP_TOKEN" >&2
  else
    # Deliberately no -f here: with -f, curl still writes the -w status via
    # this same stdout stream on an HTTP error response *and* returns
    # non-zero, which would also trigger the `|| echo "000"` fallback below
    # — doubling up into a mangled value like "401000". Without -f, curl
    # only returns non-zero (triggering the fallback) on a genuine transport
    # failure (DNS, connection refused, timeout), which is the only case
    # "000" should mean.
    status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $update_token" \
      -H "X-Probe-Version: $PROBE_VERSION" \
      -H 'content-type: application/json' \
      -d "{\"ip\":\"$ip\"}" \
      "$NUIT_CLOUD_API_URL/api/dyndns-probes/$DYNDNS_PROBE_NAME/report-ip" 2>/dev/null || echo "000")"

    # A 401 gets exactly one self-heal attempt per loop iteration — if the
    # bootstrap token is also wrong, retrying in a hot loop would just hammer
    # the server; the outer `sleep` below already paces the next attempt.
    if [ "$status" = "401" ]; then
      log "rejected as unauthorized — attempting self-heal"
      if fetched="$(refresh_token)"; then
        update_token="$fetched"
        log "self-heal succeeded — retrying this report with the new token"
        status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
          -H "Authorization: Bearer $update_token" \
          -H "X-Probe-Version: $PROBE_VERSION" \
          -H 'content-type: application/json' \
          -d "{\"ip\":\"$ip\"}" \
          "$NUIT_CLOUD_API_URL/api/dyndns-probes/$DYNDNS_PROBE_NAME/report-ip" 2>/dev/null || echo "000")"
      else
        log "self-heal unavailable or failed — check DYNDNS_BOOTSTRAP_TOKEN, or rotate a token in the portal" >&2
      fi
    fi

    case "$status" in
      # 200 means the report was accepted — it doesn't mean every hostname
      # necessarily updated cleanly (one zone's DNS provider could still
      # fail while others succeed). Per-hostname outcomes are in the
      # response body and visible in the portal; this probe stays minimal
      # and doesn't parse JSON to surface them itself.
      200) log "reported $ip for probe $DYNDNS_PROBE_NAME (200)" ;;
      401) log "still unauthorized after self-heal attempt for probe $DYNDNS_PROBE_NAME" >&2 ;;
      *) log "report failed for probe $DYNDNS_PROBE_NAME: HTTP $status" >&2 ;;
    esac
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
