Seismic Image Module
===

This directory is the Seismic-specific mkosi module — everything that layers on
top of [`shared/`](../../shared/) to turn a generic Debian base into a Seismic
node.

Top-level files at a glance:

| File                                   | Role                                                                                            |
| -------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [`mkosi.conf`](mkosi.conf)             | Debian packages (`nginx`, `certbot`, `cryptsetup`, …) + build packages                          |
| [`mkosi.build`](mkosi.build)           | Source-builds: pinned commits of `tdx-init`, `seismic-reth`, `seismic-attestation-service`, `seismic-custodian-service`, `summit` |
| [`sources.yaml`](sources.yaml)         | Pinned git refs read by `mkosi.build` (structured manifest, Renovate/Dependabot-friendly)       |
| [`mkosi.postinst`](mkosi.postinst)     | Creates users/groups, enables systemd services                                                  |
| [`kernel/config.d/`](kernel/config.d/) | Seismic-specific kernel config snippets                                                         |
| [`mkosi.extra/`](mkosi.extra/)         | Filesystem overlay — systemd units, nginx config, helper scripts                                |

What ends up in the image
---

Files in this directory aren't all part of the produced image — some are
build-inputs only. The image rootfs is the union of four channels:

| Channel                                   | What it puts in the image                                                                                                                                                                     |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`mkosi.extra/`](mkosi.extra/)            | Copied wholesale at matching paths — see tree below.                                                                                                                                          |
| `Packages=` in [`mkosi.conf`](mkosi.conf) | apt-installed Debian packages: `nginx`, `certbot`, `python3-certbot-nginx`, `cryptsetup`, `jq`, `libtss2-*`, `lz4`                                                                                |
| [`mkosi.build`](mkosi.build)              | Compiled binaries written to `$DESTDIR`: `tdx-init`, `seismic-reth`, `seismic-attestation-service`, `seismic-custodian-service`, `summit` → `/usr/bin/`              |
| [`mkosi.postinst`](mkosi.postinst)        | Image-fs mutations: system users + `engine-api`/`custodian-ipc`/`conf` groups in `/etc/{passwd,group}`, services symlinked into `/etc/systemd/system/minimal.target.wants/`, `setup-*` helper scripts made executable |

`mkosi.extra/` lays out exactly what its name suggests — the same paths
relative to the image root:

```
mkosi.extra/
├── etc/
│   ├── nginx/node-template.conf            → /etc/nginx/node-template.conf
│   ├── security/limits.d/nofile.conf       → /etc/security/limits.d/nofile.conf
│   ├── seismic/tmpfiles-persistent.conf    → /etc/seismic/tmpfiles-persistent.conf
│   ├── tmpfiles.d/seismic-runtime.conf     → /etc/tmpfiles.d/seismic-runtime.conf
│   ├── systemd/system/*.{service,timer}    → /etc/systemd/system/...
│   └── udev/rules.d/60-tpm-permissions.rules → /etc/udev/rules.d/...
└── usr/
    └── bin/{setup-nginx-ssl,setup-persistent-luks} → /usr/bin/...
```

Module-root files that are **not** in the image: `mkosi.conf`,
`mkosi.build`, `mkosi.postinst`, `sources.yaml`, `kernel/config.d/`.
They're read at build time and never copied to `$DESTDIR`.

Services
---

Each of the following is a systemd unit under
[`mkosi.extra/etc/systemd/system/`](mkosi.extra/etc/systemd/system/). They're
enabled (added to `minimal.target.wants`) via the loop in
[`mkosi.postinst`](mkosi.postinst).

