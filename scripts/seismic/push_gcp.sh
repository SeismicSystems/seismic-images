#!/usr/bin/env bash
# Upload an image's tarball to the bucket its image.json names and register
# the GCE image it names from it, which is what makes that record true.
# image.json is written with the build (`make release-assets`), before the
# bytes are anywhere; this is the one step that needs GCP credentials, and it
# takes both destinations from the record rather than from its own settings,
# so the two cannot disagree. GCE boots a registered image, not a bucket
# object, so the push is two steps.
#
# Neither is ever overwritten: the names carry the commit that built them
# and a node may already be booting those bytes. `--no-clobber` is the
# guarantee for the object, and an image's name is unique in its project;
# the exists checks ahead of both are what make pushing an image that is
# already there a no-op instead of a failure — a re-run of the CI publish
# depends on that.
#
# Usage: push_gcp.sh <image.json>   (`make push-gcp`)
#   image.json   the record `make release-assets` wrote; the tarball is read
#                from beside it, under the object's name
#
# Environment:
#   GCP_LOCATION   the region the registered image is stored in (us-central1)
set -euo pipefail

record=${1:?usage: push_gcp.sh <image.json>}
location=${GCP_LOCATION:-us-central1}

[ -f "$record" ] || {
  echo "$record not found: run \`make release-assets\` first — image.json names where the tarball and the image go" >&2
  exit 1
}
url=$(jq -r '.targets["gcp-tdx"].tarball_url // empty' "$record")
tarball_url='^https://storage\.googleapis\.com/([a-z0-9][a-z0-9._-]+)/([^/]+\.tar\.gz)$'
[[ $url =~ $tarball_url ]] || {
  echo "$record: targets.gcp-tdx.tarball_url is not a GCS URL of a .tar.gz: '$url'" >&2
  exit 1
}
bucket=${BASH_REMATCH[1]}
object=${BASH_REMATCH[2]}
image=$(jq -r '.targets["gcp-tdx"].gce_image // empty' "$record")
gce_image='^projects/([a-z][a-z0-9-]{4,28}[a-z0-9])/global/images/([a-z][a-z0-9-]{0,62})$'
[[ $image =~ $gce_image ]] || {
  echo "$record: targets.gcp-tdx.gce_image is not projects/<project>/global/images/<name>: '$image'" >&2
  exit 1
}
project=${BASH_REMATCH[1]}
name=${BASH_REMATCH[2]}
tarball=$(dirname "$record")/$object
[ -f "$tarball" ] || {
  echo "$tarball not found: $record names it, and the tarball is read from beside the record" >&2
  exit 1
}

if gcloud storage objects describe "gs://$bucket/$object" --project "$project" > /dev/null 2>&1; then
  echo "$object is already in gs://$bucket/; not overwriting." >&2
else
  echo "Uploading $tarball → gs://$bucket/ ..." >&2
  gcloud storage cp --no-clobber "$tarball" "gs://$bucket/$object" --project "$project"
fi
if gcloud compute images describe "$name" --project "$project" > /dev/null 2>&1; then
  echo "$name is already registered in $project; not replacing." >&2
else
  echo "Registering $name from gs://$bucket/$object ..." >&2
  gcloud compute images create "$name" --project "$project" \
    --source-uri "gs://$bucket/$object" \
    --guest-os-features=UEFI_COMPATIBLE,GVNIC,TDX_CAPABLE \
    --storage-location "$location"
fi
echo "$image"
