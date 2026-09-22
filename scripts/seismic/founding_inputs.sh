#!/usr/bin/env bash
# Gather what a network founded on the built image is founded from, into
# build/, and write SHA256SUMS over it, the measurements and the UKI. These
# are the release's assets, made the same way by CI and by hand, so a local
# build is checked against a release with
# `sha256sum -c --ignore-missing SHA256SUMS`.
#
# Usage: founding_inputs.sh <initrd> <efi> <measurements>
#        (the Makefile's INITRD, FILE and MEASUREMENTS_AZURE)
set -euo pipefail

usage='usage: founding_inputs.sh <initrd> <efi> <measurements>'
initrd=${1:?$usage}
efi=${2:?$usage}
measurements=${3:?$usage}
# zstd ignores a symlink, and the build leaves `latest.initrd` as one.
initrd=$(realpath "$initrd")
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
sources=modules/seismic/sources.yaml
starter=summit-genesis-starter.toml

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

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
reth=$(awk '/^seismic_reth:/{f=1} f && /git_reference:/{print $2; exit}' "$sources")
[ -n "$reth" ] || { echo "$sources carries no seismic_reth pin" >&2; exit 1; }
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

uki=$(basename "$(realpath "$efi")")

# The measurements are made against one UKI by a target of their own, and
# only the stamp ties them to this one: hashing an earlier build's file into
# this SHA256SUMS would certify PCRs no node in this image reports. The stamp
# is the VHD name, which is the UKI's stem.
vhd=${uki%.efi}.vhd
stamped=$(jq -r '.measurement_id // empty' "$measurements")
[ "$stamped" = "$vhd" ] || {
  echo "$measurements measures ${stamped:-no named image}, not $vhd — it is another build's" >&2
  exit 1
}

# One SHA256SUMS over everything the release carries: the UKI — the whole
# image identity, since the VHD only wraps it on a FAT partition, and that
# wrapping is not reproducible, so its hash would be a record no rebuilder
# could confirm — the founding inputs above, and the measurements, which are
# the admission policy a founder scaffolds into a network and so the last
# asset that should arrive unchecked. Bare filenames, so `sha256sum -c
# SHA256SUMS` works from wherever the files were downloaded to, and
# `--ignore-missing` checks whichever subset was taken.
(cd build && sha256sum \
  "$uki" seismic-reth summit reth-genesis.json summit-genesis-starter.toml \
  "$(basename "$measurements")") \
  > build/SHA256SUMS
cat build/SHA256SUMS
