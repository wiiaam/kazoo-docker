#!/bin/sh
set -e

# Monster-UI loads its config from js/config.js (AMD define block), which the
# app bundle maps to the module "config". Generate it from env at boot.
#
# The API base defaults to "http://<browser host>:8000/v2/" (upstream
# behavior): the browser talks to the host it loaded the UI from, so the
# config is correct no matter how the UI is reached (localhost or a LAN IP).
# Override with API_URL if you proxy Crossbar behind an LB / custom host.
CONFIG_PATH="/usr/share/nginx/html/js/config.js"
DEFAULT_API_EXPR="'http://' + location.hostname + ':8000/v2/'"
if [ -n "$API_URL" ]; then
    DEFAULT_API_EXPR="'$API_URL'"
fi

{
    printf 'define({\n'
    printf '    api: {\n'
    printf "        'default': %s,\n" "$DEFAULT_API_EXPR"
    printf '        provisioner: false,\n'
    printf '        socket: false\n'
    printf '    },\n'
    printf '    advancedView: true,\n'
    printf "    whitelabel: {\n        companyName: '%s',\n        applicationTitle: '%s'\n    }\n" "$WHITELABEL_NAME" "$APPLICATION_TITLE"
    printf '});\n'
} > "$CONFIG_PATH"

chown nginx:nginx "$CONFIG_PATH"

# If a /shared volume is mounted (kazoo-init compose), copy the app metadata
# (apps/*/app.json) there so kazoo-init can register the Monster-UI apps with
# Crossbar via crossbar_maintenance init_apps. Touch .ready when the copy is
# complete so kazoo-init doesn't register a partial set.
if [ -d /shared ]; then
    mkdir -p /shared/apps
    cp -r /usr/share/nginx/html/apps/. /shared/apps/
    touch /shared/.ready
    echo "monster-ui: copied apps to /shared/apps"
fi

exec nginx -g 'daemon off;'