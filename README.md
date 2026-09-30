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

What a node's boot measures on Azure, register by register, and the `(pcr4, pcr9, pcr11)` guest identity admission binds, is in [`docs/azure-measurements.md`](docs/azure-measurements.md).

## Published images

Every push to `seismic` publishes the image it builds, in two places that share one name:

- **The VHD** goes to the `dev` container of the `seismicimages` storage account, as `seismic_{VERSION}.vhd`. That blob URL is the `vhd_blob_url` a deployment boots from; Azure's managed-disk import can only read from blob storage, so the bytes live there.
- **The measurements, the founding inputs and `image.json`** go to a GitHub prerelease tagged `seismic_{VERSION}`, as `measurements.azure-tdx.json`, the four founding inputs below and the record below them, beside a `SHA256SUMS` over all of them and over the `.efi`, the UKI that is the whole image identity (the VHD only wraps it). The tag is the image basename, which is also the `measurement_id` stamped inside the measurements and the short commit of this repo that built it, so every consumer derives the URL from a name it already has:

  ```
  https://github.com/SeismicSystems/seismic-images/releases/download/seismic_{VERSION}/measurements.azure-tdx.json
  ```

  Anything that needs an image's measurements fetches that URL. The build asserts the stamp names the VHD it built, `image.json` takes the image's name from the stamp, and the publish job pushes the VHD to the blob `image.json` names and tags the release with that name, so name, blob and file agree by construction.

Every release asset carries a [build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations/using-artifact-attestations-to-establish-provenance-for-builds): before the release exists, the publish job signs a SLSA provenance statement over each asset's digest with a short-lived Sigstore certificate issued to this workflow on this branch at the building commit, and the signature is logged in Rekor. `SHA256SUMS` cannot catch a swapped asset on its own — whoever can replace an asset can replace the checksum file beside it — while an attestation names the workflow, ref and commit that signed it, so a replacement would have to be built by this workflow from a commit on `seismic`, in the open. Verify any asset against the workflow and the branch, not just the repository, so a file signed by another workflow or from another ref is refused:

```sh
gh attestation verify summit --repo SeismicSystems/seismic-images \
    --cert-identity https://github.com/SeismicSystems/seismic-images/.github/workflows/seismic.yml@refs/heads/seismic
```

The VHD is not attested: it is not reproducible, and the `.efi` it wraps is listed in `SHA256SUMS`, which is. The attestation says who built the bytes and from which commit, not that the source is sound; the reproducibility build is the other half — anyone can rebuild that commit and compare.

### Founding inputs

A network founded on an image has genesis artifacts that only that image's own code can compute — the execution-layer genesis hash comes out of `seismic-reth`, the consensus config digest out of `summit`, and each is chain identity to the nodes that derive it — and genesis files that have to match the schemas those binaries speak. So the release carries them, as this image has them:

| Asset | What it is |
| ----- | ---------- |
| `seismic-reth`, `summit` | lifted out of this image's initrd, so they are byte for byte the binaries the nodes run: a hash in `SHA256SUMS` names a file inside the image, not a same-rev rebuild (the build pins LTO, `panic=abort`, codegen-units and jemalloc's `LG_VADDR`, so the same source builds to different bytes under other flags). x86-64 Linux, dynamically linked against glibc and OpenSSL 3 as Debian trixie has them |
| `reth-genesis.json` | the execution-layer genesis, read from the `seismic_reth` commit compiled into this image rather than from a branch |
| [`summit-genesis-starter.toml`](summit-genesis-starter.toml) | the consensus parameters this image's `summit` reads, defaults included, every value a per-network choice to review. The parameter set is summit's, so the build checks this file against the `summit` it just lifted out of the image: a parameter added, removed or renamed between pins fails the build rather than shipping a starter no node in the image can load. Summit owns that schema and is the file's long-term home; until it moves there it sits at this repo's root, beside nothing the image build reads |

Both genesis files are inputs to a founding, never a founded network: every value in the starter, and the chain id and allocations in `reth-genesis.json`, is a per-network choice, made before anything is derived from them.

`make release-assets` (the measurements, the founding inputs, then `image.json`) gathers the same files from a local build into `build/`, with the same `SHA256SUMS`, so a rebuild is compared to a release with `sha256sum -c --ignore-missing SHA256SUMS`. The release notes name the three source commits the image was built from; the commit of this repository is the tag itself, and [`sources.yaml`](modules/seismic/sources.yaml) at that commit is the record a rebuild starts from.

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

