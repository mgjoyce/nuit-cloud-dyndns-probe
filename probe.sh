#!/bin/sh
# Detects this host's public IP and reports it to nuit-cloud on a loop, as
# one named probe — every hostname assigned to that probe in the portal
# gets updated from this single report. Deliberately POSIX sh + curl, no
# language runtime — this runs wherever it's deployed (a home router's
# network, a small VM, anywhere), independent of the rest of the nuit-cloud
# stack, so it stays as small and portable as the job actually requires.
set -eu

: "${NUIT_CLOUD_API_URL:?NUIT_CLOUD_API_URL is required, e.g. https://nuit-cloud.example.com}"
: "${DYNDNS_PROBE_NAME:?DYNDNS_PROBE_NAME is required, e.g. home-network — must already be registered in the portal}"
: "${DYNDNS_UPDATE_TOKEN:?DYNDNS_UPDATE_TOKEN is required — the token shown once when the probe was registered}"

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
    # Deliberately no -f here: with -f, curl still writes the -w status via
    # this same stdout stream on an HTTP error response *and* returns
    # non-zero, which would also trigger the `|| echo "000"` fallback below
    # — doubling up into a mangled value like "401000". Without -f, curl
    # only returns non-zero (triggering the fallback) on a genuine transport
    # failure (DNS, connection refused, timeout), which is the only case
    # "000" should mean.
    status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
      -H "Authorization: Bearer $DYNDNS_UPDATE_TOKEN" \
      -H 'content-type: application/json' \
      -d "{\"ip\":\"$ip\"}" \
      "$NUIT_CLOUD_API_URL/api/dyndns-probes/$DYNDNS_PROBE_NAME/report-ip" 2>/dev/null || echo "000")"

    case "$status" in
      # 200 means the report was accepted — it doesn't mean every hostname
      # necessarily updated cleanly (one zone's DNS provider could still
      # fail while others succeed). Per-hostname outcomes are in the
      # response body and visible in the portal; this probe stays minimal
      # and doesn't parse JSON to surface them itself.
      200) log "reported $ip for probe $DYNDNS_PROBE_NAME (200)" ;;
      401) log "rejected as unauthorized — check DYNDNS_PROBE_NAME/DYNDNS_UPDATE_TOKEN, or rotate the token in the portal" >&2 ;;
      *) log "report failed for probe $DYNDNS_PROBE_NAME: HTTP $status" >&2 ;;
    esac
  fi

  sleep "$CHECK_INTERVAL_SECONDS"
done
