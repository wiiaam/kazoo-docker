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

# ca-certificates has to land BEFORE the kamailio.org HTTPS repo is added
# below. This is a fresh stage with no CA trust store yet (multi-stage builds
# don't carry over installed packages from the build stage, only COPY'd
# files) -- apt-get update against an https source with no ca-certificates
# installed fails TLS verification, and apt doesn't treat that as fatal: it
# just drops that repo's package index and silently falls back to whatever
# *other* configured repo provides the same package name. Debian bullseye's
# own main repo happens to ship a same-named "kamailio" package (5.4.4-1), so
# for months every build here silently installed that instead of the
# higher-versioned deb.kamailio.org one (5.5.7+bpo11) the vendor config
# (kageds/kazoo-configs-kamailio, see POSTGRES.md) was actually written and
# tested against -- no error, because the unpinned install still "succeeded".
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/share/keyrings/kamailio.gpg /usr/share/keyrings/kamailio.gpg
COPY --from=build /etc/apt/sources.list.d/kamailio.list /etc/apt/sources.list.d/kamailio.list
COPY --from=build /etc/kazoo /etc/kazoo

# Runtime-only packages: postgresql-client (psql, used by entrypoint.sh) and
# the kamailio module set itself -- installed against the repo/keyring copied
# in above, now that ca-certificates can actually validate it.
#
# The kamailio packages stay version-pinned so apt can never again silently
# substitute Debian's own build for deb.kamailio.org's -- bump
# KAMAILIO_VERSION deliberately, not by accident.
ARG KAMAILIO_VERSION=5.5.7+bpo11
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    postgresql-client \
    kamailio=${KAMAILIO_VERSION} \
    kamailio-postgres-modules=${KAMAILIO_VERSION} \
    kamailio-kazoo-modules=${KAMAILIO_VERSION} \
    kamailio-outbound-modules=${KAMAILIO_VERSION} \
    kamailio-presence-modules=${KAMAILIO_VERSION} \
    kamailio-tls-modules=${KAMAILIO_VERSION} \
    kamailio-utils-modules=${KAMAILIO_VERSION} \
    kamailio-websocket-modules=${KAMAILIO_VERSION} \
    kamailio-extra-modules=${KAMAILIO_VERSION} \
    kamailio-xmpp-modules=${KAMAILIO_VERSION} \
    && rm -rf /var/lib/apt/lists/*

# nat_traversal writes its keepalive state here; the vendor config assumes a
# real package install already created it, which a from-source build never
# does. kamailio drops privileges to the kamailio user/group at runtime
# (entrypoint.sh's -u/-g flags), so it needs write access too.
RUN mkdir -p /etc/kazoo/kamailio/db \
    && chown kamailio:kamailio /etc/kazoo/kamailio/db

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 5061/udp 5061/tcp 7000/udp 7000/tcp 7001/udp 7001/tcp
ENTRYPOINT ["/entrypoint.sh"]
