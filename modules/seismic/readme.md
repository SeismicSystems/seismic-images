Seismic Image Module
===

This directory is the Seismic-specific mkosi module — everything that layers on
top of [`shared/`](../../shared/) to turn a generic Debian base into a Seismic
node.

Top-level files at a glance:

| File                                   | Role                                                                                            |
| -------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [`mkosi.conf`](mkosi.conf)             | Debian packages (`cryptsetup`, `jq`, …) + build packages                                        |
| [`mkosi.build`](mkosi.build)           | Source-builds: pinned commits of `tdx-init`, `seismic-reth`, `seismic-attestation-service`, `seismic-custodian-service`, `summit`, `caddy` |
| [`sources.yaml`](sources.yaml)         | Pinned git refs read by `mkosi.build` (structured manifest, Renovate/Dependabot-friendly)       |
| [`mkosi.postinst`](mkosi.postinst)     | Creates users/groups, enables systemd services                                                  |
| [`kernel/config.d/`](kernel/config.d/) | Seismic-specific kernel config snippets                                                         |
| [`mkosi.extra/`](mkosi.extra/)         | Filesystem overlay — systemd units, the Caddyfile, helper scripts                               |

What the resulting boot measures into the vTPM on Azure — the register
inventory, and the `(pcr4, pcr9, pcr11)` guest identity admission binds — is
in [`docs/azure-measurements.md`](../../docs/azure-measurements.md).

What ends up in the image
---

Files in this directory aren't all part of the produced image — some are
build-inputs only. The image rootfs is the union of four channels:

| Channel                                   | What it puts in the image                                                                                                                                                                     |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`mkosi.extra/`](mkosi.extra/)            | Copied wholesale at matching paths — see tree below.                                                                                                                                          |
| `Packages=` in [`mkosi.conf`](mkosi.conf) | apt-installed Debian packages: `cryptsetup`, `jq`, `libtss2-*`, `lz4`                                                                                |
| [`mkosi.build`](mkosi.build)              | Compiled binaries written to `$DESTDIR`: `tdx-init`, `seismic-reth`, `seismic-attestation-service`, `seismic-custodian-service`, `summit`, `caddy` → `/usr/bin/`              |
| [`mkosi.postinst`](mkosi.postinst)        | Image-fs mutations: system users + `engine-api`/`custodian-ipc`/`conf`/`tpm` groups in `/etc/{passwd,group}`, services symlinked into `/etc/systemd/system/minimal.target.wants/`, `/usr/bin` scripts (`persistent-luks-setup`, `summit-persist`) made executable |

`mkosi.extra/` lays out exactly what its name suggests — the same paths
relative to the image root:

```
mkosi.extra/
├── etc/
│   ├── caddy/Caddyfile                     → /etc/caddy/Caddyfile
│   ├── security/limits.d/nofile.conf       → /etc/security/limits.d/nofile.conf
│   ├── seismic/tmpfiles-persistent.conf    → /etc/seismic/tmpfiles-persistent.conf
│   ├── tmpfiles.d/seismic-runtime.conf     → /etc/tmpfiles.d/seismic-runtime.conf
│   ├── systemd/system/*.{service,target}   → /etc/systemd/system/...
│   └── udev/rules.d/60-tpm-permissions.rules → /etc/udev/rules.d/...
└── usr/
    └── bin/{persistent-luks-setup,summit-persist} → /usr/bin/...
```

Module-root files that are **not** in the image: `mkosi.conf`,
`mkosi.build`, `mkosi.postinst`, `sources.yaml`, `kernel/config.d/`.
They're read at build time and never copied to `$DESTDIR`. This readme is
documentation only — neither read at build time nor shipped.

Services
---

