#!/bin/sh
# Detects this host's public IP and reports it to nuit-cloud on a loop.
# Deliberately POSIX sh + curl, no language runtime — this runs wherever it's
# deployed (a home router's network, a small VM, anywhere), independent of
# the rest of the nuit-cloud stack, so it stays as small and portable as the
# job actually requires.
set -eu

: "${NUIT_CLOUD_API_URL:?NUIT_CLOUD_API_URL is required, e.g. https://nuit-cloud.example.com}"
: "${DYNDNS_HOSTNAME:?DYNDNS_HOSTNAME is required, e.g. home1.example.com — must already be registered in the portal}"
: "${DYNDNS_UPDATE_TOKEN:?DYNDNS_UPDATE_TOKEN is required — the token shown once when the host was registered}"

# ipify is used here purely as a "what does the internet see as my source
# IP" echo — nuit-cloud never talks to it, and no data beyond an empty GET
# request leaves this container toward it.
IP_ECHO_URL="${IP_ECHO_URL:-https://api.ipify.org}"
CHECK_INTERVAL_SECONDS="${CHECK_INTERVAL_SECONDS:-300}"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1"
}

while true; do
  ip="$(curl -fsS "$IP_ECHO_URL" 2>/dev/null || true)"

  if [ -z "$ip" ]; then
    log "could not detect public IP from $IP_ECHO_URL" >&2
  else
    status="$(curl -fsS -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $DYNDNS_UPDATE_TOKEN" \
      -H 'content-type: application/json' \
      -d "{\"ip\":\"$ip\"}" \
      "$NUIT_CLOUD_API_URL/api/dyndns-hosts/$DYNDNS_HOSTNAME/report-ip" 2>/dev/null || echo "000")"

    case "$status" in
      200) log "reported $ip for $DYNDNS_HOSTNAME (200)" ;;
      401) log "rejected as unauthorized — check DYNDNS_HOSTNAME/DYNDNS_UPDATE_TOKEN, or rotate the token in the portal" >&2 ;;
      *) log "report failed for $DYNDNS_HOSTNAME: HTTP $status" >&2 ;;
    esac
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
