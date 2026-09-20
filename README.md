# dyndns-management probe

A small, standalone container that detects its host's current public IP and
reports it to nuit-cloud on a loop, as one named probe — the client side of
the [`dyndns-management`](../) capability. It knows nothing about Postgres,
Auth0, or any other part of the platform: just one probe name, its
credentials, and a URL to POST to. Every hostname assigned to that probe in
the portal gets updated from a single report — one probe container can keep
any number of hostnames pointed at itself.

## Prerequisites

Register the probe first, in the portal under **Dynamic DNS** (or via
`POST /api/dyndns-probes` directly) — that's where you get its
`DYNDNS_UPDATE_TOKEN` **and** its `DYNDNS_BOOTSTRAP_TOKEN`, both shown
exactly once, at registration. Then assign one or more hostnames to the
probe (**Dynamic DNS → the probe → Add hostname**) — a probe with no
hostnames assigned will check in successfully but has nothing to update.

## Run it

```bash
docker build -t nuit-cloud-dyndns-probe .
docker run -d --name dyndns-probe \
  -e NUIT_CLOUD_API_URL=https://nuit-cloud.example.com \
  -e DYNDNS_PROBE_NAME=home-network \
  -e DYNDNS_UPDATE_TOKEN=<the update token from registration> \
  -e DYNDNS_BOOTSTRAP_TOKEN=<the bootstrap token from registration> \
  -v dyndns-probe-data:/data \
  --restart unless-stopped \
  nuit-cloud-dyndns-probe
```

The `-v dyndns-probe-data:/data` mount matters: it's where a self-healed
update token gets persisted (see below) so it survives this container being
recreated, not just restarted. Skipping it doesn't break anything day to
day, but every self-heal gets forgotten the next time the container is
replaced, and the stale `DYNDNS_UPDATE_TOKEN` baked into this `docker run`
takes over again.

## Environment variables

| Variable                 | Required | Default                    | Meaning                                                                 |
| ------------------------- | -------- | --------------------------- | ------------------------------------------------------------------------ |
| `NUIT_CLOUD_API_URL`      | yes      | —                            | Base URL of the nuit-cloud deployment reachable from this container.    |
| `DYNDNS_PROBE_NAME`       | yes      | —                            | The probe name registered in the portal, e.g. `home-network`.           |
| `DYNDNS_UPDATE_TOKEN`     | one of these two required | —              | That probe's update token — authenticates the routine report-ip call. Optional if `DYNDNS_BOOTSTRAP_TOKEN` is set: the probe fetches its own on first boot instead. |
| `DYNDNS_BOOTSTRAP_TOKEN`  | one of these two required | —              | That probe's bootstrap token — used only to self-heal an invalidated update token (see below). Without it, a 401 just logs and waits, same as before this existed. |
| `TOKEN_STATE_FILE`        | no       | `/data/update-token`        | Where a self-healed update token gets persisted — needs to be on the volume you mount (see above). |
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

## Self-heal: recovering from an invalidated update token

`DYNDNS_UPDATE_TOKEN` can stop working for reasons entirely outside this
container's control — an operator rotates it in the portal, or the database
it was issued against gets reset. Historically that meant a manual redeploy
with a new token, which assumes shell/SSH access to wherever this container
happens to be running — often not a safe assumption for a probe (a home
router behind NAT very often allows neither).

If `DYNDNS_BOOTSTRAP_TOKEN` is set, the probe handles this itself: on a 401
from report-ip, it calls `POST .../refresh-token` with the bootstrap token,
gets back a brand-new update token, persists it to `TOKEN_STATE_FILE`, and
retries the same report immediately. No manual redeploy needed, no
assumption of terminal access to this host, ever, after the one time you
first deployed it.

The bootstrap token itself is deliberately not something this script can
ever recover on its own — if it's wrong or gone, that's the one credential
still requiring a manual redeploy, the same as any device that's never had
working credentials at all. Rotate it in the portal (**Dynamic DNS → the
probe → Rotate bootstrap token**) if you suspect it's been compromised.
