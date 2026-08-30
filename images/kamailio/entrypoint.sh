#!/bin/sh
set -e

# ---------------------------------------------------------------- defaults
: "${DOMAIN:=localhost}"
# What kamailio advertises in Via/Contact/Record-Route -- the address other
# SIP UAs (phones, FreeSWITCH) will actually try to reach. Must be a real,
# routable address for whoever is calling in; 127.0.0.1 only works for
# same-host testing.
: "${ADVERTISE_IP:=127.0.0.1}"
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
sed_escape() {
    printf '%s' "$1" | sed 's/[&\\|#]/\\&/g'
}

# Set one kamailio #!substdef, activating it if it ships commented. Vendor
# templates ship toggleable lines as "# # #!substdef ..." (strip all but the
# last '#' to enable):
#
#   # # #!substdef "!MY_HOSTNAME!kamailio.2600hz.com!g"
#   ->  #!substdef "!MY_HOSTNAME!<value>!g"
#
# Idempotent: replaces the value between the trailing '!' delimiters
# regardless of what's currently there. Assumes values contain no '!'.
#
# NOTE: token names here (MY_HOSTNAME, MY_IP_ADDRESS, etc.) are Kamailio's
# own vendor config tokens from Kazoo Classic's local.cfg template -- not
# something this script invented. Renaming them would mean patching the
# .cfg templates themselves, not just this script.
patch_subst() {
    token="$1"
    value="$2"
    file="$3"
    escaped_value=$(sed_escape "$value")
    sed -i -E "/!${token}!/{s/^([ #]+)#!/#!/;}" "$file" || true
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
# database: its ALTER TABLE ... OWNER TO kamailio clauses require a login
# role named "kamailio", and psql needs an existing target database.
# Bootstrap both idempotently before loading the dump. PG_USER here is a
# superuser (compose maps it to POSTGRES_USER), which is all CREATE
# ROLE/DATABASE require.
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

# setid 1 -> freeswitch media server. Always reconcile to exactly the
# current FREESWITCH_SIP_ADDRESS so a stale row from a previous run (old
# container IP, old hostname) never sits alongside the current one --
# duplicate rows pointing at "the same" destination under different
# addresses caused 480/482 "merged" responses and call loops.
seed_dispatcher() {
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DB" \
        -v ON_ERROR_STOP=1 -c \
        "DELETE FROM dispatcher WHERE setid=1 AND destination <> 'sip:$FREESWITCH_SIP_ADDRESS';
         INSERT INTO dispatcher (setid,destination,flags,priority,attrs,description)
         VALUES (1,'sip:$FREESWITCH_SIP_ADDRESS',0,0,'','freeswitch')
         ON CONFLICT DO NOTHING;"
    log "dispatcher setid=1 -> sip:$FREESWITCH_SIP_ADDRESS"
}

# ---------------------------------------------------------------- config
log "patching $LOCAL_CFG"

# BIND_IP is the address kamailio listens on inside its own network
# namespace (container/pod IP) -- not necessarily reachable by anyone else.
# ADVERTISE_IP is what gets put in Via/Contact/Record-Route so remote UAs
# know where to actually send packets back. These are the same value only
# when kamailio is directly reachable at its own bind address (e.g. host
# networking, or a macvlan/real LAN IP) -- behind any NAT, LB, or bridged
# network they differ, and getting ADVERTISE_IP wrong is what breaks
# in-dialog requests (ACK/BYE) since those route using the advertised
# Contact, not the original bind address.
# BIND_IP: what kamailio binds its listeners to.
#   empty (default) -> 0.0.0.0, i.e. bind on ALL interfaces -- always safe.
#              Binding a specific address (esp. the IPv6 ULA that `hostname -i`
#              lists first on dual-stack k8s pods) can fail with "Cannot
#              assign requested address" + crashloop on a v4-only underlay.
#   0.0.0.0  -> all IPv4 interfaces    [::] -> all IPv6 interfaces
#   dual     -> both stacks (IPv4 all, IPv6 [::] sockets appended below)
#   <addr>   -> that one address (advanced / plain-IP hosts only)
: "${BIND_IP:=0.0.0.0}"

BIND_IP_V6=""
if [ "$BIND_IP" = "dual" ]; then
    BIND_IP="0.0.0.0"
    BIND_IP_V6="[::]"
fi
if [ "$BIND_IP" = "::" ]; then
    BIND_IP="[::]"
fi
if [ "$ADVERTISE_IP" = "127.0.0.1" ]; then
    ADVERTISE_IP="$BIND_IP"
fi

patch_subst MY_HOSTNAME       "$DOMAIN"       "$LOCAL_CFG"
patch_subst MY_IP_ADDRESS     "$BIND_IP"      "$LOCAL_CFG"
patch_subst MY_EXT_IP_ADDRESS "$ADVERTISE_IP" "$LOCAL_CFG"
patch_subst MY_AMQP_URL       "$KZAMQP_URI"   "$LOCAL_CFG"
patch_subst KAMAILIO_DBMS     "postgres"      "$LOCAL_CFG"
patch_subst KAZOO_DB_URL      "$PG_URL"       "$LOCAL_CFG"
patch_subst AMQP_USER         "$RABBIT_USER"  "$LOCAL_CFG"
patch_subst AMQP_PASSWORD     "$RABBIT_PASS"  "$LOCAL_CFG"
patch_subst AMQP_HOST         "$RABBIT_HOST"  "$LOCAL_CFG"

# Callers can't route to BIND_IP when it isn't their externally-reachable
# address, so the plaintext UDP/TCP listeners need an explicit `advertise`
# clause -- without it, Via/Contact/Record-Route would carry BIND_IP instead
# of ADVERTISE_IP and in-dialog requests (ACK/BYE) from real clients get
# dropped.
grep -q '!MY_EXT_IP_ADDRESS!' "$LOCAL_CFG" || \
    printf '\n#!substdef "!MY_EXT_IP_ADDRESS!%s!g"\n' "$ADVERTISE_IP" >>"$LOCAL_CFG"
patch_subst MY_EXT_IP_ADDRESS "$ADVERTISE_IP" "$LOCAL_CFG"
for _port in 5060 7000; do
    sed -i \
        -e "s#\!UDP_SIP\!udp:MY_IP_ADDRESS:${_port}\!g#\!UDP_SIP\!udp:MY_IP_ADDRESS:${_port} advertise ${ADVERTISE_IP}:${_port}\!g#" \
        -e "s#\!TCP_SIP\!tcp:MY_IP_ADDRESS:${_port}\!g#\!TCP_SIP\!tcp:MY_IP_ADDRESS:${_port} advertise ${ADVERTISE_IP}:${_port}\!g#" \
        "$LOCAL_CFG" || true
done

# BIND_IP=dual: additionally listen on [::] (all IPv6) for the SIP + WS ports.
# Appended listen= lines are processed like any other in the main config, so
# the v4 (0.0.0.0) and v6 sockets coexist on the same ports.
if [ -n "$BIND_IP_V6" ]; then
    log "adding IPv6 listeners on ${BIND_IP_V6}"
    {
        printf '\n# dual-stack IPv6 listeners (BIND_IP=dual)\n'
        for _port in 5060 7000; do
            printf 'listen=udp:%s:%s advertise %s:%s\n' "$BIND_IP_V6" "$_port" "$ADVERTISE_IP" "$_port"
            printf 'listen=tcp:%s:%s advertise %s:%s\n' "$BIND_IP_V6" "$_port" "$ADVERTISE_IP" "$_port"
        done
    } >>"$LOCAL_CFG"
fi
log "advertising ${ADVERTISE_IP} on kamailio listen sockets"

# When BIND_IP and ADVERTISE_IP differ (any NAT/bridge/LB in front of
# kamailio -- not just Docker Desktop), the TCP flow kamailio reuses for
# in-dialog BYE/ACK has its local socket bound to BIND_IP while
# Via/Record-Route advertise ADVERTISE_IP. With tcp_accept_aliases=no, the
# connection lookup that feeds t_relay fails to match the existing flow
# (local IP differs from the advertised dst) and in-dialog requests die
# with 481 "Call/Transaction Does Not Exist" -- the phone never gets the
# ACK and FreeSWITCH tears the call down with 408 ACK Timeout. Enabling it
# lets kamailio reuse the established flow for in-dialog messages, same as
# out-of-dialog routing already does via +sip.instance. default.cfg owns
# the value and is included after local.cfg, so patch it directly
# (idempotent).
DEFAULT_CFG="$(dirname "$CONF")/default.cfg"
sed -i 's#^tcp_accept_aliases = no$#tcp_accept_aliases = yes#' "$DEFAULT_CFG"
log "tcp_accept_aliases enabled (reuse flow TCP for in-dialog requests)"

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