**Boot chain (services ordered by when they're needed):**

```
  tdx-init.service       (waits for operator config POST → /run/seismic/conf/)
          │
          ▼
  custodian.service      (owns root_key, serves key ops on the custodian socket,
          │               drops LUKS keys to /run/seismic/custodian/)
          ▼
  attestation.service  (attestation RPC on :7878; on joining nodes
          │                     fetches root_key from peers into the custodian)
          ▼
  persistent-luks-setup.service  (reads LUKS keys, verifies header MAC, mounts /persistent)
          │
          ▼
  nginx-ssl-setup.service ──► certbot-renew.timer
          │                    (cron-style, fires
          │                     certbot-renew.service
          │                     monthly to renew the
          │                     Let's Encrypt cert)
          ▼
  reth.service
          │
          ▼
  summit.service
```

The boot chain has no service-level TPM-perms or per-service dir-setup;
both are handled out-of-band:

- **TPM device perms** — see
  [`60-tpm-permissions.rules`](mkosi.extra/etc/udev/rules.d/60-tpm-permissions.rules)
  (udev rule, applied at device-creation time).
- **`/persistent/<svc>` ownership/mode** — see
  [`tmpfiles-persistent.conf`](mkosi.extra/etc/seismic/tmpfiles-persistent.conf)
  (applied by `persistent-luks-setup.service`'s `ExecStartPost` after
  the LUKS volume is mounted).

### TPM access

Configured declaratively via the
[udev rule](mkosi.extra/etc/udev/rules.d/60-tpm-permissions.rules) —
perms are set the moment the kernel publishes the device, before any
service starts. No ordering constraints; no `Requires=`/`After=`
against any TPM-setup unit anywhere.

`attestation.service` gains TPM access via the `attestation`
group ownership on `/dev/tpmrm0` (set by the udev rule). The custodian,
`reth`, and `summit` don't talk to the TPM. The TPM2 user-space libraries
the attestation service links against (`libtss2-esys-…`,
`libtss2-tctildr0t64`) come from `mkosi.conf` Packages.

### `tdx-init.service`

Runs `tdx-init wait-for-config`, which on every boot blocks until a
provisioner POSTs the node's configuration (TOML: `[domain]` name/email,
optional `[root_key]` genesis_node/peers, and `[network]` with the
base64 network manifest + reth genesis) via HTTP. On receipt
tdx-init translates the payload into per-service config files under
`/run/seismic/conf/`: `domain.env` (for `setup-nginx-ssl`),
`custodian.env` (consumed by `custodian.service` via `EnvironmentFile=`),
`attestation.env` (likewise by `attestation.service`),
`network-manifest.json` (hashed by the attestation service into
`network_id`), and `reth-genesis.json` (the chain spec `reth.service`
passes to `--chain`).
The drop-zone is tmpfs (declared in
[`tmpfiles.d/seismic-runtime.conf`](mkosi.extra/etc/tmpfiles.d/seismic-runtime.conf)),
so the sentinel `tdx-init-done` is wiped each boot and deploy tooling
re-POSTs every time — matches the broader RAM-only design where
`root_key` is also re-fetched per boot.

Runs as the `tdx-init` system user (group `conf`). The runtime dir is
materialized with `tdx-init:conf 2750` by systemd-tmpfiles at
sysinit.target, before any service starts.

`setup-nginx-ssl` sources `domain.env` for certbot. `custodian.service`
reads `SEISMIC_CUSTODIAN_GENESIS_NODE` from `custodian.env` and
`attestation.service` reads `SEISMIC_ROOT_KEY_PEERS` from
`attestation.env`; the attestation service fails fast at startup if the
custodian holds no root key and no peers are set (no in-binary fallback —
operator config is the only source of peer IPs). reth reads its chain spec from
`/run/seismic/conf/reth-genesis.json`; summit takes its args statically
from the systemd unit file.

### `custodian.service`

