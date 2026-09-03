# AGENTS.md — Kazoo Classic 4.3 docker stack

Working knowledge for agents operating on this repo.

## Goal & status

- **Goal**: a Dockerized **Kazoo Classic 4.3** stack (community hard-fork of
  2600Hz Kazoo v4.3), deployable both via `compose.yaml` (single-host dev/lab)
  and the `charts/kazoo` Helm chart (Kubernetes, the production target).
- **Status**: both topologies are validated. Device-to-device SIP calls work
  end-to-end (ring, answer, two-way audio, clean hangup) on a live k8s
  deployment — not just compose. A carrier SIP trunk (BYOC resource,
  registration-based, not IP-ACL) registers and places outbound calls
  successfully; see "SIP profile serving & carrier trunk registration" below
  for the mechanism, since it required a real architecture change (FreeSWITCH's
  SIP profile is now served dynamically by ecallmgr, not baked into the image).
  Inbound DID delivery through that trunk is still being chased down, but it's
  been isolated to the *carrier's own* platform (their call dies internally
  before ever generating a leg toward this stack) — not a bug in this repo.

## Pinned versions

- CouchDB **3.2.3** (official image) · RabbitMQ **3.13.7** (official) ·
  PostgreSQL **13** (official) · Kazoo-Applications **4.3 / OTP 19.3**
  (kazoo-classic release, `rockylinux:8`) · FreeSWITCH **1.10.9 + mod_kazoo**
  (built from source, `debian:11`) · Kamailio **5.5.7 + PostgreSQL**
  (`debian:11`) · Monster-UI **4.3** (allapps tarball, nginx:alpine).
- Builds are source-based; no third-party package tokens required.

## Layout

- `compose.yaml` — the 8-service bridge-network stack (couchdb, rabbitmq,
  postgres, kazoo-apps, monster-ui, ecallmgr, kamailio, freeswitch). Container
  hostnames are dotted (`<svc>.kazoo`) and map 1:1 to k8s hostname/subdomain
  (Kubernetes is the production target).
- `.env` / `.env.example` — shared secret/cookie domain across all services.
  `.env` is gitignored; `.env.example` documents every var (incl. realm,
  master-account creds, and the advertised public-IP vars `KAMAILIO_PUBLIC_IP`/
  `FS_PUBLIC_IP`).
