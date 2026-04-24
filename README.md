# Seismic Images

**TDX confidential VM images for Seismic nodes.**

Fork of [flashbots/flashbots-images](https://github.com/flashbots/flashbots-images), extended with a `seismic/` module that bundles the Seismic node stack into a reproducible [mkosi](https://github.com/systemd/mkosi)-built image deployable to Azure and GCP Confidential VMs.

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

## What's in the image

| Component                | Purpose                                                                                                         | Source                                                                        |
| ------------------------ | --------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `tdx-init`               | First-boot LUKS provisioning; writes `/persistent/conf/node.json`                                               | [SeismicSystems/tdx-init](https://github.com/SeismicSystems/tdx-init)         |
| `seismic-enclave-server` | Shielded-tx decryption + key derivation; runs in-TEE                                                            | [SeismicSystems/enclave](https://github.com/SeismicSystems/enclave)           |
| `seismic-reth`           | Execution client                                                                                                | [SeismicSystems/seismic-reth](https://github.com/SeismicSystems/seismic-reth) |
| `summit`                 | Consensus client                                                                                                | [SeismicSystems/summit](https://github.com/SeismicSystems/summit)             |
| `nginx` + `certbot`      | HTTPS termination with Let's Encrypt for public RPC/WS/metrics                                                  | Debian                                                                        |

Source-built pins are in [`seismic/mkosi.build`](seismic/mkosi.build).

## Exposed HTTPS endpoints

nginx terminates TLS (Let's Encrypt) and reverse-proxies the following paths to in-TEE services. See [`seismic/mkosi.extra/etc/nginx/node-template.conf`](seismic/mkosi.extra/etc/nginx/node-template.conf).

| Route             | Backend                          | Purpose                                                                                               | Public?                                |
| ----------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `/rpc`            | `reth` `:8545`                   | Ethereum JSON-RPC (shielded tx support via TxSeismic)                                                 | ✅ intended public                      |
| `/ws`             | `reth` `:8546`                   | Ethereum WebSocket RPC                                                                                | ✅ intended public                      |
| `/summit`         | `summit` `:3030`                 | Consensus REST API, incl. `/summit/get_deposit_signature/...` used by the staking UI                  | ⚠️ **overly broad** — see warning below |
| `/enclave`        | `seismic-enclave-server` `:7878` | Enclave API (attestation quotes, public key queries, shielded-tx decryption, key derivation, signing) | ⚠️ **overly broad** — see warning below |
| `/metrics/reth`   | `reth` `:9001`                   | Prometheus metrics                                                                                    | ⚠️ unauthenticated                      |
| `/metrics/summit` | `summit` `:9002`                 | Prometheus metrics                                                                                    | ⚠️ unauthenticated                      |

### ⚠️ Known sharp edges

Everything above listens on the single public `:443`. The intended long-term fix is to split nginx into two tiers — a public server block with only the endpoints that should reach the open internet (`/rpc`, `/ws`, a narrowed `/summit/get_deposit_signature`, attestation-quote queries on `/enclave`), and an internal server block on a separate port with the rest (`/metrics/*`, the full `/summit/*` query surface, operator-facing `/enclave/*`). The deploy tooling would then configure cloud firewall rules (Azure NSG / GCP firewall) to allow the public port from `0.0.0.0/0` and restrict the internal port to the VPC CIDR. Until that split lands, the concrete issues are:

- **`/summit/*` is a blanket proxy.** Summit exposes a JSON-RPC surface (via `jsonrpsee`) with ~20 methods: mostly read-only state queries (`getCheckpoint`, `getValidatorBalance`, `getDeposit`, etc. — analogous to `eth_*` reads and safe to expose), plus `getDepositSignature` which causes a BLS signature in the enclave, plus `sendGenesis` on the genesis-setup API which must *never* be public at runtime. Narrowing requires JSON-RPC-method-level filtering (all calls are `POST /`, so you can't gate by URL path alone). `getDepositSignature` additionally has no rate limiting — trivially DoS-able — and should gain `limit_req` regardless of network controls.
- **`/enclave/*` is a blanket proxy.** Only endpoints *designed* to be public should be reachable (attestation quotes, public-key queries). Operation-causing endpoints (decrypt calldata, sign consensus messages, key derivation) are meant for reth/summit over localhost only. Current config doesn't enforce this; we rely on the enclave's own auth (if any) to reject external callers. Pending the public/internal port split, or narrowing via an explicit allowlist.
- **`/metrics/*` is unauthenticated.** Operationally safe on a locked-down network (the cloud firewall rule above is the right fix), but anyone who can reach the port can scrape sync status, peer info, and resource usage. Do *not* expose the internal port to the open internet without adding basic auth or an IP allowlist on top.

## Our diff vs upstream

You can track [diff with upstream](https://github.com/SeismicSystems/seismic-images/compare/main...seismic) by comparing the `seismic` branch with `origin/main` (which is pinned to the upstream commit we most recently rebased on).

## Where to look next

- [**DEVELOPMENT.md**](DEVELOPMENT.md) — generic mkosi module/kernel-config/reproducibility guidance (from upstream)
- [`seismic/mkosi.conf`](seismic/mkosi.conf) — Debian packages in the image
- [`seismic/mkosi.build`](seismic/mkosi.build) — pinned commits for `reth` / `enclave` / `summit` / `tdx-init`
- [`seismic/mkosi.postinst`](seismic/mkosi.postinst) — systemd services enabled on boot
- [`seismic/mkosi.extra/`](seismic/mkosi.extra/) — per-service unit files and configs
- Deploy tooling lives in a separate repo.

## Running locally

To boot a built image under QEMU for smoke testing (without TDX):

```sh
qemu-system-x86_64 \
    -enable-kvm -machine type=q35,smm=on -m 16384M -nographic \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
    -drive if=pflash,format=raw,file=/usr/share/edk2/x64/OVMF_VARS.4m.fd \
    -kernel build/latest.efi \
    -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 \
    -device virtio-net-pci,netdev=net0
```

TDX-enabled invocation and troubleshooting are in the [upstream README](https://github.com/flashbots/flashbots-images/blob/main/README.md).

## Acknowledgements

Built on [flashbots/flashbots-images](https://github.com/flashbots/flashbots-images). Thanks to the Flashbots team for the mkosi-based TDX image tooling that this repo forks.
