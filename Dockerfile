# A minimal, standalone dynamic DNS probe — detects this host's public IP and
# reports it to nuit-cloud's dyndns-management-api on a loop. Deployed
# independently of the rest of the platform (e.g. on a home network's
# gateway or any host whose public IP needs tracking), not part of the
# shared Dockerfile at the repo root. See README.md for the env vars it needs.
FROM alpine:3.20

RUN apk add --no-cache curl

COPY probe.sh /probe.sh
RUN chmod +x /probe.sh

ENTRYPOINT ["/probe.sh"]
