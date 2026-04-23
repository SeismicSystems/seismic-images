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
| `seismic-reth`           | Execution client                                                                                                | [SeismicSystems/seismic-reth](https://github.com/SeismicSystems/seismic-reth) |
| `seismic-enclave-server` | Shielded-tx decryption + key derivation; runs in-TEE                                                            | [SeismicSystems/enclave](https://github.com/SeismicSystems/enclave)           |
| `summit`                 | Consensus client                                                                                                | [SeismicSystems/summit](https://github.com/SeismicSystems/summit)             |
| `staking-ui`             | Staking dApp served at `/staking`                                                                               | [SeismicSystems/staking-ui](https://github.com/SeismicSystems/staking-ui)     |
| `nginx` + `certbot`      | HTTPS termination with Let's Encrypt for public RPC/WS/metrics                                                  | Debian                                                                        |
| `nftables`               | Firewall — see [`seismic/mkosi.extra/etc/nftables/seismic.conf`](seismic/mkosi.extra/etc/nftables/seismic.conf) | Debian                                                                        |

Observability (Prometheus, Grafana) runs externally — reth metrics are exposed at `https://{domain}/metrics/reth`, summit metrics at `https://{domain}/metrics/summit`. Keeping them out of the image means bumping Prometheus or a Grafana dashboard doesn't change the TDX measurement.

Source-built pins are in [`seismic/mkosi.build`](seismic/mkosi.build).

## Our diff vs upstream

You can track [diff with upstream](https://github.com/SeismicSystems/seismic-images/compare/main...seismic) by comparing the `seismic` branch with `origin/main` (which is pinned to the upstream commit we most recently rebased on).

## Where to look next

- [**DEVELOPMENT.md**](DEVELOPMENT.md) — generic mkosi module/kernel-config/reproducibility guidance (from upstream)
- [`seismic/mkosi.conf`](seismic/mkosi.conf) — Debian packages in the image
- [`seismic/mkosi.build`](seismic/mkosi.build) — pinned commits for `reth` / `enclave` / `summit` / `tdx-init` / `staking-ui`
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
