#!/usr/bin/env bash
# Upload an image's VHD to the blob its image.json names, which is what makes
# that record true. image.json is written with the build (`make
# release-assets`), before the bytes are anywhere; this is the one step that
# needs Azure credentials, and it takes the destination from the record
# rather than from its own settings, so the two cannot disagree.
#
# A blob is never overwritten: its name carries the commit that built it and
# a node may already be booting those bytes. `--overwrite false` is the
# guarantee (spelled out rather than left to the CLI's default, which has
# flipped before); the exists check ahead of it is what makes pushing an
# image that is already there a no-op instead of a failure — a re-run of the
# CI publish depends on that.
#
# Usage: push_azure.sh <image.json>   (`make push-azure`)
#   image.json   the record `make release-assets` wrote; the VHD is read from
#                beside it, under the blob's name
#
# Environment:
#   AZURE_AUTH_MODE   login (default), or key without RBAC on the account
set -euo pipefail

record=${1:?usage: push_azure.sh <image.json>}
auth_mode=${AZURE_AUTH_MODE:-login}

[ -f "$record" ] || {
  echo "$record not found: run \`make release-assets\` first — image.json names where the VHD goes" >&2
  exit 1
}
url=$(jq -r '.targets["azure-tdx"].vhd_blob_url // empty' "$record")
blob_url='^https://([a-z0-9]+)\.blob\.core\.windows\.net/([a-z0-9-]+)/([^/]+\.vhd)$'
[[ $url =~ $blob_url ]] || {
  echo "$record: targets.azure-tdx.vhd_blob_url is not an Azure blob URL of a .vhd: '$url'" >&2
  exit 1
}
account=${BASH_REMATCH[1]}
container=${BASH_REMATCH[2]}
blob=${BASH_REMATCH[3]}
vhd=$(dirname "$record")/$blob
[ -f "$vhd" ] || {
  echo "$vhd not found: $record names it, and the VHD is read from beside the record" >&2
  exit 1
}

exists=$(az storage blob exists \
  --account-name "$account" --container-name "$container" --name "$blob" \
  --auth-mode "$auth_mode" --query exists -o tsv)
if [ "$exists" = true ]; then
  echo "$blob is already in $account/$container/; not overwriting." >&2
else
  echo "Uploading $vhd → $account/$container/ ..." >&2
  az storage blob upload \
    --account-name "$account" --container-name "$container" --name "$blob" \
    --file "$vhd" --overwrite false --auth-mode "$auth_mode"
fi
echo "$url"
