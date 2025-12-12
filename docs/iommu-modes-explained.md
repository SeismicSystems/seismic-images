# IOMMU Modes Explained: pt vs nopt

## What is IOMMU?

The **IOMMU** (Input-Output Memory Management Unit) sits between devices and memory, translating device addresses to physical memory addresses - similar to how the MMU works for CPUs.

## Two Operating Modes

### 1. Passthrough Mode (`iommu=pt`)

**What it does:**
- Devices bypass IOMMU translation
- DMA goes directly to physical memory
- Minimal overhead, best performance

**Memory flow:**
```
Device → IOMMU (passthrough) → Physical Memory (encrypted in TDX)
```

**In TDX context:**
- Device tries to access encrypted memory
- `force_dma_unencrypted(dev)` returns true
- Kernel tries to allocate unencrypted DMA buffer
- If driver uses `__GFP_COMP` → **BUG** (your deadlock)

**Command line:**
```
iommu=pt intel_iommu=on
```

### 2. Translation Mode (`iommu=nopt` or no `pt`)

**What it does:**
- IOMMU actively translates all DMA addresses
- Uses SWIOTLB bounce buffers
- Slightly more overhead, but safer

**Memory flow:**
```
Device → IOMMU (translate) → SWIOTLB (shared/unencrypted) → Physical Memory
```

**In TDX context:**
- SWIOTLB buffers are pre-allocated as shared memory
- These buffers are already unencrypted
- The problematic `force_dma_unencrypted()` check is avoided
- No `__GFP_COMP` issue

**Command line:**
```
iommu=nopt intel_iommu=on
# OR just:
intel_iommu=on  (translation is default)
```

## Why This Fixes Your Bug

### The Bug Path (with `iommu=pt`):
```c
// In kernel/dma/direct.c:178
if (force_dma_unencrypted(dev) && (gfp & __GFP_COMP)) {
    WARN_ON_ONCE(1);  // ← Your warning here
    return NULL;       // ← Causes deadlock
}
```

This code is **only reached** when:
1. Memory encryption is active (TDX)
2. Device is trying to allocate DMA memory directly (passthrough mode)
3. Allocation uses compound pages (`__GFP_COMP`)

### The Fix Path (with `iommu=nopt`):
```c
// DMA allocation goes through SWIOTLB path instead
// SWIOTLB buffers are pre-allocated and already shared
// Never hits the force_dma_unencrypted() + __GFP_COMP check
// ✓ No warning, no deadlock
```

## Performance Impact

### Passthrough Mode (`iommu=pt`)
- **Pros**: Fastest DMA performance (direct access)
- **Cons**: Breaks with TDX + NVMe (your bug)

### Translation Mode (`iommu=nopt`)
- **Pros**: Works with TDX, safer, prevents attacks
- **Cons**: ~5-10% DMA overhead due to bounce buffering

**For TDX VMs, the overhead is acceptable** - you're already paying for encryption overhead, so the IOMMU translation overhead is negligible in comparison.

## SWIOTLB Buffer

The SWIOTLB (Software I/O TLB) is a bounce buffer for DMA:

```
Your kernel: swiotlb=262144
            ↑
            262,144 pages = 1GB of bounce buffer space
```

**What it does:**
1. Pre-allocated at boot as **shared** (unencrypted) memory in TDX
2. Device DMAs to/from SWIOTLB
3. Kernel copies data between SWIOTLB ↔ encrypted guest memory
4. Device never touches encrypted memory directly

## Verification

After booting with `iommu=nopt`, check:

```bash
# Should show SWIOTLB is active
dmesg | grep -i swiotlb
# Output: "PCI-DMA: Using software bounce buffering for IO (SWIOTLB)"

# Should NOT show passthrough
dmesg | grep -i "iommu.*passthrough"
# Output: (nothing) or "Default domain type: Translated"

# Should NOT see the DMA warning
dmesg | grep "dma_direct_alloc"
# Output: (nothing)
```

## Summary

| Parameter | Mode | TDX + NVMe | Performance | Security |
|-----------|------|------------|-------------|----------|
| `iommu=pt` | Passthrough | ❌ Deadlocks | Fast | Less isolation |
| `iommu=nopt` | Translation | ✅ Works | Slightly slower | Better isolation |

**For TDX VMs: Always use `iommu=nopt` or omit `pt` entirely.**
