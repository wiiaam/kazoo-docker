#!/bin/bash
# Entrypoint for the kazoo-freeswitch image (SignalWire freeswitch 1.10.9 +
# freeswitch-mod-kazoo). Renders the env-driven placeholders in the layered
# templates under /etc/kazoo/freeswitch, then execs FreeSWITCH as PID 1.
#
# Bridge/K8s-safe defaults: services reach each other by DNS name, so
# KZ_AMQP_HOST defaults to the compose service name (rabbitmq); sip-ip/rtp-ip
# in the sofia profile bind via FreeSWITCH's own $${local_ip_v4}
# auto-detection, and the event socket listens on 0.0.0.0 (ecallmgr connects
# to it over the network).
set -euo pipefail

: "${ERLANG_COOKIE:?ERLANG_COOKIE must be set}"
: "${RABBIT_USER:?RABBIT_USER must be set}"
: "${RABBIT_PASS:?RABBIT_PASS must be set}"


# Must be freeswitch@<dotted fqdn>: Erlang long-name dist (shortname=false)
# requires a dot in the host portion, and kazoo's kz_dist.erl special-cases a
# node literally named "freeswitch". Compose sets `hostname:` to a dotted
# alias so `hostname -f` here matches what ecallmgr sees. On Kubernetes the
# pod hostname is set via KAZOO_NODENAME because k8s pod hostnames are
# single labels -- set spec.hostname/subdomain + headless Service to make
# "<node>.kazoo" DNS-resolvable, then pass the same name explicitly here.
: "${KAZOO_NODENAME:=freeswitch@$(hostname -f)}"
KAZOO_PORT="${KAZOO_PORT:-8031}"
EVENT_BIND_IP="${EVENT_BIND_IP:-0.0.0.0}"
EVENT_PORT="${EVENT_PORT:-8021}"
SIP_PORT="${SIP_PORT:-11000}"
RTP_START_PORT="${RTP_START_PORT:-16384}"
RTP_END_PORT="${RTP_END_PORT:-32768}"
FS_USER="${FS_USER:-freeswitch}"
FS_BIN="${FS_BIN:-/usr/local/freeswitch/bin/freeswitch}"
FS_CONFIG="${FS_CONFIG:-/etc/kazoo/freeswitch}"
FS_HOME="${FS_HOME:-/var/lib/kazoo-freeswitch}"
FS_PID="${FS_PID:-/var/run/freeswitch/freeswitch.pid}"

# FreeSWITCH<->RabbitMQ direct AMQP channel (env-set in kazoo.conf.xml).
KZ_AMQP_HOST="${KZ_AMQP_HOST:-rabbitmq}"
KZ_AMQP_PORT="${KZ_AMQP_PORT:-5672}"
KZ_AMQP_VHOST="${KZ_AMQP_VHOST:-/}"
KZ_AMQP_USER="${KZ_AMQP_USER:-$RABBIT_USER}"
KZ_AMQP_PASS="${KZ_AMQP_PASS:-$RABBIT_PASS}"
KZ_AMQP_ZONE="${KZ_AMQP_ZONE:-local}"
export KZ_AMQP_HOST KZ_AMQP_PORT KZ_AMQP_VHOST KZ_AMQP_USER KZ_AMQP_PASS KZ_AMQP_ZONE

export HOME="$FS_HOME"

render() {
  sed -i -e "s/KAZOO_PORT/${KAZOO_PORT}/g" \
         -e "s/KAZOO_COOKIE/${ERLANG_COOKIE}/g" \
         -e "s/KAZOO_NODENAME/${KAZOO_NODENAME}/g" \
         -e "s/EVENT_BIND_IP/${EVENT_BIND_IP}/g" \
         -e "s/EVENT_PORT/${EVENT_PORT}/g" \
         -e "s/SIP_PORT/${SIP_PORT}/g" \
         -e "s/RTP_START_PORT/${RTP_START_PORT}/g" \
         -e "s/RTP_END_PORT/${RTP_END_PORT}/g" \
         "${FS_CONFIG}/autoload_configs/kazoo.conf.xml" \
         "${FS_CONFIG}/autoload_configs/event_socket.conf.xml" \
         "${FS_CONFIG}/autoload_configs/switch.conf.xml"
}

