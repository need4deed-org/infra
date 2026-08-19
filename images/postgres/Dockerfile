# archive_command runs as a child of the postmaster, so pgBackRest has to be in
# the postgres image itself. No sidecar, Job or operator can supply it.
FROM postgres:17@sha256:a426e44bac0b759c95894d68e1a0ac03ecc20b619f498a91aae373bf06d8508d

# From the PGDG apt repo that postgres:17 already has configured.
ARG PGBACKREST_VERSION=2.59.0-1.pgdg13+1

# curl: postgres:17 ships neither curl nor wget, and the backup CronJob needs
# one for the Slack alert and the dead man's switch ping.
# ca-certificates: explicitly, because --no-install-recommends drops it (it is
# only a recommends of curl) and without it every TLS peer - the S3 gateway
# included - fails verification as self-signed.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        "pgbackrest=${PGBACKREST_VERSION}" \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
