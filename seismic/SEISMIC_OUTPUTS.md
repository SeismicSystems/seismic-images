# Output Files

All build artifacts go to the `build/` directory with filenames following this pattern:

```
seismic-{profile}-{timestamp}.{extension}
```

## File Types by Platform

### Azure
```
build/seismic-azure-20251107223045.efi      # Bootable UKI image (~200 MB)
build/seismic-azure-20251107223045.vhd      # Azure disk image (~502 MB)
build/seismic-azure-20251107223045.vmlinuz  # Kernel
build/seismic-azure-20251107223045.initrd   # Root filesystem
build/seismic-azure-20251107223045.manifest # Build metadata
```

The `.vhd` file is what you upload to Azure.

### GCP
```
build/seismic-gcp-20251107223045.efi        # Bootable UKI image (~200 MB)
build/seismic-gcp-20251107223045.tar.gz     # GCP disk image (~1 GB)
build/seismic-gcp-20251107223045.vmlinuz    # Kernel
build/seismic-gcp-20251107223045.initrd     # Root filesystem
build/seismic-gcp-20251107223045.manifest   # Build metadata
```

The `.tar.gz` file is what you upload to GCP.

### Bare Metal
```
build/seismic-baremetal-20251107223045.efi      # Bootable UKI image (~200 MB)
build/seismic-baremetal-20251107223045.vmlinuz  # Kernel
build/seismic-baremetal-20251107223045.initrd   # Root filesystem
build/seismic-baremetal-20251107223045.manifest # Build metadata
```

The `.efi` file is what you boot directly.

## Measurements

After running `make measure`, you get:

```
build/measurements.json              # Standard TDX format (Azure, bare metal)
build/gcp_measurements.json          # GCP-specific format
```

Measurements contain:
- MRTD (Measurement Register of TDX)
- RTMR values (Runtime Measurement Registers)
- Expected PCR values
- Hashes of kernel, initrd, and command line

## Organizing Builds

### By platform

```bash
mkdir -p build/{azure,gcp,baremetal}

# After each build
mv build/seismic-azure-* build/azure/
mv build/seismic-gcp-* build/gcp/
mv build/seismic-baremetal-* build/baremetal/
```

### By date

```bash
DATE=$(date +%Y%m%d)
mkdir -p releases/seismic-${DATE}
cp build/seismic-* releases/seismic-${DATE}/
```

### Keep recent only

```bash
# Keep last 5 builds of each type
cd build
ls -t seismic-azure-*.vhd | tail -n +6 | xargs -r rm
ls -t seismic-gcp-*.tar.gz | tail -n +6 | xargs -r rm
ls -t seismic-baremetal-*.efi | tail -n +6 | xargs -r rm
```

## Upload Examples

### Azure

```bash
az vm image create \
  --resource-group my-rg \
  --source build/seismic-azure-20251107223045.vhd \
  --name seismic-20251107 \
  --location eastus \
  --os-type Linux
```

### GCP

```bash
gcloud compute images create seismic-20251107 \
  --source-uri gs://my-bucket/seismic-gcp-20251107223045.tar.gz \
  --guest-os-features=UEFI_COMPATIBLE,SEV_SNP_CAPABLE
```

## Typical Sizes

- `.efi` file: ~200 MB
- `.vhd` file: ~500 MB
- `.tar.gz` file: ~1 GB
- `.vmlinuz`: ~6 MB
- `.initrd`: ~180 MB
- `measurements.json`: ~4 KB