- `images/<name>/` — one image per stack component:
  - `kazoo-core/` — shared base for kazoo_apps + ecallmgr roles. Entrypoint
    (`entrypoint.sh`) renders `config.ini`, writes `.erlang.cookie`, spawns the
    release; `KAZOO_BOOTSTRAP=/kazoo-init.sh` (kazoo-apps only) runs
    provisioning. `config.ini.template` is envsubst'd.
  - `kazoo-freeswitch/` — FreeSWITCH **1.10.9 + mod_kazoo** built from source.
    `entrypoint.sh` renders templates in `templates/autoload_configs/` from
    env, generates a self-signed `wss.pem`, ensures `epmd`, execs FreeSWITCH.
    `modules.conf` controls the build. **There is deliberately no
    `templates/sip_profiles/` and no local `autoload_configs/sofia.conf.xml`**
    (the Dockerfile actively deletes the vendor tree's copy of the latter) —
    the `sipinterface_1` SIP profile is served dynamically by ecallmgr instead
    of read from a file on disk; see "SIP profile serving & carrier trunk
    registration" below. Do not re-add either without understanding why they
    were removed.
  - `kamailio/` — kamailio 5.5.7 with PostgreSQL (not KazooDB). Entrypoint
    patches `local.cfg` substdefs, seeds PG role/db/schema from the initdb dump,
    seeds the dispatcher, injects `advertise` on UDP/TCP listeners.
  - `monster-ui/` — static SPA + nginx; talks only to Crossbar over HTTP.
- `charts/kazoo/` — Kubernetes chart mirroring the compose stack (single-replica
  StatefulSets for the data plane, Deployments for the app plane). See the
  Helm chart section below.
- `README.md` — user-facing docs for the two things that are configured
  live (via Crossbar/`sup`) rather than through the chart: external
  SIP/RTP IP assignment and carrier trunk registration. Kept deliberately
  generic (no real IPs/carrier details) — this file (`AGENTS.md`) is where
  the concrete mechanism and gotchas live.

## How the stack wires together (critical coupling)

Shared values that everything hangs on (real values live in `.env`):

1. **ERLANG_COOKIE** — identical across kazoo_apps/ecallmgr (VM
   `~/.erlang.cookie` + config.ini `[kazoo_apps]`/`[ecallmgr]` sections),
   FreeSWITCH mod_kazoo (`kazoo.conf.xml` `<param name="cookie">`). Note the
   **two-cookie concept**: the VM distribution cookie (what `sup` and dist use)
   vs the config.ini per-section cookies (what the app layer presents when it
   connects out). Both come from the same value.
2. **Rabbit creds** — one set, one vhost `/`: `[amqp] uri` in config.ini
   (kazoo apps), kamailio kazoo-module `MY_AMQP_URL`, FS direct-publish
   `KZ_AMQP_*` env (see below). kazoo-classic bundles its own amqp_client, so
   the broker version is decoupled from the app dependencies.
3. **Couch creds/host** — `[bigcouch] user/pass/ip` in config.ini (COUCH_* on
   the core image = COUCHDB_* in compose). `admin_port = 5984` equals the data
   port by design (see CouchDB section).
4. **SIP path**: phones SIP -> kamailio:5060 (UDP/TCP) -> dispatcher setid 1 ->
   `sip:freeswitch:11000`. Registrations/location live in PG (kamailio), NOT couch.
5. **eCallMgr <-> FS**: Erlang **dist long-name** connection. ecallmgr *initiates*
   to `freeswitch@freeswitch.kazoo`, dist port **8031**, over the docker network.
   **mod_sofia is deliberately NOT loaded in modules.conf** — it is loaded by
   ecallmgr only *after* the node connects; FS SIP therefore only comes up once
   FS has joined ecallmgr.

## Mod_kazoo / FreeSWITCH signaling (the key architecture)

- mod_kazoo is a pure **Erlang C-node** (`freeswitch@freeswitch.kazoo`, dist
  8031, cookie from `kazoo.conf.xml`). It is NOT an AMQP client in itself; the
  `KZ_AMQP_*` env-set channel is a separate/legacy publish path. FS events and
  fetch (directory/dialplan) requests flow to ecallmgr **over the dist
  connection**.
- ecallmgr discovers which FS nodes to reach from the **`ecallmgr` system_config
  couch doc → `"fs_nodes"`** list (`ecallmgr_fs_nodes:start_preconfigured_servers`
  → `kapps_config:get(<<"ecallmgr">>, <<"fs_nodes">>)`). If the key is missing it
  only ever pings the default `freeswitch@<ecallmgr's own host>` and retries
  forever → every call fails **"All Servers Busy"**. This is what broke on a
  clean-slate DB and is now seeded idempotently by `kazoo-init.sh` →
  `ensure_ecallmgr_fs_nodes()` (so future clean-slate rebuilds self-heal).

## SIP profile serving & carrier trunk registration (dynamic, ecallmgr-driven)

This is the biggest architecture change since the original device-to-device
milestone, so it gets its own section. Two related but separate things live
here: (a) how the *SIP profile itself* is delivered to FreeSWITCH, and (b)
how a *carrier trunk that requires registration* (rather than IP-ACL trust)
gets set up. README.md has the generic how-to; this section has the why and
the gotchas.

### Version matters: this is kazoo-classic, not upstream 2600hz/kazoo

`kazoo-core` builds from `kazoo-classic/kazoo` release tags (`KAZOO_RELEASE_TAG`
in `images/kazoo-core/Dockerfile`), **not** `2600hz/kazoo` master. The two have
diverged on exactly this mechanism: on `2600hz/kazoo` master,
`ecallmgr_fs_gateways:get/0` (the module that turns resource-gateway docs into
FreeSWITCH gateway XML) has **zero callers anywhere in the codebase** — it's
orphaned. On this repo's actual `kazoo-classic` tag, the equivalent module
(`ecallmgr_fs_config.erl`'s `default_sip_profiles/1`) still calls it directly.
**Always verify against the actual pinned `kazoo-classic` tag's source, not
upstream master** — they can behave differently on exactly the kind of thing
you'd naively "look up in the Kazoo docs" for.

### Why the SIP profile is served dynamically instead of from a file

FreeSWITCH's XML core resolves a named `<configuration>` section (like
`sofia.conf`) from its local static file tree *first*; it only calls out to a
registered "fetch" handler (here, `mod_kazoo`'s binding into ecallmgr) if that
section is **entirely absent** locally — not merely incomplete. A local
`sofia.conf.xml` that still exists, even with an empty `<profiles>` block,
fully satisfies the lookup and the dynamic fetch is never invoked. So to make
ecallmgr the source of truth, the Dockerfile has to actively `rm` both the
vendor tree's `autoload_configs/sofia.conf.xml` *and* the local
`sip_profiles/` dir (see "Layout" above) — not just decline to add our own
version, since the vendor's copy would otherwise win.

The consequence: `ecallmgr` becomes the **sole** source for the entire
`sipinterface_1` profile (every setting, not just the ones you care about),
with no static-file fallback. `system_config/ecallmgr.default.fs_profiles.
sipinterface_1.Settings` must be a **complete** settings object — every
`<param>` the old static `sip_profiles/sipinterface_1.xml` used to have,
reproduced exactly (see git history for the deleted file's last content if
you need the full reference list). A partial object doesn't merge with
sensible defaults for the parts you left out; whatever isn't in that JSON
object simply isn't in the profile FreeSWITCH gets.

Two flags gate this, both on `system_config/ecallmgr`:
- **`sofia_conf`** — without it, the fetch handler pattern-matches
  `'true' = kapps_config:is_true(...)` and just fails closed (caught,
  replies "not found"); FreeSWITCH then silently keeps whatever it already
  had. No error visible in FreeSWITCH's own logs — the rejection happens
  entirely on ecallmgr's side.
- **`process_gateways`** — separately gates whether `Gateways` (built from
  `ecallmgr_fs_gateways:get/0`, which reads the `sip_auth` and `offnet`
  couch DBs) gets included in the served profile at all.

### Registering a carrier trunk (`register: true` on a resource gateway)

Kazoo resources support `"register": true` on a gateway object for carriers
that authenticate via SIP REGISTER rather than a static IP allow-list — no
external registration proxy needed, contrary to what you might assume from
first principles (Kazoo *does* support this natively, it's just gated behind
`process_gateways` and barely documented). Crossbar's `cb_resources.erl`
handles a `register: true` + `enabled: true` gateway on an **account-level**
resource by aggregating a copy of the resource doc into the `sip_auth`
database (that's what `ecallmgr_fs_gateways:get/0` actually reads) and firing
a `reload_gateways` AMQP event.

**Gotcha that will burn you**: `reload_gateways`'s handler
(`ecallmgr_fs_node:handle_reload_gateways/2`) checks the `process_gateways`
flag **at the moment the event is handled**, not when it was published. If
you save the resource *before* `process_gateways` is already `true`, the
event fires and is silently swallowed — flipping the flag afterwards does
**not** retroactively trigger anything. You must save/re-save the resource
(any no-op edit works) *after* `process_gateways` is already on, to get a
fresh event that actually does something. If a registration mysteriously
never appears despite both flags being set, this is the first thing to check.

### Verifying a registration & general ESL/`fs_cli` access

`fs_cli` lives at `/usr/local/freeswitch/bin/fs_cli` in the image (built by
`make install`, copied wholesale) — it's not on `$PATH`, which reads as
"missing" if you only try the bare command name. The event socket
(`autoload_configs/event_socket.conf.xml`) is scoped to `loopback.auto`, so
it's reachable via `kubectl exec`/`docker exec` into the pod itself, not from
other pods or nodes:

```
fs_cli -H 127.0.0.1 -P 8021 -p ClueCon -x "sofia status gateway <resource-id>-0"
```

A healthy trunk shows `State  REGED`. (Historical note: this ACL used to be
set to `"any"`, which isn't a real named ACL anywhere in this config tree —
FreeSWITCH's ACL lookup fails closed on an unresolvable name, so it silently
denied *every* connection including loopback, making `fs_cli` look totally
broken. `mod_event_socket` is not ecallmgr's real control channel regardless
— that's `mod_kazoo` over `KAZOO_PORT`/dist, confirmed by `kazoo_node.c`
bgexec log lines — so this ACL only ever mattered for manual debugging.)

### XML-comment gotcha (crash-loops the whole pod)

**XML comments must never contain a literal `--` anywhere in their body**,
not just at the open/close delimiters — not even as an em-dash-style prose
separator. FreeSWITCH's XML parser fails the *entire* aggregated config tree
on this with a cryptic `Cannot Initialize [error near line N]: unclosed
<!--`, where `N` is a line number in the fully-expanded/included document,
not necessarily anywhere near the actual offending file — and FreeSWITCH
won't start at all, crash-looping the pod. Use `;` or plain sentence breaks
in XML comments in this repo, never `--`. (This shipped and crash-looped
production for real during this work — grep any new/edited `templates/**/*.xml`
comment for a bare `--` before it goes out.)

## CouchDB (data plane)

- CouchDB 3.x dropped the BigCouch-era "admin node port" 5986. kazoo-classic
  targets CouchDB 3.x directly and **never uses the admin connection** (verified
  in source); the 2600hz-era HAProxy 15986 shim is NOT needed. config.ini sets
  `admin_port = 5984` (same as the data port) and nothing routes to a foreign
  port. No proxy in front of CouchDB in this stack.
- Database names are URL-encoded account DBs (`account%2F<id>`); CouchDB 3.2.3
  only serves them via the encoded path — kazoo keeps them encoded end-to-end,
  no normalization needed.

## kazoo-core image (roles + init)

- One image, three roles selected by `KAZOO_NODE` (`kazoo_apps` | `ecallmgr`):
  a release tree at `/opt/kazoo` running `kazoo foreground`, controlled via
  `sup`. Nodes are `kazoo_apps@<hostname>`, `ecallmgr@<hostname>`; `sup`
  builds its target from the local node, so provisioning must run inside the
  node's own container.
- `kazoo-init.sh` (idempotent, kazoo-apps only) does, in order: wait for the
  node → `sup kapps_maintenance refresh` (creates/updates system DBs + views,
  retried while booting) → `ensure_ecallmgr_fs_nodes` (seeds `fs_nodes`) →
  `crossbar_maintenance create_account <name> <realm> <user> <pass>` →
  `crossbar_maintenance init_apps <shared-apps-dir> <api-url>` (registers
  Monster-UI apps once `/shared/.ready` appears).
- Post-boot knobs (`sup kapps_config set <cat> <key> ...`): `crossbar
  autoload_modules`, `ecallmgr authz_enabled`/`authz_default_action`, `smtp_client
  relay`, `notify default_from`, `ecallmgr default_ringback`.
- Erlang distribution: each container runs its own `epmd` on :4369; peers reach
  it via the container's DNS name. Long node names need a dotted host → compose
  sets `hostname:` to `<svc>.kazoo`.

## Monster-UI

- A browser-side SPA, **only** a client of Crossbar REST :8000 — no AMQP, no
  Erlang, no server-side logic. Web UI on :8080 (nginx). The app list shown in
  the UI tab bar comes from Crossbar's `/v2/accounts/{id}/apps` (populated by
  `crossbar_maintenance init_apps`).
- `CROSSBAR_API_URL` baked into registered apps must be **host-reachable**
  (e.g. `http://localhost:8000/v2`), never the docker-internal service name —
  the browser uses it, not the container.

## Kamailio

- Uses the community-postgres config tree (`local.cfg` substdefs), PostgreSQL
  for schema (subscriber/location/dispatcher), and the **kazoo module**
  (`MY_AMQP_URL`) for the RabbitMQ event bus. The entrypoint idempotently:
  waits for PG → creates the `kamailio` role/db if missing → loads the initdb
  schema if empty → seeds `dispatcher` setid 1 → patches `local.cfg` +
  `advertise` → execs kamailio.
- **k8s dispatcher target = FS reachable address, NOT the in-cluster name**:
  the chart feeds kamailio `FREESWITCH_SIP_ADDRESS` = `freeswitch.publicIP:11000`
  when set (else the freeswitch Service name). The Service name resolves to the
  freeswitch **ClusterIP**, and FS mirrors that ClusterIP into the SDP of the
  caller-facing leg (`a=oldmediaip` markers) → phones send RTP into a black
  hole → "call connects, no audio". The publicIP (LB VIP) path yields the
  correct `c=192.168.10.251` SDP. (See "Solved issues" #9.)

## HOMER / SIP capture (`homer/`, deployed into ns `kazoo`)

- Stands up **heplify sidecars** (per kazoo-kamailio + kazoo-freeswitch pod) →
  **heplify-server** (HEPv3 9060/UDP, TCP 9061, Postgres back-end) →
  **homer-app** (UI, LoadBalancer 9080→80, default creds `admin/sipcapture`
  and `support/sipcapture`). Chart sidebar: `hepCapture.enabled` + the
  `kazoo-kamailio-hep`/`kazoo-freeswitch-hep` ConfigMaps
  (`charts/kazoo/templates/hep-capture.yaml`); kamailio captures SIP 5060–7000,
  freeswitch SIP 11000 + RTP/RTCP 16384–16512, both `HEPv3` UDP → heplify-server.
- heplify sidecar needs NET_ADMIN/NET_RAW → the kazoo ns runs PSA
  **privileged** (relabelled). Config knobs: `hepCapture.{enabled,image,server}`.
- **heplify-server gotchas**: HEPTLSADDR shares its port with HEPTCPADDR — leave
  `HEPLIFYSERVER_HEPTLSADDR=""` or the TLS listener wins the bind then dies on
  the missing cert, killing the TCP port. Readiness must target **TCP 9061**
  (9060 is UDP-only): a failing probe keeps the pod out of EndpointSlices and
  heplify's UDP HEP gets dropped+ICMP-refused even though the Service looks
  fine — the EndpointSlice/`cilium service list` backend must match the live
  pod IP. Keep `Service` UDP 9060 + TCP 9061 ports explicit (a re-apply once
  silently dropped the UDP port).
- Query captured traffic (messages are in `homer_data`; `raw` has full SIP+SDP,
  `protocol_header`/`data_header` are jsonb):
  ```
  kubectl -n kazoo exec deploy/homer-db -- psql -U root -d homer_data -P pager=off \
    -c "select id, create_date, sid, protocol_header->>'srcIp' src, data_header->>'method' m, data_header->>'from_user' frm from hep_proto_1_call order by id"
  ```
  Rx the terminating-leg SDP via `select substring(raw from 'v=0.*') ...`
  (200 OK must carry `c=192.168.10.251`, not a ClusterIP/pod IP).

## GHCR builds (GitHub Actions)

- One workflow per image (`kazoo-core`, `kazoo-freeswitch`, `kazoo-kamailio`,
  `kazoo-monster-ui`), each scoped by `paths:` to its own `images/<dir>/**` so
  a push only rebuilds the image that actually changed. Push → build + push;
  pull requests → build only (no push). `workflow_dispatch` for manual rebuilds.
- Image names: `kazoo-core`, `kazoo-freeswitch`, `kazoo-kamailio`,
  `kazoo-monster-ui` (dirs `images/kazoo-core`, `images/kazoo-freeswitch`,
  `images/kamailio`, `images/monster-ui`). All builds are source-based from
  public URLs (git clones + release tarballs), so GitHub-hosted runners need
  no extra creds.
- Tags: everything is tagged `latest` for now (proper version tagging pending).
  GHA cache (`type=gha`, scope `<image>`) is shared, so PR builds are fast.
- Pushed packages are private by default in GHCR — set the repo/package
  visibility to public (or configure your k8s-imagePullSecrets) to pull them.
- **Helm chart**: `kazoo-helm.yml` packages `charts/kazoo` and pushes it as an
  OCI artifact to `oci://ghcr.io/<repo>/` on helm/ changes (PRs lint-only).
  Install/upgrade with:
  `helm install kazoo oci://ghcr.io/wiiaam/kazoo-docker/kazoo --version <Chart.yaml version>`.
  Bump `version:` in `charts/kazoo/Chart.yaml` whenever chart contents change.

## Helm chart (`charts/kazoo`)

- Mirrors the compose stack 1:1 on Kubernetes: image tags/behavior are the same
  images (`kazoo-*`, `latest`), env/secret wiring matches `.env.example`, and
  the ECK coupling is preserved (Erlang cookie, Rabbit creds, Couch host).
- **Erlang long-node names need dotted hostnames**; k8s pod DNS gives us the
  equivalent of the compose `hostname: <svc>.kazoo` trick. Every pod that runs
  an Erlang node (`kazoo-apps`, `ecallmgr`, `freeswitch`) sets
  `hostname: <svc>` + `subdomain: <values.subdomain>` +
  `setHostnameAsFQDN: true`, so it resolves as `<svc>.<subdomain>` behind a
  headless Service named after `values.subdomain` (default `kazoo`, matching
  the compose names `kazoo-apps.kazoo`, `freeswitch.kazoo`, ...). The
  `freeswitch@freeswitch.kazoo` identity is defaulted on both sides
  (`freeswitch.nodeName` + `kaa` `FS_NODE_NAME`), so the ecallmgr `fs_nodes`
  seed from `kazoo-init.sh` keeps working unchanged.
- The **`shared` PVC (ReadWriteMany)** is the `/shared` staging dir used by
  `crossbar_maintenance init_apps`: kazoo-apps renders the apps there,
  monster-ui's initContainer copies them in.
- **Values layout follows kube-prometheus-stack**: top-level `nameOverride` /
  `fullnameOverride` / `global.{imageRegistry,imagePullPolicy,
  imagePullSecrets}` + `subdomain`; each component carries `enabled`, a flat
  `image:` string (`--set <comp>.image=...`), a `service:` block (`name` = the
  in-cluster DNS name, type/ports/nodePort), and its storage. Service names
  default to standard short names (`couchdb`, `rabbitmq`, `postgres`, `crossbar`,
  `kamailio`, `freeswitch`, `monster-ui`); override e.g.
  `--set freeswitch.service.name=fs0` and the env wiring (`RABBIT_HOST`,
  `COUCH_HOST`, `FREESWITCH_SIP_ADDRESS`, ...) follows automatically.
- Expose model (`values.yaml`): genuinely generic — `<comp>.service.{type,
  labels,annotations,externalTrafficPolicy,loadBalancerIP,loadBalancerSourceRanges}`
  pass straight through to the Service (most-charts style), so LB pool
  selection / IP pinning live in the user's `service.labels`/`service.annotations`
  (e.g. Cilium LB-IPAM). Default `ClusterIP`; expose kamailio/freeswitch with
  `service.type: LoadBalancer`. Kamailio keeps SIP 5060 (set
  `kamailio.advertiseIP` at the LB). FreeSWITCH `freeswitch.service.includeRtp:
  true` appends the RTP slice 16384-16512 to the same Service (SIP 11000 +
  dist 8031 already there) — a single WAN-DNAT target, no node pinning.
  Pod-level hostPort/hostNetwork remain only for single-node labs
  (`kamailio.external.type`, `freeswitch.external.type`). Advertise
  DNS names (e.g. `sip.example.com`) for `kamailio.advertiseIP` /
  `freeswitch.publicIP` / `extRtpIP` so node-failure/NAT-rewrite churn is
  avoided.
- **The phone advertise-IP caveat still applies in k8s**: kamailio needs
  `kamailio.advertiseIP` (a host-reachable IP) or in-dialog requests die
  (same root cause as `.env` `KAMAILIO_PUBLIC_IP`; tree in
  `charts/kazoo/templates/NOTES.txt`).
- `<comp>.service.type: none` (kazooCore/monsterUi) skips that Service
  (`kubectl port-forward` instead) — avoids an invalid `type: none` in the
  Spec. Each component's `service` block sets name/type/ports, mirroring the
  kube-prometheus-stack values layout.
- Data plane is single-replica StatefulSets (CouchDB/Rabbit/PG) + PVCs; kazoo
  apps, ecallmgr, kamailio, freeswitch, monster-ui are Deployments.
- **HTTPRoutes** (Gateway API, per-app `<comp>.httpRoute:`, disabled by
  default): one route per app (`kazooCore.httpRoute` → Crossbar, `monsterUi.httpRoute`),
  each with own `enabled`/`hostname`/`gateway.{name,namespace}`/`tls` and
  appended `rules` (full specs: matches/filters/backendRefs) merged after the
  default backendRef rule; backendRefs follow the `<comp>.service.name`
  overrides automatically. TLS terminates on the Gateway (`tls` only selects
  the derived-URL scheme). The Crossbar base baked into Monster-UI app
  registration is derived by `kazoo.crossbarApiUrl`: explicit
  `monsterUi.crossbarApiUrl` wins → else
  `<scheme>://<kazooCore.httpRoute.hostname>/v2` when that route is enabled →
  else `http://localhost:8000/v2`.
- **No `extSipIP`/`extRtpIP` values** — removed along with the static SIP
  profile file (see "SIP profile serving..." above); the externally-advertised
  SIP/RTP address is now set live via `system_config/ecallmgr`, not a chart
  value or container env var. `NOTES.txt` points at that instead.
- **Every service's probes use a `startupProbe`**, not flat
  `initialDelaySeconds` on readiness/liveness. The old pattern (e.g.
  `initialDelaySeconds: 60`) sized the delay for the worst-case boot, so a
  normal-speed boot paid that full fixed delay on every redeploy regardless.
  The current pattern: a `startupProbe` (same check, short `periodSeconds`,
  large `failureThreshold` for runway) gates readiness/liveness until the
  process is actually up, and readiness/liveness themselves carry no
  `initialDelaySeconds` and a small `failureThreshold` (fast real-failure
  detection once startup is confirmed). Apply this same shape to any new
  service template rather than reintroducing flat delays.
- Render check: `helm lint charts/kazoo` and `helm template kazoo charts/kazoo`
  (20 manifests default: 8 Services incl. headless, 5 Deployments, 3
  StatefulSets, 3 PVCs, 1 Secret; +2 HTTPRoutes when any `<comp>.httpRoute`
  is enabled). Release name defaults to `kazoo`.
- Image/pull defaults: each component carries a flat `image:` string — the
  four kazoo images default to the repo's GHCR packages
  (`ghcr.io/wiiaam/<image>:latest`); the data plane uses official Docker Hub
  images (`couchdb:3.2.3`, `rabbitmq:3.13.7-management`, `postgres:13`).
  `global.imagePullPolicy` (default `IfNotPresent`) is applied to every
  container. Override an image with `--set <comp>.image=...`, or set
  `global.imageRegistry` to force every image (incl. official) through one
  registry (prepends the registry, keeps the repo path). Images must exist +
  be pullable in GHCR first (see GHCR builds): packages are private by
  default, set visibility public or pass `imagePullSecrets`.

## Key files / touch points

| Concern | File |
|---|---|
| FS config render + env | `images/kazoo-freeswitch/entrypoint.sh` |
| mod_kazoo dist settings (cookie/nodename/port, legacy-events) | `images/kazoo-freeswitch/templates/autoload_configs/kazoo.conf.xml` |
| Removes the local `sofia.conf.xml`/`sip_profiles` so the profile below is dynamic | `images/kazoo-freeswitch/Dockerfile` |
| SIP profile (ext-sip/rtp advertise, codecs, context) — **live config, not a file** | `system_config/ecallmgr.default.fs_profiles.sipinterface_1.Settings` (Crossbar/`sup`; see README.md + the section above) |
| ESL access (fs_cli via loopback only) | `images/kazoo-freeswitch/templates/autoload_configs/event_socket.conf.xml` |
| Build-time modules | `images/kazoo-freeswitch/modules.conf` |
| kamailio config secrets/advertise/dispatcher seeding | `images/kamailio/entrypoint.sh` |
| node bootstrap + `fs_nodes` seeding + master account | `images/kazoo-core/kazoo-init.sh` |
| node/env render for apps/ecallmgr | `images/kazoo-core/entrypoint.sh`, `config.ini.template` |
| published ports / RTP slice / IP vars | `compose.yaml` |
| shared secrets/tokens template | `.env.example` |
| chart values / expose modes / secrets | `charts/kazoo/values.yaml` |
| Erlang long-name wiring (headless svc + FQDN) | `charts/kazoo/templates/{headless.yaml, _helpers.tpl}` |
| per-env override of `freeswitch@freeswitch.kazoo` | `images/kazoo-core/kazoo-init.sh` (`FS_NODE_NAME`) |

## Ports

| Port | Use |
|---|---|
| 8000 | Crossbar HTTP API (published for browser) |
| 8080 | Monster-UI (nginx) |
| 5060 udp+tcp | Kamailio SIP |
| 11000 udp+tcp | FreeSWITCH SIP (published) |
| 16384–16512 udp | FreeSWITCH RTP (published slice) |
| 8021 / 8031 | FS ESL / Erlang dist (internal) |
| 5672 / 15672 | RabbitMQ AMQP / management |

## Crossbar API smoke gotchas (4.3 classic)

- Bare account-unscoped v2 endpoints (`/v2/users`, `/v2/phone_numbers`) return
  **500** in this upstream build — not a stack defect (the request context never
  gets a DB name). The UI always calls `/v2/accounts/{id}/...`, which works.
- Auth: `PUT /v2/user_auth` with `{"data":{"credentials":"<md5(user:password)>",
  "account_name": "<name>"}}`; `realm` also works. The raw password is never sent.
- Ops gotcha: `kazoo eval "$(cat file)"` runs **on the live node** — a trailing
  `erlang:halt()` in the eval kills kazoo_apps. Never put `halt()` in eval files.

## Solved issues worth remembering

1. **"All Servers Busy" after clean DB** — missing `fs_nodes` in
   `system_config/ecallmgr` (above). Fix + verification:
   `sup ecallmgr_fs_nodes summary` lists `freeswitch@freeswitch.kazoo | true`.
2. **Advertised-address topology** — kamailio must `advertise` the host-reachable
   IP (`KAMAILIO_PUBLIC_IP`) in Via/Contact/Record-Route on UDP/TCP 5060 + 7000,
   or phones drop in-dialog BYE/ACK. FS advertises `EXT_SIP_IP`
   (=`FS_PUBLIC_IP`) as ext-sip and `EXT_RTP_IP` for RTP; SIP 11000 + the RTP
   slice are published to the host. On Docker Desktop the host IP is the LAN
   address (set it in `.env`); `127.0.0.1` only works from the host itself.
3. **Dispatcher dedup** — stale `dispatcher` rows (old container IPs) caused
   480/482 "merged" responses; entrypoint now prunes + keeps one canonical
   destination (and prunes other `sip:<bridge-ip>:11000` rows). NB in k8s the
   entrypoint's old `INSERT ... ON CONFLICT DO NOTHING` had no unique backing
   index, so restarts re-appended identical rows — the image is now hardened to
   `DELETE FROM dispatcher WHERE setid=1` + single INSERT (image rebuild
   pending a GHCR push). Runtime reload: `kamcmd dispatcher.reload`.
4. **`legacy-events=true` mandatory** in kazoo.conf.xml — without it ecallmgr
   only sees modern 2-tuple fetch events and never answers directory/dialplan
   requests ("unhandled message" catch-all).
5. **Missing `wss.pem` kills sipinterface_1** — sofia reads it even with
   tls=false; entrypoint generates a self-signed one each boot.
6. **mod_kazoo build branch** — use the in-tree v1.10.9 mod_kazoo; the standalone
   master build double-frees. Also **pinned**: FS is `1.10.9` (newer crashes on
   kazoo-classic AMQP).
7. **Console/tooling gotchas** — no jq/python3 in the core image (rockylinux,
   curl-only); FS container has no bash (use `sh -c`). `fs_cli` binary exists
   at `/usr/local/freeswitch/bin/fs_cli` but isn't on `$PATH`; the event
   socket ACL is scoped to `loopback.auto` (see "SIP profile serving..."
   above for the history of why it used to silently deny everyone).
8. **kamailio binds all interfaces by default** — the entrypoint now defaults
   `BIND_IP=0.0.0.0` (all IPv4) instead of `hostname -i`'s first address:
   dual-stack k8s pods list the intended-but-not-assignable IPv6 first on a
   v4-only underlay → "bind ... Cannot assign requested address" crashloop.
   Optional override: `[::]` = all v6, `dual` = both stacks (appends
   `listen=...:[::]:<port>` lines), or a single address. No chart plumbing
   needed; empty/unset = all interfaces. Requires an image rebuild to take
   effect.
9. **"Call connects, no audio" in k8s = ClusterIP leaked into SDP** — kamailio
   seeded the dispatcher with `sip:freeswitch:11000`, which CoreDNS resolved to
   the freeswitch **Service ClusterIP** (10.102.30.x). FS recorded that host as
   the leg's local contact and mirrored it into the 200 OK SDP sent back to the
   caller (`c=IN IP4 10.102.30.120`, plus `a=oldmediaip:192.168.10.251` marks),
   so phones point RTP at an unroutable ClusterIP → silent call. The cleanup:
   the chart now feeds `FREESWITCH_SIP_ADDRESS` = `freeswitch.publicIP:11000`
   (the LB VIP, which also honours the phone-advertise caveat) rather than the
   service name, when publicIP is set. Diagnosed from a HOMER trace where the
   same call forked to the ClusterIP (broken SDP c=10.102.30.120) AND the VIP
   (good SDP c=192.168.10.251) on duplicate dispatcher rows.
   Optional override: `[::]` = all v6, `dual` = both stacks (appends
   `listen=...:[::]:<port>` lines), or a single address. No chart plumbing
   needed; empty/unset = all interfaces. Requires an image rebuild to take
   effect.

## Master account + test topology

- Master account has realm `MASTER_REALM` (def. `sip.example.local` from
  `.env.example`); devices `admin` and `tester` (MicroSIP) register to kamailio
  over TCP with host-reachable contacts
  `sip:<user>@<KAMAILIO_PUBLIC_IP>:<port>;transport=TCP;ob`.
- Devices/accounts were (re)created in a clean-slate CouchDB by hand;
  recreating them is NOT automated in this repo yet.

## Useful commands

Docker is not on PATH on every dev shell (Docker Desktop on Windows/WSL) —
point an alias/wrapper at the `docker`/`docker.exe` binary first.

- Inspect a running stack: `docker ps` (names are `kazoo-<svc>-1`).
- Logs: `docker logs kazoo-freeswitch-1` (also `kazoo-ecallmgr-1`,
  `kazoo-kamailio-1`). FS logs in `/var/log/freeswitch/` (`kazoo-debug.log`).
- ecallmgr media-server view:
  `docker exec kazoo-ecallmgr-1 sh -c 'cd /opt/kazoo/bin && ./sup ecallmgr_fs_nodes summary'`
- Rabbit connections test (proves which services join the AMQP bus):
  `docker exec kazoo-rabbitmq-1 rabbitmqctl list_connections` / `list_channels`.
- Couchdoc read:
  `curl "http://<user>:<pass>@couchdb:5984/system_config/ecallmgr"`.
- Rebuild + recreate one service: `docker compose up -d --build <svc>`.
- Erlang dist reachability probe (from ecallmgr):
  `erl -name pingtest@ecallmgr.kazoo -setcookie <cookie> -noshell -eval 'io:format("~p~n",[net_adm:ping('\''freeswitch@freeswitch.kazoo'\'')]),halt().'`

## Open threads / next steps

- **Inbound DID delivery through the registered carrier trunk fails** — traced
  conclusively (via the carrier's own SIP trace + CDRs) to their platform
  refusing the call internally before ever generating a leg toward this
  stack; confirmed not a network/firewall/routing issue on our side (an
  external SIP probe straight at the advertised SIP port gets a correct
  response). Nothing further to do here from this repo's side until the
  carrier's own resource/registrar-lookup issue is found.
- **Voicemail/prompt playback is broken**, unrelated to the trunk work:
  `playback(prompt://...)` fails with `Invalid file format [prompt]`,
  preceded by `kazoo_fetch_agent.c: No languages XML erlang handler
  currently available`. `mod_shout`/`mod_native_file`/`mod_sndfile` all load
  fine, so it's specifically the dynamic language/prompt-XML resolution path
  (part of `mod_kazoo`) that isn't coming up — not investigated further yet.
- Automate device/account provisioning (currently manual couch edits) so a
  clean-slate rebuild is fully scripted (`kazoo-init.sh` is the right home).
- Multi-node/K8s growth: CouchDB cluster + zone placement, HAProxy/edge story
  (the chart is currently single-replica per data service).
- Investigate whether FS ever needs its own AMQP connection (the "zero rabbit
  connections from FS" observation turned out to be expected, not a bug).