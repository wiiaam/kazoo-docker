FROM debian:11 AS build

ARG DEBIAN_FRONTEND=noninteractive

# Apt resilience: foreign mirrors (deb.debian.org / deb.kamailio.org) flake on
# CI runners; default retry count is 0, which turns a blip into a hard failure.
RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "20";\n' \
    > /etc/apt/apt.conf.d/99retries

# Build-only tooling: fetches the kamailio signing key and clones the
# community config tree below. None of curl/gnupg/git is needed at runtime,
# so they stay confined to this stage.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    git \
    && rm -rf /var/lib/apt/lists/*

# --- Kamailio 5.5 deb repo key (https + signed-by keyring) -------------------
# The as-served kamailiodebkey.gpg is a legacy-format keyring that apt's strict
# keydb reader cannot parse ("invalid packet (ctb=2d)" -> NO_PUBKEY -> exit 100).
# Import + re-export via gpg normalises it: gpg drops the unparseable legacy
# packets and re-emits the valid signing key(s) as a clean, apt-readable keyring.
RUN mkdir -p /usr/share/keyrings /tmp/kamailio-key \
    && curl -fsSL https://deb.kamailio.org/kamailiodebkey.gpg -o /tmp/kamailio-key/kamailio.gpg \
    && GNUPGHOME=/tmp/kamailio-key gpg --batch --no-tty --import /tmp/kamailio-key/kamailio.gpg \
    && GNUPGHOME=/tmp/kamailio-key gpg --batch --no-tty --export > /usr/share/keyrings/kamailio.gpg \
    && rm -rf /tmp/kamailio-key \
    && printf 'deb [signed-by=/usr/share/keyrings/kamailio.gpg] https://deb.kamailio.org/kamailio55 bullseye main\ndeb-src [signed-by=/usr/share/keyrings/kamailio.gpg] https://deb.kamailio.org/kamailio55 bullseye main\n' \
    > /etc/apt/sources.list.d/kamailio.list

# Community Postgres backend configs (kageds 4.3-postgres): kamailio.cfg + roles
# + db_scripts/kamailio_initdb_postgres.sql
ARG KAMAILIO_CONFIGS_REPO="https://github.com/kageds/kazoo-configs-kamailio.git"
ARG KAMAILIO_CONFIGS_REF="4.3-postgres"
RUN git clone -q -b "$KAMAILIO_CONFIGS_REF" --depth 1 "$KAMAILIO_CONFIGS_REPO" /etc/kazoo

# ---- runtime image ----
FROM debian:11

ARG DEBIAN_FRONTEND=noninteractive

RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "20";\n' \
    > /etc/apt/apt.conf.d/99retries

COPY --from=build /usr/share/keyrings/kamailio.gpg /usr/share/keyrings/kamailio.gpg
COPY --from=build /etc/apt/sources.list.d/kamailio.list /etc/apt/sources.list.d/kamailio.list
COPY --from=build /etc/kazoo /etc/kazoo

# Runtime-only packages: ca-certificates (kamailio-tls-modules), postgresql-client
# (psql, used by entrypoint.sh), and the kamailio module set itself -- installed
# against the repo/keyring copied in above, so no curl/gnupg/git needed here.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    postgresql-client \
    kamailio \
    kamailio-postgres-modules \
    kamailio-kazoo-modules \
    kamailio-outbound-modules \
    kamailio-presence-modules \
    kamailio-tls-modules \
    kamailio-utils-modules \
    kamailio-websocket-modules \
    kamailio-extra-modules \
    kamailio-xmpp-modules \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 5061/udp 5061/tcp 7000/udp 7000/tcp 7001/udp 7001/tcp
ENTRYPOINT ["/entrypoint.sh"]
