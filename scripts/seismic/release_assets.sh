#!/usr/bin/env bash
# Make a release's assets from the built image, into build/: the founding
# inputs a network on this image is founded from, and image.json, the record
# tying the release together, with one SHA256SUMS over them, the
# measurements and the UKI. Made the same way by CI and by hand, so a local
# build is checked against a release with
# `sha256sum -c --ignore-missing SHA256SUMS`. Local work only: nothing here
# needs credentials, and nothing is uploaded.
#
# Usage: release_assets.sh <initrd> <efi> <measurements-azure> <measurements-gcp> <commit>
#        (`make release-assets`: its INITRD, FILE, MEASUREMENTS_AZURE,
#        MEASUREMENTS_GCP, COMMIT)
#   measurements-azure   the stamped measurements.azure-tdx.json (`make measure`)
#   measurements-gcp     the stamped measurements.gcp-tdx.json (`make measure-gcp`)
#   commit               the commit of this repository that built the image
#
# Environment (the Makefile passes its own, with these defaults):
#   AZURE_STORAGE_ACCOUNT     account the VHD goes to          (seismicimages)
#   AZURE_CONTAINER           container within it: dev (ephemeral) or
#                             releases (long-term)             (dev)
#   AZURE_STORAGE_ACCOUNT_ID  the account's ARM ID; required, and must name
#                             AZURE_STORAGE_ACCOUNT
#   GCP_BUCKET                bucket the tarball goes to  (seismic-images)
#   GCP_PROJECT               project its GCE image is registered in (seismic-images)
set -euo pipefail

usage='usage: release_assets.sh <initrd> <efi> <measurements-azure> <measurements-gcp> <commit>'
initrd=${1:?$usage}
efi=${2:?$usage}
measurements=${3:?$usage}
gcp_measurements=${4:?$usage}
commit=${5:?$usage}
account=${AZURE_STORAGE_ACCOUNT:-seismicimages}
container=${AZURE_CONTAINER:-dev}
gcp_bucket=${GCP_BUCKET:-seismic-images}
gcp_project=${GCP_PROJECT:-seismic-images}
account_id=${AZURE_STORAGE_ACCOUNT_ID:?AZURE_STORAGE_ACCOUNT_ID must name the storage account (the Makefile sets it for seismicimages)}
# Checked before the slow part, so a typo costs nothing.
case "$container" in
  dev | releases) ;;
  *) echo "AZURE_CONTAINER=$container must be one of: dev, releases" >&2; exit 1 ;;
esac
case "$account_id" in
  /subscriptions/*/resourceGroups/*/providers/Microsoft.Storage/storageAccounts/"$account") ;;
  *) echo "AZURE_STORAGE_ACCOUNT_ID is not the ARM ID of storage account $account: $account_id" >&2; exit 1 ;;
esac
# Resolved before the cd below, so the arguments are read from where the
# caller spelled them. zstd ignores a symlink, and the build leaves
# `latest.initrd` as one.
initrd=$(realpath "$initrd")
efi=$(realpath "$efi")
measurements=$(realpath "$measurements")
gcp_measurements=$(realpath "$gcp_measurements")
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
sources=modules/seismic/sources.yaml
starter=summit-genesis-starter.toml

pin() {
  local ref
  ref=$(awk -v key="$1" '$0 ~ "^" key ":" {f=1} f && /git_reference:/ {print $2; exit}' "$sources")
  [ -n "$ref" ] || { echo "$sources carries no $1 pin" >&2; exit 1; }
  printf '%s' "$ref"
}

# The image's name is the UKI's stem, and the VHD's and the tarball's. The
# measurements are made against one UKI by targets of their own, and only
# their stamps tie them to this one: hashing an earlier build's file into
# this SHA256SUMS would certify registers no node in this image reports.
uki=$(basename "$efi")
image=${uki%.efi}
stamped=$(jq -r '.measurement_id // empty' "$measurements")
[ "$stamped" = "$image.vhd" ] || {
  echo "$measurements measures ${stamped:-no named image}, not $image.vhd — it is another build's" >&2
  exit 1
}
stamped=$(jq -r '.measurement_id // empty' "$gcp_measurements")
[ "$stamped" = "$image.tar.gz" ] || {
  echo "$gcp_measurements measures ${stamped:-no named image}, not $image.tar.gz — it is another build's" >&2
  exit 1
}

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

####### FOUNDING INPUTS #######

# The two binaries are lifted out of the initrd, so they are byte for byte
# the ones the image runs: a hash over them names a file inside the image,
# not a same-rev rebuild elsewhere (the build pins LTO, panic=abort,
# codegen-units and jemalloc's LG_VADDR, so the same source builds to
# different bytes under other flags).
echo "unpacking $initrd" >&2
zstd -dc "$initrd" | cpio -idm --quiet --no-absolute-filenames --no-preserve-owner -D "$root"
cp "$root/usr/bin/seismic-reth" "$root/usr/bin/summit" build/
cp "$starter" build/

# The execution-layer genesis is read from the seismic-reth commit compiled
# into the image rather than from a branch, so it is the one reth knows how
# to load.
reth=$(pin seismic_reth)
echo "fetching reth genesis at seismic-reth ${reth:0:7}" >&2
curl -fsSL --retry 3 -o build/reth-genesis.json \
  "https://raw.githubusercontent.com/SeismicSystems/seismic-reth/$reth/crates/seismic/chainspec/res/genesis/dev.json"
jq -e . build/reth-genesis.json > /dev/null