echo "=================================================="
echo " kazoo-docker-freeswitch startup"
echo "=================================================="
echo " > KAZOO_NODENAME      : ${KAZOO_NODENAME}"
echo " > KAZOO_COOKIE        : ${ERLANG_COOKIE}"
echo " > KAZOO_PORT (erlang) : ${KAZOO_PORT}"
echo " > EVENT_BIND_IP/PORT  : ${EVENT_BIND_IP}:${EVENT_PORT} (ESL)"
echo " > SIP_PORT            : ${SIP_PORT}"
echo " > RTP_START/END_PORT  : ${RTP_START_PORT}-${RTP_END_PORT}"
echo " > KZ_AMQP_HOST/PORT   : ${KZ_AMQP_HOST}:${KZ_AMQP_PORT}"
echo " > FS_CONFIG           : ${FS_CONFIG}"
echo " > FS_HOME             : ${FS_HOME}"
echo "=================================================="

render

# sofia's SIP UA creation reads wss.pem from tls-cert-dir unconditionally,
# even with tls=false -- a missing file kills the whole sipinterface_1
# profile ("Bad WSS.PEM certificate"). Generate a self-signed one on every
# boot (containers are ephemeral; mount a real cert to replace it).
CERTS_DIR="${FS_CONFIG}/certs"
mkdir -p "$CERTS_DIR"
if [ ! -s "${CERTS_DIR}/wss.pem" ]; then
  echo ">>> No WSS certificate at ${CERTS_DIR}/wss.pem, generating a self-signed one..."
  openssl req -x509 -newkey rsa:2048 -keyout /tmp/wss.key -out /tmp/wss.crt \
    -days 3650 -nodes -subj "/CN=$(hostname -f)"
  cat /tmp/wss.crt /tmp/wss.key > "${CERTS_DIR}/wss.pem"
  rm -f /tmp/wss.key /tmp/wss.crt
fi
chown -R "${FS_USER}" "$CERTS_DIR"

echo ">>> Preparing directories..."
mkdir -p /var/log/freeswitch "${FS_HOME}"/db "${FS_HOME}"/cache "${FS_HOME}"/storage \
  /usr/share/kazoo-freeswitch/sounds /var/run/freeswitch
chown -R "${FS_USER}" /var/log/freeswitch "${FS_HOME}" \
  /usr/share/kazoo-freeswitch/sounds /var/run/freeswitch
rm -f "${FS_PID}"

echo ">>> Ensuring epmd is running (Erlang distribution node lookup)..."
EPMD_BIN=$(command -v epmd || find /usr/lib/erlang/bin /usr/local/bin /usr/bin /opt -name epmd 2>/dev/null | head -1)
if [ -z "$EPMD_BIN" ]; then
  echo "[ERROR] epmd not found in image!" >&2
  exit 1
fi
if "$EPMD_BIN" -names >/dev/null 2>&1; then
  echo "    epmd already running"
else
  "$EPMD_BIN" -daemon
  sleep 2
  "$EPMD_BIN" -names >/dev/null 2>&1 || { echo "[ERROR] epmd did not start" >&2; exit 1; }
  echo "    epmd started"
fi

FREESWITCH_ARGS="-nonat -conf ${FS_CONFIG} -run /var/run/freeswitch -db ${FS_HOME}/db -log /var/log/freeswitch -cache ${FS_HOME}/cache -sounds /usr/share/kazoo-freeswitch/sounds -storage ${FS_HOME}/storage"

echo ""
echo "=================================================="
echo " Starting FreeSWITCH"
echo "    ARGS: ${FREESWITCH_ARGS}"
echo "=================================================="
cd "${FS_HOME}"
if [ "$(whoami)" = "${FS_USER}" ]; then
  exec "${FS_BIN}" ${FREESWITCH_ARGS}
else
  # `exec` inside the -c string so bash replaces itself with freeswitch as
  # PID 1 -- otherwise SIGTERM to the container never reaches FreeSWITCH.
  exec runuser -s /bin/bash "${FS_USER}" -c "exec ${FS_BIN} ${FREESWITCH_ARGS}"
fi