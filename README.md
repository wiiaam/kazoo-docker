# kazoo-docker

## External SIP/RTP IP configuration

`sipinterface_1` (FreeSWITCH's SIP profile) is served dynamically by `ecallmgr`
rather than baked into a static file in the `kazoo-freeswitch` image. This
means the externally-advertised SIP/RTP address (`ext-sip-ip` / `ext-rtp-ip`),
`sip-port`, and `tls-sip-port` are **not** Helm values or container env
vars — they're configured entirely through Kazoo's own
`system_config/ecallmgr` document, via the Crossbar API or `sup`, and take
effect without an image rebuild or redeploy.

### One-time setup

Two flags on `system_config/ecallmgr` need to be enabled (cluster-wide,
persists across restarts):

```
sup kapps_config set_default ecallmgr process_gateways true
sup kapps_config set_default ecallmgr sofia_conf true
```

- `process_gateways` — lets ecallmgr push resource gateways with
  `"register": true` (see below) to FreeSWITCH.
- `sofia_conf` — makes ecallmgr the source of the entire `sipinterface_1`
  profile config, served on demand instead of read from a local file. This
  only has an effect because the `kazoo-freeswitch` image deliberately does
  not ship a local `sofia.conf.xml`/`sip_profiles` — if either flag is off,
  FreeSWITCH silently keeps whatever it already has (harmless when set
  ahead of time, but nothing changes until both are true).

### Setting the profile

The profile's settings live under
`system_config/ecallmgr.default.fs_profiles.sipinterface_1.Settings`, e.g.
via `PATCH`/`POST` on `/v2/system_configs/ecallmgr`:

```json
{
  "data": {
    "default": {
      "fs_profiles": {
        "sipinterface_1": {
          "Settings": {
            "ext-sip-ip": "<your externally-reachable IP or hostname>",
            "ext-rtp-ip": "<your externally-reachable IP or hostname>",
            "sip-port": "<your SIP port, e.g. matching the k8s Service>",
            "tls-sip-port": "<your TLS SIP port>",
            "...": "every other sofia profile setting you need (codecs, ACLs, DTMF, session timers, etc.) -- this becomes the sole source of the profile with no local-file fallback, so it must be a complete settings object, not a partial override"
          }
        }
      }
    }
  }
}
```

Changing `ext-sip-ip`/`ext-rtp-ip` going forward is just re-`PATCH`ing this
document — no image rebuild, no pod restart required for FreeSWITCH to pick
it up on its next profile reload.

## SIP trunk registration (carriers that require registration, not IP ACL)

Kazoo resources support outbound registration for carriers/BYOC trunks that
authenticate via SIP REGISTER rather than a static IP allow-list. This is a
resource-gateway feature (`"register": true`), gated by the same
`process_gateways` flag from above.

### Steps

1. Enable `process_gateways` on `system_config/ecallmgr` (see above) if not
   already on.
2. On the resource's gateway object (via Crossbar `/v2/accounts/{account_id}/resources/{resource_id}`
   or a global resource), set the usual auth fields plus `register`:
   ```json
   {
     "server": "<carrier SIP server>",
     "port": 5060,
     "realm": "<carrier auth realm>",
     "username": "<carrier-provided username>",
     "password": "<carrier-provided password>",
     "register": true
   }
   ```
   Optionally set `register_extension` if the carrier routes inbound calls
   back to the registered contact rather than sending fresh INVITEs to an
   ACL'd IP, so Kazoo knows which extension/callflow to route those to.
3. Save the resource. Saving publishes a `reload_gateways` AMQP event that
   tells ecallmgr to tell FreeSWITCH to rescan its sofia profile.
   **Gotcha**: this only does anything if `process_gateways` was *already*
   `true` at the moment of the save — if you just turned the flag on in the
   same session, save/re-save the resource once more afterwards to fire a
   fresh event under the new setting.

### Verifying registration

From inside the `kazoo-freeswitch` pod (`fs_cli` lives at
`/usr/local/freeswitch/bin/fs_cli`, not on `$PATH`, and the event socket is
restricted to loopback — use `kubectl exec`):

```
fs_cli -H 127.0.0.1 -P 8021 -p ClueCon -x "sofia status gateway <resource-id>-0"
```

A healthy registration shows `State  REGED`. If it's stuck in
`TRYING`/`FAILED`, check the credentials/realm first, then confirm the
gateway actually reached FreeSWITCH at all (`sofia status` should list it) —
if it's missing entirely, re-check the `process_gateways` timing gotcha
above, or check FreeSWITCH's logs for the REGISTER attempt and the carrier's
response.