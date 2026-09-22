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
make measure       # Azure TDX measurements -> build/measurements.azure-tdx.json
make measure-gcp   # GCP TDX measurements   -> build/measurements.gcp-tdx.json
```

The two formats differ because Azure and GCP expose TDX quotes through different mechanisms — Azure via `tpm2-tools` + the Microsoft attestation service, GCP via the [`dstack`](https://github.com/Dstack-TEE/dstack) toolchain. The deploy tooling (and the Seismic enclave's attestation path) consume these files to verify that deployed nodes match a known-good image.

`make measure` also stamps a `measurement_id` into the file: the versioned artifact filename (`seismic_{VERSION}.vhd`) these PCRs measure — the same name `make push-azure` uploads as the blob. Consumers of the measurements read which image they bind to from the file itself, with no out-of-band identifier to pass around (or get wrong).

The files are named for the attestation type whose registers they hold (the admission pipeline keys policy records on `attestation_type`), so an image published for both clouds carries one of each under one release.

## Published images

Every push to `seismic` publishes the image it builds, in two places that share one name:

- **The VHD** goes to the `dev` container of the `seismicimages` storage account, as `seismic_{VERSION}.vhd`. That blob URL is the `vhd_blob_url` a deployment boots from; Azure's managed-disk import can only read from blob storage, so the bytes live there.
- **The measurements, the founding inputs and `image.json`** go to a GitHub prerelease tagged `seismic_{VERSION}`, as `measurements.azure-tdx.json`, the four founding inputs below and the record below them, beside a `SHA256SUMS` over all of them and over the `.efi`, the UKI that is the whole image identity (the VHD only wraps it). The tag is the image basename, which is also the `measurement_id` stamped inside the measurements and the short commit of this repo that built it, so every consumer derives the URL from a name it already has:

  ```
  https://github.com/SeismicSystems/seismic-images/releases/download/seismic_{VERSION}/measurements.azure-tdx.json
  ```

  Anything that needs an image's measurements fetches that URL. The publish job asserts the stamp equals `<tag>.vhd` before it creates the release, so name, blob and file agree by construction.

### Founding inputs

A network founded on an image has genesis artifacts that only that image's own code can compute — the execution-layer genesis hash comes out of `seismic-reth`, the consensus config digest out of `summit`, and each is chain identity to the nodes that derive it — and genesis files that have to match the schemas those binaries speak. So the release carries them, as this image has them:

| Asset | What it is |
| ----- | ---------- |
| `seismic-reth`, `summit` | lifted out of this image's initrd, so they are byte for byte the binaries the nodes run: a hash in `SHA256SUMS` names a file inside the image, not a same-rev rebuild (the build pins LTO, `panic=abort`, codegen-units and jemalloc's `LG_VADDR`, so the same source builds to different bytes under other flags). x86-64 Linux, dynamically linked against glibc and OpenSSL 3 as Debian trixie has them |
| `reth-genesis.json` | the execution-layer genesis, read from the `seismic_reth` commit compiled into this image rather than from a branch |
| [`summit-genesis-starter.toml`](summit-genesis-starter.toml) | the consensus parameters this image's `summit` reads, defaults included, every value a per-network choice to review. The parameter set is summit's, so the build checks this file against the `summit` it just lifted out of the image: a parameter added, removed or renamed between pins fails the build rather than shipping a starter no node in the image can load. Summit owns that schema and is the file's long-term home; until it moves there it sits at this repo's root, beside nothing the image build reads |

Both genesis files are inputs to a founding, never a founded network: every value in the starter, and the chain id and allocations in `reth-genesis.json`, is a per-network choice, made before anything is derived from them.

`make release-assets` (the measurements, then `make founding-inputs`) gathers the same files from a local build into `build/`, with the same `SHA256SUMS`, so a rebuild is compared to a release with `sha256sum -c --ignore-missing SHA256SUMS`. The release notes name the three source commits the image was built from; the commit of this repository is the tag itself, and [`sources.yaml`](modules/seismic/sources.yaml) at that commit is the record a rebuild starts from.

### `image.json`

Where the image's bytes are and what they are, in one machine-readable file, so a consumer reads these facts instead of spelling them by convention:

```json
{
  "image": "seismic_2026-09-22.2ee71c",
  "commit": "<the commit of this repository that built it>",
  "sources": {"seismic_reth": "<sha>", "summit": "<sha>", "enclave": "<sha>"},
  "targets": {
    "azure-tdx": {
      "vhd_blob_url": "https://seismicimages.blob.core.windows.net/dev/seismic_2026-09-22.2ee71c.vhd",
      "storage_account_id": "/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Storage/storageAccounts/seismicimages",
      "measurements": "measurements.azure-tdx.json",
      "efi_sha256": "<sha256 of the .efi>"
    }
  }
}
```

`targets` is keyed by attestation type, one entry per cloud the image is published for — Azure only today; a GCP image adds an entry, not a schema. Per target: the artifact the nodes boot from, the storage account's ARM ID (Azure's managed-disk import refuses to read a blob from another subscription or resource group without it, and the URL names the account but neither of those; a SAS URL would avoid the requirement but expires, so it has no place in a release), the measurements asset for that target, and the sha256 of the artifact where it is reproducible — the `.efi`, since the VHD's wrapping is not. Once per file: the image name (the tag, and the stem of `measurement_id`), this repository's commit, and the three source pins from `sources.yaml`. The publish job writes it (`make image-json`, [`scripts/seismic/image_json.sh`](scripts/seismic/image_json.sh)) after the VHD is pushed, asking Azure for the account's ID rather than carrying it in this repo, and renders the release notes from it. It refuses a measurements file and a `SHA256SUMS` that name different UKIs, so the two halves of a release cannot come from different builds. It is the one asset `make release-assets` does not produce, since the ID is a fact about where the bytes were put, not about the build.

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
- [`docs/azure-measurements.md`](docs/azure-measurements.md) — what a node's boot measures on Azure TDX: the register inventory, what each PCR covers, and the `(pcr4, pcr9, pcr11)` guest identity admission uses
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
