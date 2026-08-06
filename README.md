# Seismic Images

**TDX confidential VM images for Seismic nodes.**

Fork of [flashbots/flashbots-images](https://github.com/flashbots/flashbots-images), extended with a `modules/seismic/` module that bundles the Seismic node stack into a reproducible [mkosi](https://github.com/systemd/mkosi)-built image deployable to Azure and GCP Confidential VMs.

## Quick start

Requires [Lima](https://lima-vm.io/) on macOS/Linux. For alternatives (native Nix, etc.), see [DEVELOPMENT.md](DEVELOPMENT.md).

```sh
make build IMAGE=seismic
```

Produces in `build/`:

| File                                 | Purpose                                                        |
| ------------------------------------ | -------------------------------------------------------------- |
| `seismic_{VERSION}.efi`              | Unified Kernel Image — the boot artifact, shared across clouds |
| `seismic_{VERSION}.vhd`              | Azure Confidential VM disk image                               |
| `seismic_{VERSION}.tar.gz`           | GCP Confidential VM custom-image tarball                       |
| `seismic_{VERSION}.manifest`         | JSON SBOM of every Debian package in the image                 |
| `seismic_{VERSION}.{initrd,vmlinuz}` | Debug extracts of the UKI's contents                           |

`{VERSION}` is `{commit-date}.{commit-hash}[-dirty]` — see [mkosi.version](mkosi.version).

## TDX measurements

Generate expected measurement values (RTMRs, MRTD) for the built UKI so a verifier can attest that a running node booted from exactly this image:

```sh
make measure       # Azure-style measurements -> build/measurements.json
make measure-gcp   # GCP-style measurements   -> build/gcp_measurements.json
```

The two formats differ because Azure and GCP expose TDX quotes through different mechanisms — Azure via `tpm2-tools` + the Microsoft attestation service, GCP via the [`dstack`](https://github.com/Dstack-TEE/dstack) toolchain. The deploy tooling (and the Seismic enclave's attestation path) consume these files to verify that deployed nodes match a known-good image.

`make measure` also stamps a `measurement_id` into the file: the versioned artifact filename (`seismic_{VERSION}.vhd`) these PCRs measure — the same name `make push-azure` uploads as the blob. Consumers of the measurements read which image they bind to from the file itself, with no out-of-band identifier to pass around (or get wrong).

## What's in the image

| Component                | Purpose                                                           | Source                                                                                                                       |
| ------------------------ | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `tdx-init`               | First-boot LUKS provisioning; writes `/persistent/conf/node.json` | [SeismicSystems/enclave/bin/tdx-init](https://github.com/SeismicSystems/enclave/tree/seismic/bin/tdx-init)             |
| `seismic-custodian-service` | Owns `root_key`; serves key derivation and root-key wrapping over a local Unix socket only | [SeismicSystems/enclave/bin/custodian-service](https://github.com/SeismicSystems/enclave/tree/seismic/bin/custodian-service) |
| `seismic-attestation-service` | Attestation evidence + peer root-key bootstrap; network-facing on `:7878` | [SeismicSystems/enclave/bin/attestation-service](https://github.com/SeismicSystems/enclave/tree/seismic/bin/attestation-service) |
| `seismic-reth`           | Execution client                                                  | [SeismicSystems/seismic-reth](https://github.com/SeismicSystems/seismic-reth)                                                |
| `summit`                 | Consensus client                                                  | [SeismicSystems/summit](https://github.com/SeismicSystems/summit)                                                            |
| `nginx` + `certbot`      | HTTPS termination with Let's Encrypt for public RPC/WS/metrics    | Debian                                                                                                                       |

Source-built pins are in [`modules/seismic/mkosi.build`](modules/seismic/mkosi.build).

## Exposed HTTPS endpoints

nginx terminates TLS (Let's Encrypt) and reverse-proxies the following paths to in-TEE services. See [`modules/seismic/mkosi.extra/etc/nginx/node-template.conf`](modules/seismic/mkosi.extra/etc/nginx/node-template.conf).

| Route             | Backend                          | Purpose                                                                                               | Public?                                |
| ----------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `/rpc`            | `reth` `:8545`                   | Ethereum JSON-RPC (shielded tx support via TxSeismic)                                                 | ✅ intended public                      |
| `/ws`             | `reth` `:8546`                   | Ethereum WebSocket RPC                                                                                | ✅ intended public                      |
| `/summit`         | `summit` `:3030`                 | Consensus REST API, incl. `/summit/get_deposit_signature/...` used by the staking UI                  | ⚠️ **overly broad** — see warning below |
| `/attestation`    | `attestation-service` `:7878` | Attestation API (tx-io attestation evidence, health/LUKS status, reth's purpose-key fetch, peer root-key bootstrap) | ⚠️ **overly broad** — see warning below |
| `/metrics/reth`   | `reth` `:9001`                   | Prometheus metrics                                                                                    | ⚠️ unauthenticated                      |
| `/metrics/summit` | `summit` `:9002`                 | Prometheus metrics                                                                                    | ⚠️ unauthenticated                      |

### ⚠️ Known sharp edges

Everything above listens on the single public `:443`. The intended long-term fix is to split nginx into two tiers — a public server block with only the endpoints that should reach the open internet (`/rpc`, `/ws`, a narrowed `/summit/get_deposit_signature`, attestation-quote queries on `/attestation`), and an internal server block on a separate port with the rest (`/metrics/*`, the full `/summit/*` query surface, operator-facing `/attestation/*`). The deploy tooling would then configure cloud firewall rules (Azure NSG / GCP firewall) to allow the public port from `0.0.0.0/0` and restrict the internal port to the VPC CIDR. Until that split lands, the concrete issues are:

- **`/summit/*` is a blanket proxy.** Summit exposes a JSON-RPC surface (via `jsonrpsee`) with ~20 methods: mostly read-only state queries (`getCheckpoint`, `getValidatorBalance`, `getDeposit`, etc. — analogous to `eth_*` reads and safe to expose), plus `getDepositSignature` which causes a BLS signature in the enclave, plus `sendGenesis` on the genesis-setup API which must *never* be public at runtime. Narrowing requires JSON-RPC-method-level filtering (all calls are `POST /`, so you can't gate by URL path alone). `getDepositSignature` additionally has no rate limiting — trivially DoS-able — and should gain `limit_req` regardless of network controls.
- **`/attestation/*` is a blanket proxy.** Only endpoints *designed* to be public should be reachable (attestation quotes, health/status queries). `getPurposeKeys` returns secret key material and is meant for reth over localhost only. Current config doesn't enforce this, and the attestation service has no caller auth of its own — anyone who can reach the port can call `getPurposeKeys`. Pending the public/internal port split, or narrowing via an explicit allowlist — and `getPurposeKeys` retires entirely once reth fetches its keys from the custodian socket.
- **`/metrics/*` is unauthenticated.** Operationally safe on a locked-down network (the cloud firewall rule above is the right fix), but anyone who can reach the port can scrape sync status, peer info, and resource usage. Do *not* expose the internal port to the open internet without adding basic auth or an IP allowlist on top.

## Our diff vs upstream

You can track [diff with upstream](https://github.com/SeismicSystems/seismic-images/compare/main...seismic) by comparing the `seismic` branch with `origin/main` (which is pinned to the upstream commit we most recently rebased on).

## Where to look next

- [**DEVELOPMENT.md**](DEVELOPMENT.md) — generic mkosi module/kernel-config/reproducibility guidance (from upstream)
- [`modules/seismic/mkosi.conf`](modules/seismic/mkosi.conf) — Debian packages in the image
- [`modules/seismic/mkosi.build`](modules/seismic/mkosi.build) — pinned commits for `reth` / `enclave` / `summit` / `tdx-init`
- [`modules/seismic/mkosi.postinst`](modules/seismic/mkosi.postinst) — systemd services enabled on boot
- [`modules/seismic/mkosi.extra/`](modules/seismic/mkosi.extra/) — per-service unit files and configs
- Deploy tooling lives in a separate repo.

## Running locally

Boot a built image under QEMU for smoke testing (without TDX). 
TDX-enabled invocation and troubleshooting are in the [upstream README](https://github.com/flashbots/flashbots-images/blob/main/README.md).

### macOS via Lima

Uses the Lima VM you already run for builds. Nested virt isn't available, so boot goes through software emulation (TCG) — slow (~10 min to reach systemd) but works without any extra setup on the host.

Enter the Lima VM:

```sh
limactl shell <your-lima-vm>   # e.g. tee-builder-<hash>
cd ~/mnt                       # where the repo is mounted
```

Everything below runs *inside* that shell.

One-time setup:

```sh
sudo apt-get install -y qemu-system-x86 ovmf
cp /usr/share/OVMF/OVMF_VARS.fd /tmp/OVMF_VARS.fd   # writable NVRAM
```

Boot:

```sh
qemu-system-x86_64 \
    -accel tcg -machine type=q35,smm=on -m 1024M -nographic \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
    -kernel build/latest.efi \
    -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 \
    -device virtio-net-pci,netdev=net0
```

Exit QEMU with `Ctrl-a x`.

### Linux with KVM

> **TODO: not validated in this repo.** The upstream-inherited command below assumes bare-metal Linux with KVM access and should boot in seconds, but hasn't been tested in our fork — please update this section if you run it successfully.

```sh
qemu-system-x86_64 \
    -enable-kvm -machine type=q35,smm=on -m 16384M -nographic \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.secboot.fd \
    -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
    -kernel build/latest.efi \
    -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 \
    -device virtio-net-pci,netdev=net0
```

## Acknowledgements

Built on [flashbots/flashbots-images](https://github.com/flashbots/flashbots-images). Thanks to the Flashbots team for the mkosi-based TDX image tooling that this repo forks.
