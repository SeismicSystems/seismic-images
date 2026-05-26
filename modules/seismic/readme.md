Seismic Image Module
===

This directory is the Seismic-specific mkosi module — everything that layers on
top of [`shared/`](../../shared/) to turn a generic Debian base into a Seismic
node.

Top-level files at a glance:

| File                                   | Role                                                                                            |
| -------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [`mkosi.conf`](mkosi.conf)             | Debian packages (`nginx`, `certbot`, `cryptsetup`, …) + build packages                          |
| [`mkosi.build`](mkosi.build)           | Source-builds: pinned commits of `tdx-init`, `seismic-reth`, `seismic-enclave-server`, `summit` |
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
| `Packages=` in [`mkosi.conf`](mkosi.conf) | apt-installed Debian packages: `nginx`, `certbot`, `python3-certbot-nginx`, `cryptsetup`, `systemd-cryptsetup`, `tpm2-tools`, `libtss2-*`, `lz4`                                              |
| [`mkosi.build`](mkosi.build)              | Compiled binaries written to `$DESTDIR`: `tdx-init`, `seismic-reth`, `seismic-enclave-server`, `summit` → `/usr/bin/`; reth dev genesis → `/usr/share/seismic-reth/genesis.json`              |
| [`mkosi.postinst`](mkosi.postinst)        | Image-fs mutations: system users + `engine-api`/`conf`/`tss` groups in `/etc/{passwd,group}`, services symlinked into `/etc/systemd/system/minimal.target.wants/`, `setup-*` helper scripts made executable |

`mkosi.extra/` lays out exactly what its name suggests — the same paths
relative to the image root:

