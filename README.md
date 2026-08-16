# dyndns-management probe

A small, standalone container that detects its host's current public IP and
reports it to nuit-cloud on a loop, as one named probe — the client side of
the [`dyndns-management`](../) capability. It knows nothing about Postgres,
Auth0, or any other part of the platform: just one probe name, one secret
token, and a URL to POST to. Every hostname assigned to that probe in the
portal gets updated from a single report — one probe container can keep any
number of hostnames pointed at itself.

## Prerequisites

Register the probe first, in the portal under **Dynamic DNS** (or via
`POST /api/dyndns-probes` directly) — that's where you get the
`DYNDNS_UPDATE_TOKEN` this container needs. The token is shown exactly once,
at registration (or after a token rotation); if you lose it, rotate it in
the portal to get a new one. Then assign one or more hostnames to the probe
(**Dynamic DNS → the probe → Add hostname**) — a probe with no hostnames
assigned will check in successfully but has nothing to update.

## Run it

```bash
docker build -t nuit-cloud-dyndns-probe .
docker run -d --name dyndns-probe \
  -e NUIT_CLOUD_API_URL=https://nuit-cloud.example.com \
  -e DYNDNS_PROBE_NAME=home-network \
  -e DYNDNS_UPDATE_TOKEN=<the token from registration> \
  --restart unless-stopped \
  nuit-cloud-dyndns-probe
```

## Environment variables

| Variable                 | Required | Default                    | Meaning                                                                 |
| ------------------------- | -------- | --------------------------- | ------------------------------------------------------------------------ |
| `NUIT_CLOUD_API_URL`      | yes      | —                            | Base URL of the nuit-cloud deployment reachable from this container.    |
| `DYNDNS_PROBE_NAME`       | yes      | —                            | The probe name registered in the portal, e.g. `home-network`.           |
| `DYNDNS_UPDATE_TOKEN`     | yes      | —                            | That probe's secret update token.                                      |
| `IP_ECHO_URL`             | no       | `https://api.ipify.org`     | Where to ask "what's my public IP" — swap for a self-hosted echo if you'd rather not call out to a third party. |
| `CHECK_INTERVAL_SECONDS`  | no       | `300`                        | How often to check and (if changed) report.                            |

## How it decides whether to update anything

The probe always reports whatever IP it currently sees — it does not track
whether that's changed since last time, and it doesn't know how many
hostnames are assigned to it. Deciding "is this actually new" per hostname,
and publishing each changed record, lives entirely on the server side
(`applyIpReport` in `nuit-cloud-dyndns-management`), so the probe stays as
simple as possible and the server remains the single source of truth for
what every record currently says. A `200` response means the report was
accepted — it doesn't guarantee every hostname updated cleanly (one DNS
zone could fail while others succeed); per-hostname outcomes are in the
response body and visible in the portal, not parsed by this script.