Each unit lives under
[`mkosi.extra/etc/systemd/system/`](mkosi.extra/etc/systemd/system/) and
is enabled into `minimal.target.wants` by the loop in
[`mkosi.postinst`](mkosi.postinst); the three summit units come in
through `summit.target`. What each process is, and the order a boot
walks them in, is
[the node lifecycle](https://github.com/SeismicSystems/seismic/blob/main/docs/tee/architecture.md#node-lifecycle-power-on-to-serving).
The edges themselves are each unit's `After=`/`Requires=` lines; on a
running node, `systemctl list-dependencies minimal.target` prints them.

Two things the boot needs have no unit:

- **TPM device perms** come from a udev rule,
  [`60-tpm-permissions.rules`](mkosi.extra/etc/udev/rules.d/60-tpm-permissions.rules),
  applied the moment the kernel publishes the device.
- **`/persistent/<svc>` ownership and mode** come from
  [`tmpfiles-persistent.conf`](mkosi.extra/etc/seismic/tmpfiles-persistent.conf),
  applied by `persistent-luks-setup.service`'s `ExecStartPost` once the
  LUKS volume is mounted.

### Users and groups

Created in [`mkosi.postinst`](mkosi.postinst). Each service runs as its
own system user; the groups are the only way one reaches another's
files, sockets or devices.

| User | Supplementary groups | Runs |
| --- | --- | --- |
| `tdx-init` | `custodian-ipc` | `tdx-init.service` |
| `custodian` | `conf` | `custodian.service` |
| `attestation` | `conf`, `custodian-ipc`, `tpm` | `attestation.service` |
| `reth` | `conf`, `engine-api`, `custodian-ipc` | `reth.service` (primary group `engine-api`) |
| `summit` | `conf`, `engine-api` | `summit-keygen`, `summit-persist`, `summit` |
| `caddy` | | `caddy.service` |
| root | | `persistent-luks-setup` |

| Group | Grants |
| --- | --- |
| `conf` | reading `/run/seismic/conf` |
| `custodian-ipc` | connecting to the custodian socket, where the unit's `--allow` grants then decide what each user may call; reading `candidate-tx-io-pk` |
| `engine-api` | summit connecting to reth's Engine API socket |
| `tpm` | opening `/dev/tpm*`. `attestation` is the only member: a process that can quote arbitrary `report_data` can have a peer wrap `root_key` to a key of its own ([one process opens the TPM](https://github.com/SeismicSystems/seismic/blob/main/docs/tee/architecture.md#one-process-opens-the-tpm)) |

### Directories

Runtime dirs are tmpfs, created each boot by
[`tmpfiles.d/seismic-runtime.conf`](mkosi.extra/etc/tmpfiles.d/seismic-runtime.conf)
unless a unit declares them with `RuntimeDirectory=`. Persistent dirs are
on the LUKS volume, from
[`tmpfiles-persistent.conf`](mkosi.extra/etc/seismic/tmpfiles-persistent.conf).

| Path | Owner, mode | Written by | Read by |
| --- | --- | --- | --- |
| `/run/seismic/conf` | `tdx-init:conf 2750` | tdx-init | `conf` members and root ([files below](#tdx-initservice)) |
| `/run/seismic/custodian` | `custodian:custodian-ipc 2750` | the custodian: its socket, the LUKS keyfile (0400), and `candidate-tx-io-pk` (0640) | `custodian-ipc` members connect; `persistent-luks-setup` reads and shreds the keyfile; the attestation service and tdx-init read `candidate-tx-io-pk` |
| `/run/seismic/status` | `root:root 0755` | `persistent-luks-setup` (wipe progress) | the attestation service |
| `/run/seismic/summit` | `summit:summit 0755` | `summit-keygen`, `summit-persist` | the attestation service; read-only to `summit.service` |
| `/run/seismic/summit/keys` | `summit:summit 0700` | `summit-keygen` | `summit-persist`; inaccessible to `summit.service` |
| `/run/reth-engine` | `reth:engine-api 0750` (`RuntimeDirectory=`) | reth's Engine API socket | summit |
| `/persistent/caddy` | `caddy:caddy 0700` | caddy | caddy |
| `/persistent/reth` | `reth:reth 0700` | reth | reth |
| `/persistent/summit/db` | `summit:summit 0700` | summit | summit |
| `/persistent/summit/keys` | `summit:summit 0700` | `summit-persist` | summit, read-only |

Setgid on the two `2750` dirs gives every file created in them the
dir's group, so the writer needs no membership of its own.

### `tdx-init.service`

Blocks on `:8080` every boot until the operator POSTs the node's
configuration, then writes one file per consumer into
`/run/seismic/conf` and drops the `.tdx-init-done` sentinel:

| File | Read by |
| --- | --- |
| `domain.env` | systemd for `caddy.service` |
| `attestation.env` | the attestation service, once the sentinel appears |
| `network-manifest.json` | the attestation service, whose quote window it closes; the custodian, for its `founding_tx_io_pk` |
| `reth-p2p.env` | systemd for `reth.service` |
| `reth-genesis.json` | reth (`--chain`) |
| `summit.env` | systemd for `summit.service` |
| `summit-genesis.toml` | summit (`--genesis-path`) |

### `summit.target`: `summit-keygen`, `summit-persist`, `summit`

Summit's keys must exist before the manifest pins them, and its keystore
opens only with LUKS, after the POST. Two oneshots carry the keys across
that gap
([summit's keys before LUKS](https://github.com/SeismicSystems/seismic/blob/main/docs/tee/network-founding.md#summits-keys-before-luks)):

- **`summit-keygen`** runs at boot: `summit keys generate
  --no-overwrite` into `/run/seismic/summit/keys`, then the public halves from
  `summit keys show --json` into `/run/seismic/summit/public-keys.json`.
- **`summit-persist`** runs after `persistent-luks-setup` and decides
  from the keystore on disk; the cases are in the
  [script](mkosi.extra/usr/bin/summit-persist)'s header. Every
  successful run rewrites the public-keys file from the keystore, which
  is what the launch checks read.

The start order, and what restarting each unit reaches, are drawn in
[`summit.target`](mkosi.extra/etc/systemd/system/summit.target).

### `custodian.service`

Starts at boot, mints a candidate `root_key` in RAM, and writes its
`tx_io_pk@0` to `/run/seismic/custodian/candidate-tx-io-pk`, so the
founding harvest can quote it before any configuration exists. When the
attestation service first asks for `root_key`, after the POST, the custodian
reads the manifest's pin: it keeps the candidate if the pin names it, and
otherwise discards it and installs only a fetched key that derives the pin.

### `attestation.service`

Two listeners. `:7879` serves the founding harvest from boot (summit's
public keys and the custodian's candidate `tx_io_pk@0`), plain HTTP, and
must stay operator-CIDR-only permanently: the quote window reopens every
boot, since the manifest that closes it lives on tmpfs.
`:7878` binds only once the custodian holds `root_key`, so the open port
is the readiness signal deploy tooling waits on.

`RestartSec=60` is unusually long: quote generation can be slow, and a
tight restart loop would hammer the TPM.

### `persistent-luks-setup.service`

Runs [`persistent-luks-setup`](mkosi.extra/usr/bin/persistent-luks-setup);
its header comment has the design (key handoff, header MAC,
detached-header open). `Restart=on-failure` rides out a disk not yet
attached or a slow root-key bootstrap.

The disk defaults to `/dev/disk/by-path/*10` (Azure LUN 10). Other
clouds override it with globs in
`/etc/seismic-images/persistent-disk-glob`. TODO: have deploy tooling
write the override at provisioning time.

### `caddy.service`

The public HTTPS proxy on `:443`, as the unprivileged `caddy` user with
`CAP_NET_BIND_SERVICE` alone. The
[Caddyfile](mkosi.extra/etc/caddy/Caddyfile) is static and in the
image, so it is measured and the same on every node; the only per-node
input is the domain name and ACME contact from `domain.env`, which
systemd reads for it.

Caddy takes and renews its certificate itself, from Let's Encrypt or,
when that fails, ZeroSSL, over TLS-ALPN-01 on `:443`, and retries a
failed attempt in-process.
Nothing listens on `:80`, there is no admin endpoint, and HTTP/3 is
off. The certificate, its key and the ACME account live in
`/persistent/caddy`, so a reboot keeps them. Nothing depends on the
unit: a node without a certificate has no public HTTPS, while reth and
summit run regardless.

### `reth.service` and `summit.service`

| | reth | summit |
| --- | --- | --- |
| Public | devp2p `:30303` TCP+UDP (discv5 only) | P2P `:18551` |
| Loopback | RPC `:8545`, WS `:8546`, metrics `:9001` | REST `:3030` (Caddy `/summit`), metrics `:9002` |

reth fetches its purpose keys from the custodian socket at startup;
`persistent-luks-setup` finishing implies the custodian holds
`root_key`. summit drives reth over the Engine API socket and only
reads its keystore.

Doc gap
---

This readme currently only covers services. Things not documented here
yet that would be worth adding over time: the kernel config rationale
(`kernel/config.d/10-seismic`), build-time flags for reproducibility in
`mkosi.build`, and the relationship between this module and the
`mkosi.profiles/{azure,gcp}/` cloud-specific additions.
