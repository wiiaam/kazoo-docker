#!/bin/bash
# Core image entrypoint: shared by kazoo_apps / ecallmgr.
# KAZOO_NODE selects the role and may NOT contain '@' -- it spawns the kazoo
# release; the node name is derived by rel/kazoo as <KAZOO_NODE>@<hostname>,
# so containers must run with a dotted, DNS-resolvable hostname (compose
# `hostname:` / k8s `subdomain`+`hostname`).
#
# KAZOO_BOOTSTRAP: optional path to a post-start provisioning script. When
# set, the node is started in the background, this entrypoint waits for it to
# come up (local `sup` -- note sup builds its target as <name>@<LOCAL host>,
# so provisioning MUST run inside the node's own container), runs the script,
# then re-attaches to the foreground node forever.
set -euo pipefail

: "${KAZOO_NODE:=kazoo_apps}"
: "${ERLANG_COOKIE:?ERLANG_COOKIE must be set}"
: "${RABBIT_USER:?RABBIT_USER must be set}"
: "${RABBIT_PASS:?RABBIT_PASS must be set}"
: "${COUCH_USER:?COUCH_USER must be set}"
: "${COUCH_PASS:?COUCH_PASS must be set}"
: "${RABBIT_HOST:=127.0.0.1}"
: "${COUCH_HOST:=127.0.0.1}"

export RABBIT_USER RABBIT_PASS COUCH_USER COUCH_PASS ERLANG_COOKIE RABBIT_HOST COUCH_HOST
envsubst '${RABBIT_USER} ${RABBIT_PASS} ${ERLANG_COOKIE} ${COUCH_USER} ${COUCH_PASS} ${RABBIT_HOST} ${COUCH_HOST}' \
    < /etc/kazoo/config.ini.template > /etc/kazoo/config.ini

mkdir -p /tmp/erl_pipes /var/log/kazoo /var/run/kazoo
chmod a=rwx /tmp/erl_pipes

printf '%s' "${ERLANG_COOKIE}" > /opt/kazoo/.erlang.cookie
chmod 400 /opt/kazoo/.erlang.cookie

export HOME=/opt/kazoo
export KAZOO_ROOT=/opt/kazoo
export KAZOO_NODE
export KAZOO_COOKIE="${ERLANG_COOKIE}"
export KAZOO_CONFIG=/etc/kazoo/config.ini
export CODE_LOADING_MODE=interactive
export ERL_CRASH_DUMP="/var/log/kazoo/$(date +%s)_${KAZOO_NODE//@/_}_erl_crash.dump"

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

KAZOO_ROLE="${KAZOO_NODE%%@*}"

if [ -n "${KAZOO_BOOTSTRAP:-}" ] && [ -f "${KAZOO_BOOTSTRAP}" ]; then
    echo "entrypoint: starting ${KAZOO_ROLE} node in background"
    /opt/kazoo/bin/kazoo foreground &
    KAZOO_PID=$!
    echo "entrypoint: waiting for ${KAZOO_ROLE} node to come up..."
    until sup -n "${KAZOO_ROLE}" kz_nodes status >/dev/null 2>&1; do
        sleep 3
    done
    echo "entrypoint: node is up, running ${KAZOO_BOOTSTRAP}"
    "${KAZOO_BOOTSTRAP}"
    echo "entrypoint: bootstrap finished"
    wait "${KAZOO_PID}"
    exit $?
fi

exec /opt/kazoo/bin/kazoo foreground