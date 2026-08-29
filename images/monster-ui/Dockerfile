FROM nginx:stable-alpine

# Kazoo Classic Monster-UI 4.3 (allapps bundle) served by nginx.
# API_URL omitted on purpose: entrypoint.sh defaults to the browser host
# ("http://<host>:8000/v2/"); a baked-in value would override that default.
ENV WHITELABEL_NAME="Kazoo" \
    APPLICATION_TITLE="Kazoo"

ARG MONSTER_UI_TARBALL_URL="https://github.com/kazoo-classic/monster-ui/releases/download/v4.3.1-allapps/monster-ui-4.3.c1-allapps.tar.gz"

RUN apk add --no-cache curl \
    && curl -fsSL -o /tmp/monster-ui.tgz "$MONSTER_UI_TARBALL_URL" \
    && tar xzf /tmp/monster-ui.tgz -C /usr/share/nginx/html --strip-components=1 \
    && rm -f /tmp/monster-ui.tgz \
    && chown -R nginx:nginx /usr/share/nginx/html

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]