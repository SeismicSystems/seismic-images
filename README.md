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

Predict the registers a node booted from the built UKI will attest, so a verifier can check that a running node booted from exactly this image:

```sh
make measure       # Azure TDX: the vTPM PCRs   -> build/measurements.azure-tdx.json
make measure-gcp   # GCP TDX: RTMR1 and RTMR2   -> build/measurements.gcp-tdx.json
```

The two hold different registers because the two clouds attest differently. On Azure the guest's identity is in the vTPM's PCRs, which `measured-boot` replays from the UKI. On GCP there is no vTPM: the firmware and systemd-stub extend the UKI, the kernel command line and the initrd into the TDX RTMRs, which `attest measure gcp` replays from the UKI. The deploy tooling (and the Seismic enclave's attestation path) consume these files to verify that deployed nodes match a known-good image.

Each file is stamped with a `measurement_id`, the versioned artifact its registers measure: `seismic_{VERSION}.vhd` for Azure and `seismic_{VERSION}.tar.gz` for GCP, the names `make push-azure` and `make push-gcp` upload. Consumers of the measurements read which image they bind to from the file itself, with no out-of-band identifier to pass around (or get wrong).

The files are named for the attestation type whose registers they hold (the admission pipeline keys policy records on `attestation_type`), so an image published for both clouds carries one of each under one release.

What a node's boot measures on Azure, register by register, and the `(pcr4, pcr9, pcr11)` guest identity admission binds, is in [`docs/azure-measurements.md`](docs/azure-measurements.md). What a GCP boot extends into RTMR1 and RTMR2, event by event, is in [`docs/gcp-rtmr-events.json`](docs/gcp-rtmr-events.json), captured from a live guest; admission binds `(rtmr1, rtmr2)`.

## Published images

Every push to `seismic` publishes the image it builds, in three places that share one name:

- **The VHD** goes to the `dev` container of the `seismicimages` storage account, as `seismic_{VERSION}.vhd`. That blob URL is the `vhd_blob_url` an Azure deployment boots from; Azure's managed-disk import can only read from blob storage, so the bytes live there.
- **The tarball** goes to the `seismic-images` bucket, as `seismic_{VERSION}.tar.gz`, and is registered from there in project `seismic-images` as the GCE image `seismic-{VERSION}` with `.` as `-`, the `gce_image` a GCE deployment boots from. GCE boots a registered image, not a bucket object, so `make push-gcp` is those two steps.
- **The measurements, the founding inputs and `image.json`** go to a GitHub prerelease tagged `seismic_{VERSION}`, as `measurements.azure-tdx.json` and `measurements.gcp-tdx.json`, the four founding inputs below and the record below them, beside a `SHA256SUMS` over all of them and over the `.efi`, the UKI that is the whole image identity (the VHD and the tarball only wrap it). The tag is the image basename, which is also the `measurement_id` stamped inside the measurements and the short commit of this repo that built it, so every consumer derives the URL from a name it already has:

  ```
  https://github.com/SeismicSystems/seismic-images/releases/download/seismic_{VERSION}/measurements.azure-tdx.json
  ```

  Anything that needs an image's measurements fetches that URL. The build asserts the stamps name the VHD and the tarball it built, `image.json` takes the image's name from the stamps, and the publish job pushes the VHD and the tarball to where `image.json` names and tags the release with that name, so name, blob, image and files agree by construction.

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

`make release-assets` (the measurements, the founding inputs, then `image.json`) gathers the same files from a local build into `build/`, with the same `SHA256SUMS`, so a rebuild is compared to a release with `sha256sum -c --ignore-missing SHA256SUMS`. The release notes name the four source commits the image was built from; the commit of this repository is the tag itself, and [`sources.yaml`](modules/seismic/sources.yaml) at that commit is the record a rebuild starts from.

### `image.json`

Where the image's bytes are and what they are, in one machine-readable file, so a consumer reads these facts instead of spelling them by convention:

```jsonc
{
  // The tag, and the stem of every measurement_id.
  "image": "seismic_2026-09-22.2ee71c",
  "commit": "<the commit of this repository that built it>",
  // The four pins from sources.yaml.
  "sources": {"seismic_reth": "<sha>", "summit": "<sha>", "enclave": "<sha>", "caddy": "<sha>"},
  // One entry per cloud the image is published for, keyed by attestation
  // type. Each names the artifact its nodes boot, the measurements asset
  // stamped for that artifact, and efi_sha256, the hash of the .efi: the one
  // artifact that is reproducible (neither the VHD's nor the tarball's
  // wrapping is).
  "targets": {
    "azure-tdx": {
      // The blob an Azure node boots from.
      "vhd_blob_url": "https://seismicimages.blob.core.windows.net/dev/seismic_2026-09-22.2ee71c.vhd",
      // The account's ARM ID. Azure's managed-disk import needs it to read a
      // blob from another subscription or resource group; the URL names
      // neither.
      "storage_account_id": "/subscriptions/<id>/resourceGroups/<group>/providers/Microsoft.Storage/storageAccounts/seismicimages",
      // Stamped <image>.vhd.
      "measurements": "measurements.azure-tdx.json",
      "efi_sha256": "<sha256 of the .efi>"
    },
    "gcp-tdx": {
      // The registered image a GCE node boots from: the tag with `_` and `.`
      // as `-`.
      "gce_image": "projects/seismic-images/global/images/seismic-2026-09-22-2ee71c",
      // The .tar.gz it was registered from.
      "tarball_url": "https://storage.googleapis.com/seismic-images/seismic_2026-09-22.2ee71c.tar.gz",
      // Stamped <image>.tar.gz.
      "measurements": "measurements.gcp-tdx.json",
      "efi_sha256": "<sha256 of the .efi>"
    }
  }
}
```

The build writes it, in `make release-assets` ([`scripts/seismic/release_assets.sh`](scripts/seismic/release_assets.sh)), before the bytes are anywhere: the blob URL and the GCE image are where the VHD and the tarball will go, in the container `AZURE_CONTAINER` picks and the bucket and project `GCP_BUCKET` and `GCP_PROJECT` name, and the account's ARM ID comes from the Makefile. The publish job then makes the record true: `make push-azure` ([`scripts/seismic/push_azure.sh`](scripts/seismic/push_azure.sh)) uploads the VHD to the blob it names, and `make push-gcp` ([`scripts/seismic/push_gcp.sh`](scripts/seismic/push_gcp.sh)) uploads the tarball to the bucket and registers the GCE image it names, each reading its destination from the record. It refuses measurements stamped for any other UKI, so the halves of a release cannot come from different builds.

## What's in the image

The Seismic node stack: [`seismic-reth`](https://github.com/SeismicSystems/seismic-reth),
[`summit`](https://github.com/SeismicSystems/summit), and from
[`enclave`](https://github.com/SeismicSystems/enclave) `tdx-init`, the custodian and the
attestation service, and [Caddy](https://github.com/caddyserver/caddy) as the public HTTPS
proxy, all built from the commits pinned in [`sources.yaml`](modules/seismic/sources.yaml).
[`modules/seismic/readme.md`](modules/seismic/readme.md) covers how they are assembled:
units, users and groups, directories.

## Exposed HTTPS endpoints

Caddy terminates TLS on `:443` with a certificate it takes and renews itself (Let's Encrypt, or ZeroSSL when that fails), and reverse-proxies the following paths to in-TEE services. Each backend serves one endpoint whatever the request path, so a route matches its path exactly, with or without a trailing slash, and forwards to `/`; anything else (`/rpc/foo`, `/rpcfoo`) is a 404. Only `/ws` accepts WebSocket upgrades. See [`modules/seismic/mkosi.extra/etc/caddy/Caddyfile`](modules/seismic/mkosi.extra/etc/caddy/Caddyfile).

| Route             | Backend                          | Purpose                                                                                               | Public?                                |
| ----------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `/rpc`            | `reth` `:8545`                   | Ethereum JSON-RPC (shielded tx support via TxSeismic)                                                 | ✅ intended public                      |
| `/ws`             | `reth` `:8546`                   | Ethereum WebSocket RPC                                                                                | ✅ intended public                      |
| `/summit`         | `summit` `:3030`                 | Consensus JSON-RPC: read-only queries (health, checkpoints, headers, validator balances, deposits, state proofs) | ⚠️ no rate limiting — see below         |
| `/attestation`    | `attestation-service` `:7878` | Attestation API (tx-io attestation evidence, health/LUKS status, admission-chain status, peer root-key bootstrap) | ✅ same surface as `:7878`, which is open to anyone |
| `/metrics/reth`   | `reth` `:9001`                   | Prometheus metrics                                                                                    | ⚠️ unauthenticated                      |
| `/metrics/summit` | `summit` `:9002`                 | Prometheus metrics                                                                                    | ⚠️ unauthenticated                      |

### ⚠️ Known sharp edges

Everything above listens on the single public `:443`. The intended long-term fix is to split the proxy into two tiers — a public site with only the endpoints that should reach the open internet (`/rpc`, `/ws`, `/attestation`, and whatever of `/summit` the staking UI needs), and an internal site on a separate port with the rest (`/metrics/*`, the rest of `/summit`). The deploy tooling would then configure cloud firewall rules (Azure NSG / GCP firewall) to allow the public port from `0.0.0.0/0` and restrict the internal port to the VPC CIDR. Until that split lands, the concrete issues are:

- **`/summit` is a blanket proxy with no rate limiting.** Summit's public listener serves only read-only queries (`health`, `getCheckpoint`, `getValidatorBalance`, `getDeposit`, `getStateProof`, … — analogous to `eth_*` reads). Its signing method, `getDepositSignature`, is on a localhost-only admin listener, and `sendGenesis` on a separate genesis-setup server; the proxy reaches neither. Narrowing `/summit` further needs JSON-RPC-method-level filtering, since every call is `POST /`.
- **`/metrics/*` is unauthenticated.** Operationally safe on a locked-down network (the cloud firewall rule above is the right fix), but anyone who can reach the port can scrape sync status, peer info, and resource usage. Do *not* expose the internal port to the open internet without adding basic auth or an IP allowlist on top.

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
