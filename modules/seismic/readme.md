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
| [`mkosi.postinst`](mkosi.postinst)     | Creates users/groups, enables systemd services                                                  |
| [`kernel/config.d/`](kernel/config.d/) | Seismic-specific kernel config snippets                                                         |
| [`mkosi.extra/`](mkosi.extra/)         | Filesystem overlay — systemd units, nginx config, helper scripts                                |

Services
---

Each of the following is a systemd unit under
[`mkosi.extra/etc/systemd/system/`](mkosi.extra/etc/systemd/system/). They're
enabled (added to `minimal.target.wants`) via the loop in
[`mkosi.postinst`](mkosi.postinst).

**Boot chain (services ordered by when they're needed):**

```
  tpm-permissions.service
  (sysinit.target)
          │
          ▼
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

`tpm-permissions` runs at `sysinit.target` (very early). Every later service is transitively after it via `persistent-luks-setup`'s `Requires=tpm-permissions.service` (the LUKS script needs `/dev/tpm0` to enroll/unseal the keyslot). `enclave.service` redundantly re-declares the dependency — harmless, defensive against the chain ever being restructured.

### `tpm-permissions.service`

Runs at `sysinit.target` (very early boot). Changes ownership of
`/dev/tpm*` from `root:root` to `root:tss` and sets mode `660`, so that
processes running as non-root members of the `tss` group can access the
TPM for TDX attestation quote generation.

Needed because `enclave.service` runs as the `enclave` user (which is in
the `tss` group), not as root. Without this service, the enclave would
have no way to produce attestation quotes.

`libtss2-esys-…` and `libtss2-tctildr0t64` (in `mkosi.conf` Packages) are
the TPM2 libraries the enclave links against.

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

`Requires=tpm-permissions.service` because the script reads `/dev/tpm0`
during enroll/unseal. `Restart=on-failure RestartSec=5` to ride out
transient cases like the data disk not yet attached or the vTPM not yet
ready; systemd gives up after a few cycles, surfacing a hard failure if
the underlying issue is permanent.

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
provisioner POSTs the node's configuration (domain name, certbot email)
via HTTP and writes it to `/persistent/conf/node.json`. On every
subsequent boot the unit is a no-op (config file already exists, binary
exits immediately).

Runs as the `tdx-init` system user (group `eth`). `ExecStartPre=+...`
ensures `/persistent/conf` exists with `tdx-init:eth` ownership before
the binary writes into it.

`setup-nginx-ssl` reads the domain + email from `node.json` for certbot.
The other services (reth, enclave, summit) take their args statically
from the systemd unit files — they don't touch `node.json`, so in
principle they could start without waiting for tdx-init, but the current
boot chain serializes them after it for simplicity.

### `nginx-ssl-setup.service`

Oneshot. Reads domain+email from `/persistent/conf/node.json`, templates
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
on `:7878` as user `enclave` (group `eth`, supplementary group `tss` for
TPM access). The enclave is the trust root of the node — holds the
network encryption key, validator BLS keys, and derives per-purpose
secrets sealed to the TDX measurement. See the enclave repo for details
on the RPC surface.

Depends on `persistent-luks-setup` (needs `/persistent` for sealed state),
`nginx-ssl-setup` (for the public HTTPS endpoint), and `tpm-permissions`
(for attestation quote generation).

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
