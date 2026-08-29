#!/bin/sh
set -e

# ---------------------------------------------------------------- defaults
: "${DOMAIN:=localhost}"
: "${HOST_PUBLIC_IP:=127.0.0.1}"
: "${RABBIT_USER:=guest}"
: "${RABBIT_PASS:=guest}"
: "${RABBIT_HOST:=rabbitmq}"
: "${RABBIT_VHOST:=/}"
: "${PG_HOST:=postgres}"
: "${PG_PORT:=5432}"
: "${PG_USER:=kamailio}"
: "${PG_PASSWORD:=kamailio}"
: "${PG_DB:=kamailio}"
: "${FREESWITCH_SIP_ADDRESS:=freeswitch:11000}"
: "${KAMAILIO_SHM_MEMORY:=256}"
: "${KAMAILIO_PKG_MEMORY:=16}"

CONF="/etc/kazoo/kamailio/kamailio.cfg"
LOCAL_CFG="/etc/kazoo/kamailio/local.cfg"
DB_SCRIPT="/etc/kazoo/kamailio/db_scripts/kamailio_initdb_postgres.sql"
: "${RABBIT_VHOST:=/}"
KZAMQP_BASE="amqp://${RABBIT_USER}:${RABBIT_PASS}@${RABBIT_HOST}:5672"
if [ -n "$RABBIT_VHOST" ] && [ "$RABBIT_VHOST" != "/" ]; then
    KZAMQP_URI="${KZAMQP_BASE}/${RABBIT_VHOST}"
else
    KZAMQP_URI="$KZAMQP_BASE"
fi
PG_URL="postgres://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DB}"

# ---------------------------------------------------------------- helpers
log() { printf '[kamailio] %s\n' "$*"; }

# Escape sed replacement metacharacters so user-supplied values are safe.
# Replacement is '.'-delimited, so we escape '.' and GNU sed's specials.
sed_escape() {
    printf '%s' "$1" | sed 's/[&\\|#]/\\&/g'
}

# Set one kamailio #!substdef, activating it if it ships commented.  The kazoo
# templates comment the toggleable lines as "# # #!substdef ..." (remove all
# but the last '#' to enable), so we first uncomment the line that defines the
# token, then rewrite its value:
#
#   # # #!substdef "!MY_HOSTNAME!kamailio.2600hz.com!g"
#   ->  #!substdef "!MY_HOSTNAME!<value>!g"
#
# Idempotent: the value between the trailing '!' delimiters is replaced
# regardless of what it currently is.  Assume values contain no '!' (the
# substdef syntax itself cannot represent a literal '!' in the value).
patch_subst() {
    token="$1"
    value="$2"
    file="$3"
    escaped_value=$(sed_escape "$value")
    # activate: strip comment markers from the line that defines this token,
    # keeping the final '#' so the directive stays "#!substdef ..."
    sed -i -E "/!${token}!/{s/^([ #]+)#!/#!/;}" "$file" || true
    # set value: replace everything from the token through the next '!' with
    # the token + new value, leaving the trailing "!g" intact
    sed -i -E "s#(!${token}!)[^!]*#\1${escaped_value}#" "$file" || true
}

wait_for_pg() {
    i=0
    until pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
            log "timed out waiting for PostgreSQL at ${PG_HOST}:${PG_PORT}"
            exit 1
        fi
        sleep 2
    done
    log "PostgreSQL is ready"
}

# The initdb dump (kamailio_initdb_postgres.sql) is a pg_dump of a 12.7
# database: its ALTER TABLE ... OWNER TO kamailio clauses require a login role
# named "kamailio", and psql needs an existing target database.  Bootstrap
# both idempotently before loading the dump.  PG_USER here is a superuser
# (compose maps it to POSTGRES_USER), which is all CREATE ROLE/DATABASE
# require.
ensure_pg_role_db() {
    if ! PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
            -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'kamailio';" | grep -q 1; then
        log "creating postgres role 'kamailio'"
        PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
            -v ON_ERROR_STOP=1 -c "CREATE ROLE kamailio;"
    fi
    if ! PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
            -tAc "SELECT 1 FROM pg_database WHERE datname = '$PG_DB';" | grep -q 1; then
        log "creating postgres database '$PG_DB'"
        PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
            -v ON_ERROR_STOP=1 -c "CREATE DATABASE $PG_DB OWNER kamailio;"
    fi
}

ensure_schema() {
    if PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -tAc "SELECT to_regclass('public.version');" 2>/dev/null | grep -q version; then
        log "kamailio schema already present"
    else
        log "initializing kamailio schema from $DB_SCRIPT"
        PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 -f "$DB_SCRIPT"
    fi
}

