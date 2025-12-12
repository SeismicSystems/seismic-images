# TDX NVMe DMA Bug Fix

## Problem Summary

On TDX-enabled GCP VMs, the NVMe driver triggers a kernel warning at boot (5.355s) causing a complete block device deadlock:

```
WARNING: CPU: 3 PID: 324 at kernel/dma/direct.c:178 dma_direct_alloc+0x88/0x140
Call Trace: nvme_prep_rq → dma_pool_alloc → dma_direct_alloc
```

**Root cause**: NVMe driver uses `__GFP_COMP` flag for DMA allocations, which is forbidden when TDX memory encryption is active.

**Symptoms**:
- udev-worker hangs at boot
- All block device opens hang in `bdev_open`
- System unusable after 5.3 seconds
- Processes stuck in D state (uninterruptible sleep)

## Solutions Implemented

### 1. Boot Parameter Fix (Quick - ACTIVE)
**File**: `base/mkosi.conf` line 20

Changed: `iommu=pt` → `iommu=nopt`

This disables IOMMU passthrough mode, avoiding the TDX DMA encryption constraint.

**Pros**: Immediate fix, no kernel rebuild needed
**Cons**: Slightly different I/O path, may have minor performance impact

### 2. Kernel Patch (Proper Fix)
**Files**:
- `kernel/patches/0001-dma-fix-gfp-comp-with-tdx.patch`
- `kernel/mkosi.build` (updated to apply patches)

Patches `kernel/dma/direct.c` to auto-clear `__GFP_COMP` flag instead of failing.

**Pros**: Proper fix at kernel level, allows `iommu=pt` to work
**Cons**: Requires kernel rebuild

### 3. Kernel Config Updates
**File**: `seismic/kernel.config`

Added DMA debugging and IOMMU options for better diagnostics.

## Testing

After deploying a new image:

```bash
# On the TDX VM, run:
bash /path/to/verify-tdx-fix.sh

# Should show:
#   ✓ No DMA allocation warnings found
#   ✓ No blocked processes
#   ✓ Direct I/O works
```

Or manually test:
```bash
# Check for the warning
dmesg | grep -i "dma_direct_alloc"

# Test O_DIRECT opens (should not hang)
python3 /usr/local/lib/tdx-diagnostics/0_test_open_direct.py

# Check for blocked processes
ps aux | awk '$8 ~ /D/'
```

## Building

```bash
# Clear kernel cache to force rebuild with patches
rm -rf build/kernel-*

# Rebuild image
mkosi build
```

## Which Solution is Active?

- **Solution 1** (boot parameter): Active immediately after editing `base/mkosi.conf`
- **Solution 2** (kernel patch): Active after kernel rebuild
- **Both can be used together** for defense in depth

## Upstream Status

This bug should be reported to:
- Linux kernel DMA maintainers (dma-mapping@lists.linux.dev)
- NVMe maintainers (linux-nvme@lists.infradead.org)
- Intel TDX team

## References

- Kernel version: 6.15.8
- Platform: GCP TDX VMs (Google Compute Engine)
- DMA warning: `kernel/dma/direct.c:178`
- Failed function: `dma_direct_alloc+0x88`
- Trigger: udev reading from NVMe during boot
