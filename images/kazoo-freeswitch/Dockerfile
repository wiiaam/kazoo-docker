# kazoo-freeswitch: FreeSWITCH 1.10.9 + freeswitch-mod-kazoo, compiled from
# source on Debian 11 (as kazoo-classic documents). No SignalWire apt repo and
# no token required. 1.10.9 is pinned deliberately: newer FreeSWITCH breaks
# classic Kazoo AMQP event handling, and the SignalWire apt repos no longer
# ship the 1.10.9 bits anyway (bullseye rotated them for 1.10.12/1.11.x).
#
# mod_kazoo is built in-tree via modules.conf (event_handlers/mod_kazoo),
# matching the SignalWire freeswitch-mod-kazoo package for 1.10.9.
#
# Since 1.10.x FreeSWITCH does not bundle spandsp/sofia-sip; configure demands
# spandsp >= 3.0 and sofia-sip-ua >= 1.13.12, which Debian 11 does not ship
# (0.0.6 / 1.12.11). Build both from upstream first.

FROM debian:11 AS build

ARG SOUNDS_VERSION=1.0.53

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential automake autoconf libtool libtool-bin autoconf-archive pkg-config gawk git wget \
      ca-certificates yasm \
      libssl-dev libedit-dev libsqlite3-dev libpcre3-dev uuid-dev \
      libcurl4-openssl-dev libtiff-dev \
      libsofia-sip-ua-dev libspandsp-dev libspeex-dev libspeexdsp-dev \
      libopus-dev libsndfile1-dev libogg-dev libvorbis-dev libjpeg62-turbo-dev \
      libsoundtouch-dev libshout3-dev libmpg123-dev libmp3lame-dev \
      libopencore-amrnb-dev libopencore-amrwb-dev \
      libavcodec-dev libavformat-dev libavutil-dev libswscale-dev \
      erlang-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/deps
RUN git clone --depth 1 https://github.com/freeswitch/spandsp.git \
 && cd spandsp \
 && ./bootstrap.sh && ./configure && make -j"$(nproc)" && make install \
 && cd .. \
 && git clone --depth 1 https://github.com/freeswitch/sofia-sip.git \
 && cd sofia-sip \
 && ./bootstrap.sh && ./configure && make -j"$(nproc)" && make install \
 && ldconfig

WORKDIR /usr/src
RUN git clone --depth 1 --branch v1.10.9 \
      https://github.com/signalwire/freeswitch.git freeswitch

COPY modules.conf /usr/src/freeswitch/modules.conf

WORKDIR /usr/src/freeswitch
RUN ./bootstrap.sh -j \
 && ./configure \
 && make -j"$(nproc)" \
 && make install

# mod_kazoo is built in-tree (event_handlers/mod_kazoo via modules.conf), the
# same source SignalWire packages for the 1.10.9 apt builds. The standalone
# freeswitch/mod_kazoo master (used before) corrupts memory -- double-free at
# sofia profile start / ACL rebuild -- so it is removed.

# Kazoo plays back the "callie" prompt set (public tarball from the old
# files.freeswitch.org mirror, no token). 8k is the rate Kazoo serves to
# endpoints; the tarball extracts to en/us/callie/ under the sounds dir.
RUN mkdir -p /usr/local/freeswitch/sounds \
 && wget -qO- "https://files.freeswitch.org/releases/sounds/freeswitch-sounds-en-us-callie-8000-${SOUNDS_VERSION}.tar.gz" \
      | tar -xz -C /usr/local/freeswitch/sounds

# Kazoo's upstream config tree for FreeSWITCH (upstream 4.3), cloned here
# rather than in the runtime stage so the runtime image doesn't need git.
WORKDIR /opt/kazoo-configs-freeswitch
RUN git clone --depth 1 --branch 4.3 \
      https://github.com/2600hz/kazoo-configs-freeswitch repo \
 && mkdir -p /etc/kazoo/freeswitch \
 && cp -a repo/freeswitch/. /etc/kazoo/freeswitch/ \
 && rm -rf repo

# ---- runtime image ----
FROM debian:11

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libsofia-sip-ua0 libspandsp2 libsndfile1 libopus0 libogg0 libvorbis0a \
      libspeex1 libspeexdsp1 libsqlite3-0 libedit2 libpcre3 libcurl4 libssl1.1 libpcre2-8-0 \
      libsoundtouch1 libmpg123-0 libmp3lame0 libshout3 \
      libopencore-amrnb0 libopencore-amrwb0 \
      libavcodec58 libavformat58 libswresample3 libavutil56 libswscale5 \
      libjpeg62-turbo \
      util-linux openssl ca-certificates adduser erlang-nox \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/freeswitch /usr/local/freeswitch

# mod_spandsp/mod_sofia link against the source-built spandsp (3.1.1) and
# sofia-sip (1.13.x), which land in /usr/local/lib -- Debian's packaged
# libspandsp2/libsofia-sip-ua0 are older ABI and would break dlopen.
COPY --from=build /usr/local/lib /usr/local/lib
RUN ldconfig

RUN useradd --system --home-dir /var/lib/kazoo-freeswitch --create-home freeswitch

# Kazoo config tree (upstream 4.3), cloned in the build stage above. Our
# templates/ are laid over it: the upstream files hold static values; the
# templates substitute env-driven placeholders that entrypoint.sh renders at
# boot.
COPY --from=build /etc/kazoo/freeswitch/ /etc/kazoo/freeswitch/
RUN chown -R root:root /etc/kazoo/freeswitch

COPY templates/autoload_configs/ /etc/kazoo/freeswitch/autoload_configs/
COPY templates/sip_profiles/ /etc/kazoo/freeswitch/sip_profiles/

# Kazoo expects sounds at /usr/share/kazoo-freeswitch/sounds.
RUN mkdir -p /usr/share/kazoo-freeswitch \
 && ln -s /usr/local/freeswitch/sounds /usr/share/kazoo-freeswitch/sounds

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER root
ENTRYPOINT ["/entrypoint.sh"]