`targets` is keyed by attestation type, one entry per cloud the image is published for: `azure-tdx` (the VHD's blob and storage account) and `gcp-tdx` (the registered GCE image and the tarball it was made from). Per target: the artifact the nodes boot from, the storage account's ARM ID (Azure's managed-disk import refuses to read a blob from another subscription or resource group without it, and the URL names the account but neither of those; a SAS URL would avoid the requirement but expires, so it has no place in a release), the measurements asset for that target, and the sha256 of the artifact where it is reproducible — the `.efi`, since neither wrapping is. Once per file: the image name (the tag, and the stem of each `measurement_id`), this repository's commit, and the three source pins from `sources.yaml`. The build writes it, in `make release-assets` ([`scripts/seismic/release_assets.sh`](scripts/seismic/release_assets.sh)), before the bytes are anywhere: the blob URL and the GCE image are where the VHD and the tarball will go, in the container `AZURE_CONTAINER` picks and the bucket and project `GCP_BUCKET` and `GCP_PROJECT` name, and the account's ARM ID comes from the Makefile — not a secret, since every `image.json` carries it. The publish job then makes the record true: `make push-azure` ([`scripts/seismic/push_azure.sh`](scripts/seismic/push_azure.sh)) uploads the VHD to the blob `image.json` names and `make push-gcp` ([`scripts/seismic/push_gcp.sh`](scripts/seismic/push_gcp.sh)) uploads the tarball to the bucket and registers the GCE image it names, each reading its destination from the record rather than from settings of its own, and the release notes are rendered from it. It refuses measurements stamped for any other UKI, so the halves of a release cannot come from different builds.

## What's in the image

The Seismic node stack: [`seismic-reth`](https://github.com/SeismicSystems/seismic-reth),
[`summit`](https://github.com/SeismicSystems/summit), and from
[`enclave`](https://github.com/SeismicSystems/enclave) `tdx-init`, the custodian and the
attestation service, all built from the commits pinned in [`sources.yaml`](modules/seismic/sources.yaml).
[`modules/seismic/readme.md`](modules/seismic/readme.md) covers how they are assembled:
units, users and groups, directories.

## Exposed endpoints

The image terminates no TLS: services listen in plain HTTP, and public HTTPS ends at a front outside the node ([why](https://github.com/SeismicSystems/seismic/blob/main/docs/tee/decisions/2026-10-public-rpc-trust.md)). The image decides what binds where; the cloud firewall decides who reaches it.

| Firewall admits | Port             | Service             | Purpose                                     |
| --------------- | ---------------- | ------------------- | ------------------------------------------- |
| Anyone          | `:30303` TCP+UDP | `reth`              | devp2p (discv5 only)                        |
|                 | `:18551`         | `summit`            | consensus P2P                               |
|                 | `:7878`          | attestation service | attestation API, root-key bootstrap; browsers via the front |
| The front       | `:8545`          | `reth`              | JSON-RPC; also the operator's CLI           |
|                 | `:8546`          | `reth`              | WebSocket RPC                               |
|                 | `:3030`          | `summit`            | read-only consensus RPC                     |
| The operator    | `:8080`          | `tdx-init`          | config POST                                 |
|                 | `:7879`          | attestation service | founding harvest                            |
| Monitoring      | `:9001`          | `reth`              | metrics, unauthenticated                    |
|                 | `:9002`          | `summit`            | metrics, unauthenticated                    |
| Loopback only   | `:8551`          | `reth`              | Engine API over HTTP, unused                |
|                 | `:3031`          | `summit`            | admin RPC, signs with the validator key     |

The peer ports need no allowlist: peers authenticate at the application layer.

### The front

| Path           | Port    |
| -------------- | ------- |
| `/rpc`         | `:8545` |
| `/ws`          | `:8546` |
| `/summit`      | `:3030` |
| `/attestation` | `:7878` |

Match each path exactly, forward to `/`, and 404 the rest. Allow WebSocket upgrades on `/ws` only. Rate-limit here: neither reth nor summit does.

## Our diff vs upstream

You can track [diff with upstream](https://github.com/SeismicSystems/seismic-images/compare/main...seismic) by comparing the `seismic` branch with `origin/main` (which is pinned to the upstream commit we most recently rebased on).

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