Runs [`seismic-custodian-service`](https://github.com/SeismicSystems/enclave)
as user `custodian` — the trust root of the node. It owns
`root_key` (RAM-only) and serves key derivation and root-key wrapping on
`/run/seismic/custodian/custodian.sock`; it has no network listener.
The socket lives in a `custodian:custodian-ipc 2750` directory
(from `tmpfiles.d/seismic-runtime.conf`; setgid assigns new sockets to
the `custodian-ipc` filesystem access group, which gates who may connect),
and the unit's `--allow` grants pin which caller UID may invoke which
method. A genesis node generates `root_key` at startup
(`SEISMIC_CUSTODIAN_GENESIS_NODE` from `custodian.env`); a joining node
acquires it through the bootstrap methods driven by the attestation
service. Whenever the root key becomes present, the custodian drops the
LUKS keyfile at `/run/seismic/custodian/luks-keys` for
`setup-persistent-luks` (see boot diagram above).

### `attestation.service`

Runs [`seismic-attestation-service`](https://github.com/SeismicSystems/enclave)
on `:7878` as user `attestation` (supplementary `conf` for
`/run/seismic/conf`, `custodian-ipc` for the custodian socket). The
network-facing half of the process split: it verifies and mints
attestation evidence and answers peer bootstrap, but holds no key
material — every key operation goes through the custodian socket. On a
joining node it fetches the wrapped `root_key` from the configured peers
and installs it into the local custodian. Access to `/dev/tpmrm0` for
attestation-quote generation comes via the udev rule that sets
`attestation` group ownership on the device node.

`RestartSec=60` is unusually long — TDX quote generation can be slow on
restart; tight loops would hammer the TPM.

### `persistent-luks-setup.service`

Oneshot that runs
[`setup-persistent-luks`](mkosi.extra/usr/bin/setup-persistent-luks):
waits for the LUKS keys from the custodian, verifies the on-disk
header, opens the LUKS volume, and mounts it at `/persistent`. See
the script's header comment for the full design (key handoff, header
MAC, detached-header open).

`Restart=on-failure RestartSec=5` to ride out transient cases (disk
not yet attached, root-key bootstrap slow to complete).

`ExecStartPost=/usr/bin/systemd-tmpfiles --create /etc/seismic/tmpfiles-persistent.conf`
materializes the per-service `/persistent/<svc>` subdirs after mount.

The disk discovery defaults to `/dev/disk/by-path/*10` (Azure LUN 10).
Override with globs in `/etc/seismic-images/persistent-disk-glob` for
other clouds. TODO: have deploy tooling write the override file at
provisioning time.

### `nginx-ssl-setup.service`

Oneshot. Sources `/run/seismic/conf/domain.env` for domain+email,
templates [`node-template.conf`](mkosi.extra/etc/nginx/node-template.conf)
into a real nginx config, runs certbot to obtain a Let's Encrypt cert,
and enables the renewal timer.

Currently a hard dependency for `reth.service` + `summit.service`
(see their `Requires=`). Cert acquisition failure blocks them from
starting — coupling is probably too tight (an EL/CL doesn't
fundamentally need public HTTPS up to function), but it's the
current behavior.

### `certbot-renew.service` + `certbot-renew.timer`

Monthly cron-style job that runs `certbot renew`. The timer uses
`RandomizedDelaySec=1h` so fleet deployments don't all hit Let's
Encrypt at the same minute.

Known issue (flagged inline in the service file): potential race with
disk snapshots — worth adding a lock before production use.

### `reth.service`

Runs [`seismic-reth`](https://github.com/SeismicSystems/seismic-reth) as
user `reth` (group `eth`). Execution client — HTTP RPC on `:8545`, WS on
`:8546`, P2P on `:30303`, metrics on `:9001`. Fetches its purpose keys at
startup and decrypts `TxSeismic` (type `0x74`) calldata in-process.

Gated on `attestation.service` (and through it `custodian.service`),
since it fetches its purpose keys from the custodian's Unix socket
at startup.

### `summit.service`

Runs [`summit`](https://github.com/SeismicSystems/summit) as user
`summit` (group `eth`). Consensus client — REST API on `:3030` (reached
via nginx `/summit`), P2P on `:18551`, metrics on `:9002`.

Gated on both `attestation.service` and `reth.service`
(EL ↔ CL via Engine API).

Doc gap
---

This readme currently only covers services. Things not documented here
yet that would be worth adding over time: the kernel config rationale
(`kernel/config.d/10-seismic`), build-time flags for reproducibility in
`mkosi.build`, and the relationship between this module and the
`mkosi.profiles/{azure,gcp}/` cloud-specific additions.