# The starter must carry the parameter set of the summit the image runs, and
# that binary is the only complete statement of it: a field with a serde
# default is absent from any example genesis summit publishes, so a starter
# checked against one inherits the default unseen. `summit genesis
# set-validators` re-emits the whole struct, defaults filled in, so its
# top-level keys are the schema at this exact commit; the starter's keys must
# be the same set, less the two derived fields its header explains. Values
# are never compared: each is a per-network choice.
#
# The binary runs under the initrd's own loader and libraries, so the host's
# glibc does not matter — but it is x86-64, and it has crashed inside Rosetta,
# so anywhere but a real x86-64 Linux machine the check is left to CI. In the
# Lima VM on Apple silicon the nix shell's tools are themselves x86-64
# binaries under Rosetta, and uname there says x86_64; so the decision rests
# on two things Rosetta cannot dress up: the kernel's own report of its
# architecture, and whether a Rosetta handler is registered with the kernel
# at all.
arch=$(cat /proc/sys/kernel/arch 2>/dev/null || uname -m)
rosetta=absent
[ -e /proc/sys/fs/binfmt_misc/rosetta ] && rosetta=registered
if [ "$arch" = x86_64 ] && [ "$rosetta" = absent ]; then
  echo "checking $starter against the image's summit (kernel $arch, rosetta $rosetta)" >&2
  # The two derived fields the starter leaves out, as placeholders: both are
  # required by the parser, and set-validators replaces the second.
  { cat "$starter"
    echo 'eth_genesis_hash = "0x0000000000000000000000000000000000000000000000000000000000000000"'
    echo 'validators = []'
  } > "$root/tmp/starter.toml"
  echo '[]' > "$root/tmp/validators.json"
  "$root/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" \
    --library-path "$root/usr/lib/x86_64-linux-gnu" \
    "$root/usr/bin/summit" genesis set-validators \
    -i "$root/tmp/starter.toml" -v "$root/tmp/validators.json" > "$root/tmp/rendered.toml" || {
    echo "$starter does not load in this image's summit (its error is above)" >&2
    exit 1
  }
  keys() { grep -oE '^[A-Za-z_][A-Za-z0-9_]* *=' "$1" | tr -d ' =' | sort; }
  diff <(keys "$starter") \
       <(keys "$root/tmp/rendered.toml" | grep -vxE 'eth_genesis_hash|validators') || {
    echo "$starter is not the parameter set of this image's summit (< starter only, > summit only)" >&2
    exit 1
  }
else
  echo "not checking $starter against the image's summit: it is x86-64 and this machine is not (kernel $arch, rosetta $rosetta); CI checks it" >&2
fi

####### IMAGE.JSON #######

# Where the image's bytes are and what they are, in one machine-readable
# file, so a consumer reads the facts instead of spelling them by
# convention: the blob the VHD goes to and the storage account's ARM ID
# (Azure's managed-disk import refuses a blob from another subscription or
# resource group without the ID, and the URL cannot yield it), the bucket
# object the tarball goes to and the GCE image registered from it, the
# measurements asset for each cloud target, the UKI's sha256 (the one
# reproducible artifact; neither wrapping is), and the commits the image was
# built from. One entry per cloud target, keyed by attestation type.
#
# Written before the bytes are anywhere: the blob URL and the GCE image are
# where `make push-azure` and `make push-gcp` will put them, reading the
# destinations from this file. So the record is complete once the build is,
# and becomes true when the pushes succeed.
jq -n \
  --arg image "$image" \
  --arg commit "$commit" \
  --arg seismic_reth "$reth" \
  --arg summit "$(pin summit)" \
  --arg enclave "$(pin enclave)" \
  --arg caddy "$(pin caddy)" \
  --arg vhd_blob_url "https://$account.blob.core.windows.net/$container/$image.vhd" \
  --arg storage_account_id "$account_id" \
  --arg measurements "$(basename "$measurements")" \
  --arg gce_image "projects/$gcp_project/global/images/$(printf '%s' "$image" | tr '_.' '--')" \
  --arg tarball_url "https://storage.googleapis.com/$gcp_bucket/$image.tar.gz" \
  --arg gcp_measurements "$(basename "$gcp_measurements")" \
  --arg efi_sha256 "$(sha256sum "$efi" | cut -d' ' -f1)" \
  '{
    image: $image,
    commit: $commit,
    sources: {seismic_reth: $seismic_reth, summit: $summit, enclave: $enclave, caddy: $caddy},
    targets: {
      "azure-tdx": {
        vhd_blob_url: $vhd_blob_url,
        storage_account_id: $storage_account_id,
        measurements: $measurements,
        efi_sha256: $efi_sha256
      },
      "gcp-tdx": {
        gce_image: $gce_image,
        tarball_url: $tarball_url,
        measurements: $gcp_measurements,
        efi_sha256: $efi_sha256
      }
    }
  }' > build/image.json

####### SHA256SUMS #######

# One SHA256SUMS over everything the release carries: the UKI — the whole
# image identity, since the VHD and the tarball only wrap it on a FAT
# partition, and that wrapping is not reproducible, so their hashes would be
# records no rebuilder could confirm — the founding inputs above, the
# measurements, which are
# the admission policy a founder scaffolds into a network and so the last
# asset that should arrive unchecked, and image.json. Bare filenames, so
# `sha256sum -c SHA256SUMS` works from wherever the files were downloaded
# to, and `--ignore-missing` checks whichever subset was taken.
(cd build && sha256sum \
  "$uki" seismic-reth summit reth-genesis.json summit-genesis-starter.toml \
  "$(basename "$measurements")" "$(basename "$gcp_measurements")" image.json) \
  > build/SHA256SUMS
cat build/image.json build/SHA256SUMS
