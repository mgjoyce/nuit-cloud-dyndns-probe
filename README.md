# dyndns-management probe

A small, standalone container that detects its host's current public IP and
reports it to nuit-cloud on a loop — the client side of the
[`dyndns-management`](../) capability. It knows nothing about Postgres,
Auth0, or any other part of the platform: just one hostname, one secret
token, and a URL to POST to.

## Prerequisites

Register the hostname first, in the portal under **Dynamic DNS** (or via
`POST /api/dyndns-hosts` directly) — that's where you get the
`DYNDNS_UPDATE_TOKEN` this container needs. The token is shown exactly once,
at registration (or after a token rotation); if you lose it, rotate it in
the portal to get a new one.

## Run it

```bash
docker build -t nuit-cloud-dyndns-probe .
docker run -d --name dyndns-probe \
  -e NUIT_CLOUD_API_URL=https://nuit-cloud.example.com \
  -e DYNDNS_HOSTNAME=home1.example.com \
  -e DYNDNS_UPDATE_TOKEN=<the token from registration> \
  --restart unless-stopped \
  nuit-cloud-dyndns-probe
```

## Environment variables

| Variable                 | Required | Default                    | Meaning                                                                 |
| ------------------------- | -------- | --------------------------- | ------------------------------------------------------------------------ |
| `NUIT_CLOUD_API_URL`      | yes      | —                            | Base URL of the nuit-cloud deployment reachable from this container.    |
| `DYNDNS_HOSTNAME`         | yes      | —                            | The hostname registered in the portal, e.g. `home1.example.com`.        |
| `DYNDNS_UPDATE_TOKEN`     | yes      | —                            | That host's secret update token.                                       |
| `IP_ECHO_URL`             | no       | `https://api.ipify.org`     | Where to ask "what's my public IP" — swap for a self-hosted echo if you'd rather not call out to a third party. |
| `CHECK_INTERVAL_SECONDS`  | no       | `300`                        | How often to check and (if changed) report.                            |

## How it decides whether to update anything

The probe always reports whatever IP it currently sees — it does not track
whether that's changed since last time. Deciding "is this actually new" and
publishing the DNS record only when it is lives entirely on the server side
(`applyIpReport` in `nuit-cloud-dyndns-management`), so the probe stays as
simple as possible and the server remains the single source of truth for
what the record currently says.