```
mkosi.extra/
├── etc/
│   ├── nginx/node-template.conf            → /etc/nginx/node-template.conf
│   ├── security/limits.d/nofile.conf       → /etc/security/limits.d/nofile.conf
│   ├── seismic/tmpfiles-persistent.conf    → /etc/seismic/tmpfiles-persistent.conf
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
  persistent-luks-setup.service
          │
          ▼
  tdx-init.service
          │
          ▼
  nginx-ssl-setup.service ──► certbot-renew.timer
          │                    (cron-style, fires
          │                     certbot-renew.service
          │                     monthly to renew the
          │                     Let's Encrypt cert)
          ▼
  enclave.service
          │
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

`enclave.service` gains TPM access via the `tss` supplementary group
(`mkosi.postinst` adds the user to that group). `reth`/`summit` don't
talk to the TPM. The TPM2 user-space libraries the enclave links against
(`libtss2-esys-…`, `libtss2-tctildr0t64`) come from `mkosi.conf` Packages.

### `persistent-luks-setup.service`

Oneshot that runs
[`setup-persistent-luks`](mkosi.extra/usr/bin/setup-persistent-luks),
which provisions or unlocks the persistent LUKS volume and mounts it at
`/persistent`. Idempotent across boots:

- **First boot.** Generates a 32-byte CSPRNG key, `cryptsetup luksFormat`
  with that key, `mkfs.ext4`, then `systemd-cryptenroll --tpm2-device=auto
  --tpm2-pcrs=4+9+11` to seal an unlock key under a TPM2 PCR policy bound
  to the TDX measurement, finally wipes the original CSPRNG keyslot. No
  human ever knows the unlock material.
- **Every subsequent boot.** `cryptsetup isLuks` is true; the script
  invokes `systemd-cryptsetup attach … tpm2-device=auto`, which TPM2-
  unseals the keyslot — fails closed if the PCRs differ from when the
  slot was sealed (tampered image, different VM, etc.).

`Restart=on-failure RestartSec=5` to ride out transient cases like the
data disk not yet attached or the vTPM not yet ready; systemd gives up
after a few cycles, surfacing a hard failure if the underlying issue is
permanent. `/dev/tpm[rm]*` perms are set by udev (see "TPM device
permissions" above), so no explicit ordering against any TPM-setup
service is needed.

`ExecStartPost=/usr/bin/systemd-tmpfiles --create /etc/seismic/tmpfiles-persistent.conf` 
runs after the volume is mounted to materialize the per-service `/persistent/<svc>` subdirs 
from the central tmpfiles config. Downstream services (reth, enclave, summit, tdx-init)
used to do this work in their own `ExecStartPre` blocks;
centralized here so there's one auditable file describing what each service expects on disk.

The disk discovery defaults to `/dev/disk/by-path/*10` (Azure LUN 10).
Override with one or more globs in `/etc/seismic-images/persistent-disk-glob`
for other clouds (GCP exposes `/dev/disk/by-id/google-<diskname>`,
no LUN concept). TODO: have deploy tooling write the override file at
provisioning time.

Replaces the LUKS provisioning that previously lived inside the `tdx-init`
binary; the binary now handles only HTTP config receipt. See
`tdx-init` commit `695a2f7` for the rationale.

### `tdx-init.service`

Runs `tdx-init wait-for-config`, which on first boot blocks until a
provisioner POSTs the node's configuration (TOML: `[domain]` name/email
and optional `[enclave]` genesis_node/peers) via HTTP. On receipt
tdx-init translates the payload into per-service config files under
`/persistent/conf/`: `domain.env` (for `setup-nginx-ssl`) and
`enclave.env` (consumed by `enclave.service` via `EnvironmentFile=`).
A sentinel at `/persistent/conf/.tdx-init-done` is touched after the
per-service write completes; on subsequent boots the unit is a no-op
(sentinel present, binary exits immediately).

Runs as the `tdx-init` system user (group `conf`). `ExecStartPre=+...`
ensures `/persistent/conf` exists with `tdx-init:conf` ownership before
the binary writes into it.

`setup-nginx-ssl` sources `domain.env` for certbot. `enclave.service`
loads `enclave.env` for `SEISMIC_ENCLAVE_GENESIS_NODE` /
`SEISMIC_ENCLAVE_PEERS`; the enclave fails fast at startup if neither
is set (no in-binary fallback — operator config is the only source of
peer IPs). reth and summit take their args statically from the
systemd unit files.

### `nginx-ssl-setup.service`

Oneshot. Sources `/persistent/conf/domain.env` for domain+email, templates
[`node-template.conf`](mkosi.extra/etc/nginx/node-template.conf) into a
real nginx config, runs certbot to obtain a Let's Encrypt cert, and
enables the renewal timer.

Currently acts as a hard dependency for the whole node stack (see
[`enclave.service`](mkosi.extra/etc/systemd/system/enclave.service),
[`reth.service`](mkosi.extra/etc/systemd/system/reth.service),
[`summit.service`](mkosi.extra/etc/systemd/system/summit.service)'s
`Requires=`). Cert acquisition failure currently blocks node startup —
this coupling is probably too tight (the enclave doesn't fundamentally
need public HTTPS up to function), but it's the current behavior.

### `certbot-renew.service` + `certbot-renew.timer`

Monthly cron-style job that runs `certbot renew`. The timer uses
`RandomizedDelaySec=1h` so fleet deployments don't all hit Let's
Encrypt at the same minute.

Known issue (flagged inline in the service file): potential race with
disk snapshots — worth adding a lock before production use.

### `enclave.service`

Runs [`seismic-enclave-server`](https://github.com/SeismicSystems/enclave)
on `:7878` as user `enclave` (primary group `enclave`, supplementary `conf`
for reading `/persistent/conf/enclave.env` and `tss` for vTPM access). The
enclave is the trust root of the node — holds the network encryption key,
validator BLS keys, and derives per-purpose
secrets sealed to the TDX measurement. See the enclave repo for details
on the RPC surface.

Depends on `persistent-luks-setup` (needs `/persistent` for sealed
state) and `nginx-ssl-setup` (for the public HTTPS endpoint). Access to
`/dev/tpmrm0` for attestation-quote generation comes via the udev
rule that sets `tss` group ownership on the device node.

`RestartSec=60` is unusually long — TDX quote generation can be slow on
restart; tight loops would hammer the TPM.

### `reth.service`

Runs [`seismic-reth`](https://github.com/SeismicSystems/seismic-reth) as
user `reth` (group `eth`). Execution client — HTTP RPC on `:8545`, WS on
`:8546`, P2P on `:30303`, metrics on `:9001`. Calls into the enclave for
shielded-tx decryption on every `TxSeismic` (type `0x74`).

Gated on `enclave.service` being up, since it'll immediately try to RPC
the enclave for key material.

### `summit.service`

Runs [`summit`](https://github.com/SeismicSystems/summit) as user
`summit` (group `eth`). Consensus client — REST API on `:3030` (reached
via nginx `/summit`), P2P on `:18551`, metrics on `:9002`.

Gated on both `enclave.service` (BLS signing for consensus messages
happens in-enclave) and `reth.service` (EL ↔ CL via Engine API).

Doc gap
---

This readme currently only covers services. Things not documented here
yet that would be worth adding over time: the kernel config rationale
(`kernel/config.d/10-seismic`), build-time flags for reproducibility in
`mkosi.build`, and the relationship between this module and the
`mkosi.profiles/{azure,gcp}/` cloud-specific additions.