seed_dispatcher() {
    # setid 1 -> freeswitch media server.  Prune any stale rows left over from
    # earlier runs (old container/IP values) then (re)insert the canonical
    # destination so dispatcher never sees two rows pointing at the same FS
    # (that caused 480/482 "merged" responses and call loops).
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -c \
        "DELETE FROM dispatcher WHERE setid=1 AND destination <> 'sip:$FREESWITCH_SIP_ADDRESS';
         INSERT INTO dispatcher (setid,destination,flags,priority,attrs,description)
         VALUES (1,'sip:$FREESWITCH_SIP_ADDRESS',0,0,'','freeswitch')
         ON CONFLICT DO NOTHING;"
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -c "DELETE FROM dispatcher WHERE setid <> 1 AND destination::text LIKE 'sip:172.21.%:11000';"
    log "dispatcher setid=1 -> sip:$FREESWITCH_SIP_ADDRESS"
}

# ---------------------------------------------------------------- config
log "patching $LOCAL_CFG"
# MY_IP_ADDRESS selects the interface kamailio binds to; inside the compose
# network that must be a real container address (HOST_PUBLIC_IP from the host
# is not assigned to this container).  MY_EXT_IP_ADDRESS is what gets
# advertised in Via/Contact/Record-Route headers.  The compose stack maps
# KAMAILIO_PUBLIC_IP into HOST_PUBLIC_IP; fall back to the container address
# when it's unset or still the compose default (127.0.0.1).
MY_CONTAINER_IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
: "${MY_CONTAINER_IP:=$HOST_PUBLIC_IP}"
: "${MY_EXT_IP_ADDRESS:=$HOST_PUBLIC_IP}"
: "${MY_EXT_IP_ADDRESS:=$MY_CONTAINER_IP}"
if [ "$MY_EXT_IP_ADDRESS" = "127.0.0.1" ]; then
    MY_EXT_IP_ADDRESS="$MY_CONTAINER_IP"
fi
patch_subst MY_HOSTNAME      "$DOMAIN"               "$LOCAL_CFG"
patch_subst MY_IP_ADDRESS    "$MY_CONTAINER_IP"      "$LOCAL_CFG"
patch_subst MY_EXT_IP_ADDRESS "$MY_EXT_IP_ADDRESS"   "$LOCAL_CFG"
patch_subst MY_AMQP_URL      "$KZAMQP_URI"           "$LOCAL_CFG"
patch_subst KAMAILIO_DBMS    "postgres"              "$LOCAL_CFG"
patch_subst KAZOO_DB_URL     "$PG_URL"               "$LOCAL_CFG"
# AMQP creds also appear as raw substdefs in some config versions
patch_subst AMQP_USER        "$RABBIT_USER"          "$LOCAL_CFG"
patch_subst AMQP_PASSWORD    "$RABBIT_PASS"          "$LOCAL_CFG"
patch_subst AMQP_HOST        "$RABBIT_HOST"          "$LOCAL_CFG"

# Phones on the LAN cannot route to kamailio's docker-bridge address, so the
# Via/Contact/Record-Route must advertise an address reachable from the host
# or in-dialog requests (BYE/ACK) from the phones get dropped.  Add `advertise`
# to the plaintext UDP/TCP listeners (5060 SIP + 7000 media/alg) so kamailio
# presents MY_EXT_IP_ADDRESS in those headers.
[ -n "$MY_EXT_IP_ADDRESS" ] || MY_EXT_IP_ADDRESS="$MY_CONTAINER_IP"
grep -q '!MY_EXT_IP_ADDRESS!' "$LOCAL_CFG" || \
    printf '\n#!substdef "!MY_EXT_IP_ADDRESS!%s!g"\n' "$MY_EXT_IP_ADDRESS" >>"$LOCAL_CFG"
patch_subst MY_EXT_IP_ADDRESS "$MY_EXT_IP_ADDRESS" "$LOCAL_CFG"
for _port in 5060 7000; do
    sed -i \
        -e "s#\!UDP_SIP\!udp:MY_IP_ADDRESS:${_port}\!g#\!UDP_SIP\!udp:MY_IP_ADDRESS:${_port} advertise MY_EXT_IP_ADDRESS:${_port}\!g#" \
        -e "s#\!TCP_SIP\!tcp:MY_IP_ADDRESS:${_port}\!g#\!TCP_SIP\!tcp:MY_IP_ADDRESS:${_port} advertise MY_EXT_IP_ADDRESS:${_port}\!g#" \
        "$LOCAL_CFG" || true
done
log "advertising ${MY_EXT_IP_ADDRESS} on kamailio listen sockets"

# ---------------------------------------------------------------- database
wait_for_pg
ensure_pg_role_db
ensure_schema
seed_dispatcher

# ---------------------------------------------------------------- run
log "starting kamailio: -f $CONF"
exec kamailio -DD -E \
    -u kamailio -g kamailio \
    -m "$KAMAILIO_SHM_MEMORY" -M "$KAMAILIO_PKG_MEMORY" \
    -f "$CONF"