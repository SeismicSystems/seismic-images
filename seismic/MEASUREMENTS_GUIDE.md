# TDX Measurements Guide

## Platform Differences

TDX measurements differ between Azure, GCP, and bare metal because each platform includes different files in the image.

### What differs

| Platform | Added Packages | Added Services | Image Format |
|----------|---------------|----------------|--------------|
| Azure | dmidecode | azure-complete-provisioning.service | VHD (~502 MB) |
| GCP | udev | GCP network configs | tar.gz (~1 GB) |
| Bare metal | none | base only | EFI (~200 MB) |

Different files means different initrd contents, which produces different MRTD values.

### Measurement commands

```bash
# Azure and bare metal
make measure IMAGE=seismic
# Output: build/measurements.json

# GCP
make measure-gcp IMAGE=seismic
# Output: build/gcp_measurements.json
```

The tools differ because GCP uses a different JSON format for their attestation service.

## What Gets Measured

TDX measures these components to create MRTD:

1. Kernel binary (same across platforms)
2. Initrd contents (different per platform)
3. Kernel command line (same across platforms)
4. Firmware (runtime dependent)

## Reproducibility

Within the same platform, builds are deterministic:

```bash
# First build
make clean && make build IMAGE=seismic PROFILE=azure
make measure IMAGE=seismic
cp build/measurements.json build/measurements1.json

# Second build
make clean && make build IMAGE=seismic PROFILE=azure
make measure IMAGE=seismic

# Compare
diff build/measurements.json build/measurements1.json
# Should be identical
```

Across platforms, measurements will differ:

```bash
# Azure
make build IMAGE=seismic PROFILE=azure
make measure IMAGE=seismic
cp build/measurements.json build/azure-measurements.json

# GCP
make clean && make build IMAGE=seismic PROFILE=gcp
make measure-gcp IMAGE=seismic

# These will differ (expected)
diff build/azure-measurements.json build/gcp_measurements.json
```

## Attestation Setup

Your attestation service needs separate expected measurements for each platform:

```
attestation/
├── measurements-azure.json
├── measurements-gcp.json
└── measurements-baremetal.json
```

The service should:
1. Detect which platform the VM runs on
2. Load the corresponding expected measurements
3. Compare runtime measurements against expected values

Never mix measurements across platforms during attestation.

## Output Files

All measurement files go to `build/`:

```
build/
├── seismic-azure-20251107223045.efi
├── seismic-azure-20251107223045.vhd
├── measurements.json              # Azure/bare metal format
└── gcp_measurements.json          # GCP-specific format
```
