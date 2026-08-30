#!/bin/bash
# Post-start provisioning for the kazoo_apps node: refresh system DBs/views
# and create the master account. Runs INSIDE the kazoo_apps container, at
# boot, from entrypoint.sh when KAZOO_BOOTSTRAP=/kazoo-init.sh.
#
# sup builds its target as <name>@<LOCAL hostname> (see core/sup/src/sup.erl
# build_target/2), so these calls ALWAYS target the local node role
#  "-n ${KAZOO_ROLE}". Cross-container `sup` is therefore not possible; the
# entrypoint backgrounds the node first, waits for it, and runs us here.
#
# Idempotent: safe to re-run against an already-initialized deployment.
set -euo pipefail

: "${MASTER_ACCOUNT_NAME:?MASTER_ACCOUNT_NAME must be set}"
: "${MASTER_REALM:?MASTER_REALM must be set}"
: "${MASTER_USER:?MASTER_USER must be set}"
: "${MASTER_PASS:?MASTER_PASS must be set}"
: "${CROSSBAR_API_URL:?CROSSBAR_API_URL must be set}"
: "${FS_NODE_NAME:=freeswitch@freeswitch.kazoo}"
: "${COUCH_USER:?COUCH_USER must be set}"
: "${COUCH_PASS:?COUCH_PASS must be set}"
: "${COUCH_HOST:=127.0.0.1}"

KAZOO_ROLE="${KAZOO_NODE%%@*}"
SUP_NODE="${SUP_NODE:-${KAZOO_ROLE:-kazoo_apps}}"
echo "kazoo-init: target sup node = ${SUP_NODE} (local)"

# ecallmgr only connects to FreeSWITCH nodes listed in the `ecallmgr`
# system_config doc's "fs_nodes" key (see ecallmgr_fs_nodes:start_preconfigured_servers).
# Without it a freshly seeded DB has ecallmgr retrying the default node name
# (freeswitch@<ecallmgr's own host>) forever and every call fails "All Servers
# Busy". Seed it idempotently against couch.
ensure_ecallmgr_fs_nodes() {
  local couch="http://${COUCH_USER}:${COUCH_PASS}@${COUCH_HOST}:5984"
  local doc
  doc=$(curl -sf "${couch}/system_config/ecallmgr" || true)
  if [ -z "${doc}" ]; then
    echo "kazoo-init: system_config/ecallmgr not present yet; skipping fs_nodes seed"
    return 0
  fi
  if printf '%s' "${doc}" | grep -q '"fs_nodes"'; then
    echo "kazoo-init: ecallmgr fs_nodes already configured"
    return 0
  fi
printf '%s' "${doc}" \
      | sed "0,/\"default\": *{/s//\"default\": {\n        \"fs_nodes\": [ \"${FS_NODE_NAME}\" ],/" \
      | curl -sf -X PUT -H "Content-Type: application/json" --data-binary @- "${couch}/system_config/ecallmgr" \
      && echo "kazoo-init: seeded ecallmgr fs_nodes" \
      || echo "kazoo-init: WARNING - failed to seed ecallmgr fs_nodes"
}

echo "kazoo-init: waiting for ${SUP_NODE} to come up..."
until sup -n "${SUP_NODE}" kz_nodes status >/dev/null 2>&1; do
  sleep 3
done

echo "kazoo-init: running kapps_maintenance refresh (creates/updates system DBs + views)..."
# The first boot is racy: refresh can start while the node is still bringing up
# kazoo_datamgr (kzs_doc:open_doc function_clause on system_data). Retry --
# the maintenance step is idempotent, and once the node is fully booted it
# succeeds.
refresh_ok=0
for i in $(seq 1 20); do
  if sup -n "${SUP_NODE}" kapps_maintenance refresh; then
    refresh_ok=1
    break
  fi
  echo "kazoo-init: refresh attempt ${i} failed (node still booting?), retrying in 10s..."
  sleep 10
done
if [ "$refresh_ok" != 1 ]; then
  echo "kazoo-init: kapps_maintenance refresh never succeeded; aborting" >&2
  exit 1
fi

echo "kazoo-init: ensuring ecallmgr knows the FreeSWITCH node (fs_nodes)..."
ensure_ecallmgr_fs_nodes

echo "kazoo-init: creating master account (if it doesn't already exist)..."
sup -n "${SUP_NODE}" crossbar_maintenance create_account \
  "${MASTER_ACCOUNT_NAME}" "${MASTER_REALM}" "${MASTER_USER}" "${MASTER_PASS}" || \
  echo "kazoo-init: create_account failed/already exists -- continuing"

# Registers Monster UI's apps (callflows, resources, rates, callcenter,
# whitelabel, addressbooks, registrations) with Crossbar. `init_apps` needs
# local filesystem access to each app's metadata/app.json, which the
# monster-ui service copies into the shared /shared/apps volume. Skipped
# entirely if that volume isn't mounted.
SHARED_APPS_DIR=/shared/apps
if [ -d /shared ]; then
  echo "kazoo-init: waiting for Monster UI apps to be copied to ${SHARED_APPS_DIR}..."
  until [ -f /shared/.ready ]; do
    sleep 2
  done
  echo "kazoo-init: registering Monster UI apps with Crossbar (${CROSSBAR_API_URL})..."
  sup -n "${SUP_NODE}" crossbar_maintenance init_apps "${SHARED_APPS_DIR}" "${CROSSBAR_API_URL}"
else
  echo "kazoo-init: no shared Monster UI apps volume mounted, skipping app registration"
fi

echo "kazoo-init: done."