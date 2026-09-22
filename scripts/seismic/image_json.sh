#!/usr/bin/env bash
# Write build/image.json — where an image's bytes are and what they are, in
# one machine-readable file per release — and cover it in SHA256SUMS.
#
# Every other asset of a release is one artifact; this one is the record
# tying them together, so a consumer reads the facts instead of spelling
# them by convention: the blob the VHD sits at and the storage account's ARM
# ID (Azure's managed-disk import refuses a blob from another subscription
# or resource group without the ID, and the URL cannot yield it), the
# measurements asset for each cloud target, the UKI's sha256 (the one
# reproducible artifact; the VHD wrapping is not), and the commits the image
# was built from. Shaped per cloud target from the start, so a GCP image
# adds an entry rather than a schema.
#
# Usage: image_json.sh <measurements> <SHA256SUMS> <commit>   (`make image-json`)
#   measurements   the stamped measurements.azure-tdx.json; its measurement_id
#                  names the image, as `<image>.vhd`
#   SHA256SUMS     the checksum file `make release-assets` wrote; the UKI's line
#                  is read from it (and must name the same image), and
#                  image.json's own line is appended to it. image.json is
#                  written beside it.
#   commit         the commit of this repository that built the image
#
# Environment (the Makefile's push-azure names, same defaults):
#   AZURE_STORAGE_ACCOUNT     account the VHD was pushed to   (seismicimages)
#   AZURE_CONTAINER           container within it             (dev)
#   AZURE_STORAGE_ACCOUNT_ID  the account's ARM ID; asked of `az` when unset,
#                             which needs an `az login` that can read the account
set -euo pipefail

measurements=${1:?usage: image_json.sh <measurements> <SHA256SUMS> <commit>}
sums=${2:?usage: image_json.sh <measurements> <SHA256SUMS> <commit>}
commit=${3:?usage: image_json.sh <measurements> <SHA256SUMS> <commit>}
account=${AZURE_STORAGE_ACCOUNT:-seismicimages}
container=${AZURE_CONTAINER:-dev}
# Resolved before the cd below, so the arguments are read from where the
# caller spelled them.
measurements=$(realpath "$measurements")
sums=$(realpath "$sums")
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
sources=modules/seismic/sources.yaml
out=$(dirname "$sums")/image.json

stamped=$(jq -r .measurement_id "$measurements")
image=${stamped%.vhd}
if [ "$image" = "$stamped" ] || [ -z "$image" ]; then
  echo "$measurements: measurement_id $stamped does not name a VHD" >&2
  exit 1
fi

# The one line of SHA256SUMS that names the UKI, and it must name *this*
# image's: the measurements and the founding inputs are made by separate
# targets from whatever FILE and INITRD point at, so a stale measurements
# file beside a fresh SHA256SUMS (or the reverse) would otherwise be
# recorded here as one image. Exactly one such line, since two would mean
# two images' inputs in one build directory.
efi_lines=$(awk '$2 ~ /\.efi$/' "$sums")
[ "$(printf '%s\n' "$efi_lines" | grep -c .)" = 1 ] || {
  echo "$sums names $(printf '%s\n' "$efi_lines" | grep -c .) .efi files, expected exactly one" >&2
  exit 1
}
read -r efi_sha256 efi_name <<< "$efi_lines"
[ "$efi_name" = "$image.efi" ] || {
  echo "$measurements is stamped for $image but $sums hashes $efi_name: the two were made from different builds — re-run \`make release-assets\`" >&2
  exit 1
}

pin() {
  local ref
  ref=$(awk -v key="$1" '$0 ~ "^" key ":" {f=1} f && /git_reference:/ {print $2; exit}' "$sources")
  [ -n "$ref" ] || { echo "$sources carries no $1 pin" >&2; exit 1; }
  printf '%s' "$ref"
}

account_id=${AZURE_STORAGE_ACCOUNT_ID:-}
if [ -z "$account_id" ]; then
  echo "asking az for the ARM ID of storage account $account" >&2
  account_id=$(az storage account show --name "$account" --query id -o tsv)
fi
case "$account_id" in
  /subscriptions/*/resourceGroups/*/providers/Microsoft.Storage/storageAccounts/*) ;;
  *) echo "not a storage account ARM ID: $account_id" >&2; exit 1 ;;
esac

# The blob URL as `make push-azure` prints it.
vhd_blob_url="https://$account.blob.core.windows.net/$container/$image.vhd"

jq -n \
  --arg image "$image" \
  --arg commit "$commit" \
  --arg seismic_reth "$(pin seismic_reth)" \
  --arg summit "$(pin summit)" \
  --arg enclave "$(pin enclave)" \
  --arg vhd_blob_url "$vhd_blob_url" \
  --arg storage_account_id "$account_id" \
  --arg measurements "$(basename "$measurements")" \
  --arg efi_sha256 "$efi_sha256" \
  '{
    image: $image,
    commit: $commit,
    sources: {seismic_reth: $seismic_reth, summit: $summit, enclave: $enclave},
    targets: {
      "azure-tdx": {
        vhd_blob_url: $vhd_blob_url,
        storage_account_id: $storage_account_id,
        measurements: $measurements,
        efi_sha256: $efi_sha256
      }
    }
  }' > "$out"

# Covered by SHA256SUMS like every other asset; a re-run replaces its line.
line=$(cd "$(dirname "$sums")" && sha256sum image.json)
grep -v ' image\.json$' "$sums" > "$sums.tmp" || true
printf '%s\n' "$line" >> "$sums.tmp"
mv "$sums.tmp" "$sums"
echo "wrote $out" >&2
cat "$out"
