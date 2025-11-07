# Build Guide

## Basic Usage

```bash
# Azure
make build IMAGE=seismic PROFILE=azure

# GCP
make build IMAGE=seismic PROFILE=gcp

# Bare metal
make build IMAGE=seismic
```

All builds automatically include timestamps in filenames.

## Output Files

Builds create files in `build/` with this naming pattern:

```
seismic-{profile}-{timestamp}.{extension}
```

Examples:
- `seismic-azure-20251107223045.vhd`
- `seismic-gcp-20251107223045.tar.gz`
- `seismic-baremetal-20251107223045.efi`

## Getting Measurements

After building, export TDX measurements:

```bash
# Standard format (Azure, bare metal)
make measure IMAGE=seismic

# GCP format
make measure-gcp IMAGE=seismic
```

This auto-detects the built EFI file and creates measurements in `build/`.

## Build Organization

### Per-platform directories

```bash
# Azure
make build IMAGE=seismic PROFILE=azure
mkdir -p build/azure
mv build/seismic-azure-* build/azure/

# GCP
make build IMAGE=seismic PROFILE=gcp
mkdir -p build/gcp
mv build/seismic-gcp-* build/gcp/
```

### Release workflow

```bash
#!/bin/bash
set -e

IMAGE="seismic"
TIMESTAMP=$(date +%Y%m%d%H%M%S)
OUTDIR="releases/${IMAGE}-${TIMESTAMP}"
mkdir -p "$OUTDIR"

# Azure
make clean
make build IMAGE="$IMAGE" PROFILE=azure
cp build/${IMAGE}-azure-*.vhd "$OUTDIR/"
make measure IMAGE="$IMAGE"
cp build/measurements.json "$OUTDIR/measurements-azure.json"

# GCP
make clean
make build IMAGE="$IMAGE" PROFILE=gcp
cp build/${IMAGE}-gcp-*.tar.gz "$OUTDIR/"
make measure-gcp IMAGE="$IMAGE"
cp build/gcp_measurements.json "$OUTDIR/measurements-gcp.json"

# Bare metal
make clean
make build IMAGE="$IMAGE"
cp build/${IMAGE}-baremetal-*.efi "$OUTDIR/"
make measure IMAGE="$IMAGE"
cp build/measurements.json "$OUTDIR/measurements-baremetal.json"

echo "Builds complete: $OUTDIR"
```

## Development Builds

Add development tools (vim, strace, etc):

```bash
make build-dev IMAGE=seismic PROFILE=azure
```

## Cleanup

```bash
# Remove all build artifacts
make clean

# Remove specific timestamp
rm build/seismic-azure-20251107223045.*

# Keep only latest 5 builds
cd build && ls -t seismic-*.efi | tail -n +6 | xargs -r rm
```

## Build Manifest

Track build metadata:

```bash
cat > "build/manifest.json" <<EOF
{
  "image": "seismic",
  "version": "$(git describe --tags --always)",
  "commit": "$(git rev-parse HEAD)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "builder": "$(whoami)@$(hostname)"
}
