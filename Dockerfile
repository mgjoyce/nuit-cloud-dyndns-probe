# A minimal, standalone dynamic DNS probe — detects this host's public IP and
# reports it to nuit-cloud's dyndns-management-api on a loop. Deployed
# independently of the rest of the platform (e.g. on a home network's
# gateway or any host whose public IP needs tracking), not part of the
# platform repo's own Dockerfile. See README.md for the env vars it needs.
FROM alpine:3.20

RUN apk add --no-cache curl

# The version this image reports to the platform (set by the publish workflow: the release tag, or sha-<short>).
ARG PROBE_VERSION=dev
ENV PROBE_VERSION=$PROBE_VERSION

COPY probe.sh /probe.sh
RUN chmod +x /probe.sh && mkdir -p /data

# Where probe.sh persists a self-healed update token (TOKEN_STATE_FILE, default
# /data/update-token). The directory exists, but is deliberately *not* declared a VOLUME: an image volume becomes an
# anonymous mount in the container's OCI config, which runtimes without volume support (nuit-cloud's Nuit Container
# Service) refuse to start. Mount a named volume at /data (see README.md) to survive the container being replaced.
ENTRYPOINT ["/probe.sh"]
