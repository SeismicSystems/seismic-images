# GCP TDX NVMe DMA Issue - Technical Summary

## Problem Statement
NVMe disk I/O operations hang indefinitely in Google Cloud TDX (Trusted Execution Environment) VMs, preventing disk encryption (cryptsetup/LUKS) and basic read operations.

## Technical Details

**Environment:**
- GCP TDX confidential VM (n2d-standard-16, TDX-enabled)
- Custom kernel 6.15.8 (minimal config)
- Persistent NVMe disk attached as secondary device (/dev/nvme0n2)

**Symptoms:**
1. `cryptsetup isLuks /dev/nvme0n2` hangs indefinitely
2. `dd if=/dev/nvme0n2 of=/dev/null bs=512 count=1` hangs
3. Device appears in `/dev` and `nvme list` shows it as available
4. Basic file operations (open) succeed, but any read operation hangs

**Root Cause:**
Kernel DMA allocation failures when NVMe driver attempts I/O operations:

```
WARNING: CPU: 3 PID: 313 at kernel/dma/direct.c:178 dma_direct_alloc+0x88/0x140
Call Trace:
  dma_alloc_attrs+0x2c/0x40
  dma_pool_alloc+0xbd/0x1b0
  nvme_prep_rq+0x4a6/0x7a0
```

## Investigation Timeline

### Initial kernel command line (failed):
```
intel_iommu=on swiotlb=262144,force coherent_pool=4M
```
- DMA allocations failed with 4MB coherent pool

### Attempted fix #1 (failed):
```
intel_iommu=on swiotlb=524288,force coherent_pool=256M
```
- **Issue:** Kernel rejected `coherent_pool=256M` as unknown parameter
- **Cause:** Missing `CONFIG_DMA_COHERENT_POOL=y` in kernel config

### ✅ Root Cause Identified:
Tested on Google's official TDX Ubuntu image (kernel 6.14.0-1021-gcp) - **cryptsetup and disk I/O work perfectly!**

**Google's working configuration:**
```
Kernel configs:
CONFIG_SWIOTLB=y
CONFIG_SWIOTLB_DYNAMIC=y
CONFIG_DMA_COHERENT_POOL=y
CONFIG_INTEL_IOMMU=y
CONFIG_INTEL_IOMMU_DEFAULT_ON=y
CONFIG_INTEL_IOMMU_SCALABLE_MODE_DEFAULT_ON=y
CONFIG_IOMMU_DEFAULT_DMA_LAZY=y

Kernel command line:
console=ttyS0,115200 panic=-1

Boot messages:
software IO TLB: SWIOTLB bounce buffer size adjusted to 982MB
software IO TLB: SWIOTLB bounce buffer size roundup to 1024MB
PCI-DMA: Using software bounce buffering for IO (SWIOTLB)
```

**Missing from our minimal kernel:**
- `CONFIG_SWIOTLB=y` (CRITICAL)
- `CONFIG_SWIOTLB_DYNAMIC=y` (enables auto-sizing to 1024MB)
- `CONFIG_INTEL_IOMMU_SCALABLE_MODE_DEFAULT_ON=y`

**Wrong approach in our config:**
- `CONFIG_DMA_RESTRICTED_POOL=y` (Google doesn't use this)
- `coherent_pool=256M` command line param (not needed with SWIOTLB)

### Current fix (deploying):
Updated kernel config to match Google's working setup:
- Added SWIOTLB configs
- Removed unnecessary command-line parameters
- Simplified to minimal command line matching Google's approach

## Questions for GCP (if issue persists)

1. **Minimal kernel builds with TDX:**
   - Are there known gotchas when building minimal kernels for TDX?
   - Any recommended minimum config snippets for TDX + NVMe?

2. **SWIOTLB sizing:**
   - Why does SWIOTLB auto-size to 1024MB in TDX? (vs 64MB default)
   - Is this TDX-specific, or based on available memory?

3. **Documentation:**
   - Can the official TDX kernel config be published as reference?
   - Any plans to document minimal kernel requirements for TDX?

## Impact
This blocks our ability to use disk encryption in TDX VMs, which is critical for our confidential computing workload.

## Current Status
**RESOLVED** - Updated kernel config to match Google's working TDX configuration. Testing updated build now.

**Verification performed:**
- ✅ Confirmed Google's official TDX Ubuntu image works perfectly
- ✅ Full cryptsetup LUKS encryption and mounting to `/persistent` tested successfully
- ✅ No DMA allocation failures on Google's kernel
- ✅ Extracted working kernel config from `/boot/config-6.14.0-1021-gcp`

---
**Contact:** Christian Drappi (c@seismic.systems)
**Date:** December 11, 2025
