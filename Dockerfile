# A minimal, standalone dynamic DNS probe — detects this host's public IP and
# reports it to nuit-cloud's dyndns-management-api on a loop. Deployed
# independently of the rest of the platform (e.g. on a home network's
# gateway or any host whose public IP needs tracking), not part of the
# shared Dockerfile at the repo root. See README.md for the env vars it needs.
FROM alpine:3.20

RUN apk add --no-cache curl

COPY probe.sh /probe.sh
RUN chmod +x /probe.sh

# Where probe.sh persists a self-healed update token (TOKEN_STATE_FILE,
# default /data/update-token) — declared so a container recreated without
# an explicit `-v` still keeps an anonymous volume across it, rather than
# silently forgetting every self-heal the moment the container is replaced.
# Mount a named volume instead (see README.md) to survive a full removal.
VOLUME ["/data"]

ENTRYPOINT ["/probe.sh"]
