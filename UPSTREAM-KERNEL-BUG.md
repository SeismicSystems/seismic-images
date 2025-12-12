# Upstream Kernel Bug Report: TDX + NVMe DMA Deadlock

## Bug Summary

**Severity**: Critical - System deadlock
**Affects**: Linux kernel 6.15.8 (likely 6.12+)
**Platform**: TDX-enabled VMs (Intel Trust Domain Extensions)
**Trigger**: NVMe I/O operations during boot (5.3 seconds after boot)

## The Problem

When TDX memory encryption is active, the kernel has a fundamental flaw in how it handles DMA allocations:

1. **DMA layer** (`kernel/dma/direct.c:178`) rejects allocations with `__GFP_COMP` when encryption is active
2. **NVMe driver** requests exactly this combination without checking for encryption
3. **Result**: NULL return causes block layer deadlock - all processes hang in `bdev_open()`

## Reproduction

```bash
# Boot a TDX VM with:
console=ttyS0,115200 panic=-1 iommu=pt intel_iommu=on swiotlb=262144

# At ~5.3s, udev reads from NVMe device
# System immediately deadlocks with this warning:
WARNING: CPU: 3 PID: 324 at kernel/dma/direct.c:178 dma_direct_alloc+0x88/0x140
Call Trace:
  dma_alloc_attrs+0x2c/0x40
  dma_pool_alloc+0xbd/0x1b0
  nvme_prep_rq+0x482/0x990
  nvme_queue_rqs+0xbc/0x140
  [...]
  blkdev_read_iter+0x109/0x140

# All subsequent block device opens hang forever
```

## Stack Traces

**Trigger process** (PID 324 - udev-worker):
```
folio_wait_bit_common → __folio_lock → truncate_inode_pages_range
→ kill_bdev → blkdev_flush_mapping → blkdev_put_whole
```

**Blocked processes** (all others trying to open block devices):
```
bdev_open+0x71 → blkdev_open → do_dentry_open → path_openat
```

## Root Cause Analysis

### Issue 1: DMA Layer Doesn't Handle Encryption Gracefully

**File**: `kernel/dma/direct.c` line ~178

```c
if (force_dma_unencrypted(dev) && (gfp & __GFP_COMP)) {
    WARN_ON_ONCE(1);
    return NULL;  // ← BUG: Should clear flag and continue
}
```

**Why this is wrong**:
- Abrupt failure with no cleanup
- Block layer left in inconsistent state
- Causes deadlock as other processes wait for device
- Should either: auto-clear `__GFP_COMP` OR provide clear error to caller

### Issue 2: NVMe Driver Doesn't Detect Memory Encryption

**File**: `drivers/nvme/host/pci.c` (in `nvme_prep_rq` or similar)

```c
// Current code doesn't check for memory encryption
void *prp_list = dma_pool_alloc(dev->prp_page_pool, GFP_ATOMIC, &prp_dma);
```

**Why this is wrong**:
- DMA pool created with flags that include `__GFP_COMP`
- No detection of TDX/SEV/memory encryption active
- Should adjust allocation strategy when encryption detected

## Proposed Fixes

### Option A: Fix DMA Layer (Graceful Degradation)

```c
// kernel/dma/direct.c line ~178
if (force_dma_unencrypted(dev) && (gfp & __GFP_COMP)) {
-   WARN_ON_ONCE(1);
-   return NULL;
+   /* Compound pages can't be used with encrypted DMA.
+    * Clear flag and continue - slightly less efficient but works. */
+   gfp &= ~__GFP_COMP;
+   pr_debug_once("DMA: Cleared __GFP_COMP for encrypted device %s\n",
+                 dev_name(dev));
}
```

**Pros**: One-line fix, handles all drivers
**Cons**: Hides the underlying driver issue

### Option B: Fix NVMe Driver (Proper Solution)

```c
// drivers/nvme/host/pci.c
static int nvme_configure_prp_pools(struct nvme_dev *dev)
{
    gfp_t pool_flags = GFP_DMA | __GFP_NOWARN;

+   /* Don't use compound pages if memory encryption is active */
+   if (!force_dma_unencrypted(&dev->pci_dev->dev))
+       pool_flags |= __GFP_COMP;

    dev->prp_page_pool = dma_pool_create("prp list page", dev->dev,
-                                         PAGE_SIZE, PAGE_SIZE, 0);
+                                         PAGE_SIZE, PAGE_SIZE, pool_flags);
    [...]
}
```

**Pros**: Correct fix at driver level
**Cons**: Every DMA-using driver needs similar fixes

### Option C: Both (Defense in Depth)

Implement both fixes:
1. DMA layer auto-clears flag (prevents deadlocks)
2. Drivers check for encryption (optimal performance)

## System Information

```
Kernel: 6.15.8-yocto-tiny #1 PREEMPT
Hardware: Google Google Compute Engine (TDX)
BIOS: Google 09/24/2025
Command line: console=ttyS0,115200 panic=-1 iommu=pt intel_iommu=on swiotlb=262144
Memory encryption: Intel TDX active
SWIOTLB: 262144 pages (~1GB)
```

## Workaround

Change boot parameter: `iommu=pt` → `iommu=nopt`

This disables IOMMU passthrough, avoiding the encrypted DMA path entirely.

## Impact

**Critical**: Any TDX/SEV VM using NVMe storage will deadlock at boot.

Affected configurations:
- GCP TDX VMs with NVMe persistent disks
- Azure TDX VMs
- AWS with NVMe + memory encryption
- Any SEV-SNP + NVMe combination

## Maintainers to Contact

- **DMA**: Christoph Hellwig <hch@lst.de>, Robin Murphy <robin.murphy@arm.com>
- **NVMe**: Keith Busch <kbusch@kernel.org>, Christoph Hellwig <hch@lst.de>
- **TDX**: Kirill A. Shutemov <kirill.shutemov@linux.intel.com>
- **Lists**: linux-nvme@lists.infradead.org, iommu@lists.linux.dev

## Testing

Test with:
```bash
python3 -c "import os; os.open('/dev/nvme0n1', os.O_RDONLY | os.O_DIRECT)"
```

Should complete without hanging.

## References

- TDX spec: https://www.intel.com/content/www/us/en/developer/articles/technical/intel-trust-domain-extensions.html
- Similar bug: [link if found in kernel bugzilla]
