FROM rockylinux:8

# Kazoo Classic 4.3 Erlang core. The RPMs ship the OTP-19.3 release tree at
# /opt/kazoo (bin/kazoo, bin/sup, erts-8.3). One image, three runtime roles,
# selected by the KAZOO_NODE env (kazoo_apps | ecallmgr | kazoo-init).
ARG KAZOO_RELEASE_TAG="v4.3-2-alpha"
ARG RELEASE_BASE="https://github.com/kazoo-classic/kazoo/releases/download/${KAZOO_RELEASE_TAG}"

RUN dnf install -y --setopt=install_weak_deps=False epel-release \
    && dnf install -y --setopt=install_weak_deps=False gettext tar curl \
    && curl -fsSL -o /tmp/erlang.rpm "$RELEASE_BASE/erlang-otp-19.3-1.el8.x86_64.rpm" \
    && curl -fsSL -o /tmp/rebar.rpm   "$RELEASE_BASE/rebar-2.6.4-1.el8.x86_64.rpm" \
    && curl -fsSL -o /tmp/elixir.rpm  "$RELEASE_BASE/elixir-1.5.3-1.el8.x86_64.rpm" \
    && curl -fsSL -o /tmp/kazoo.rpm   "$RELEASE_BASE/kazoo-classic-4.3-2.el8.x86_64.rpm" \
    && dnf install -y --setopt=install_weak_deps=False /tmp/erlang.rpm /tmp/rebar.rpm /tmp/elixir.rpm \
    && dnf install -y --setopt=install_weak_deps=False /tmp/kazoo.rpm \
    && rm -f /tmp/*.rpm \
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN mkdir -p /var/log/kazoo /var/run/kazoo

COPY config.ini.template /etc/kazoo/config.ini.template
COPY entrypoint.sh /entrypoint.sh
COPY kazoo-init.sh /kazoo-init.sh

RUN chmod +x /entrypoint.sh /kazoo-init.sh

EXPOSE 8000 4369
ENTRYPOINT ["/entrypoint.sh"]