FROM debian:11

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    git \
    postgresql-client \
    && mkdir -p /usr/share/keyrings \
    && curl -fsSL https://deb.kamailio.org/kamailiodebkey.gpg -o /usr/share/keyrings/kamailio.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/kamailio.gpg] http://deb.kamailio.org/kamailio55 bullseye main" > /etc/apt/sources.list.d/kamailio.list \
    && echo "deb-src [signed-by=/usr/share/keyrings/kamailio.gpg] http://deb.kamailio.org/kamailio55 bullseye main" >> /etc/apt/sources.list.d/kamailio.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
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

# Community Postgres backend configs (kageds 4.3-postgres): kamailio.cfg + roles
# + db_scripts/kamailio_initdb_postgres.sql
ARG KAMAILIO_CONFIGS_REPO="https://github.com/kageds/kazoo-configs-kamailio.git"
ARG KAMAILIO_CONFIGS_REF="4.3-postgres"
RUN git clone -q -b "$KAMAILIO_CONFIGS_REF" --depth 1 "$KAMAILIO_CONFIGS_REPO" /etc/kazoo

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5060/tcp 5061/udp 5061/tcp 7000/udp 7000/tcp 7001/udp 7001/tcp
ENTRYPOINT ["/entrypoint.sh"]