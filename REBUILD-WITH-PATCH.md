# Rebuild Image with Kernel Patch

## Current Status

❌ **Boot parameter fix (`iommu=nopt`) is NOT sufficient**
- Your machine shows: `iommu=nopt` in kernel cmdline
- But still gets: `WARNING at kernel/dma/direct.c:178`
- Still deadlocks on close()

## Why Boot Parameter Doesn't Work

The bug check happens BEFORE IOMMU involvement:
```c
// kernel/dma/direct.c:178
if (force_dma_unencrypted(dev) && (gfp & __GFP_COMP)) {
    WARN_ON_ONCE(1);  // ← Triggers regardless of IOMMU mode!
    return NULL;       // ← Causes deadlock
}
```

`force_dma_unencrypted(dev)` returns true for ANY TDX VM, regardless of IOMMU settings.

## Required Fix: Kernel Patch

You MUST apply the kernel patch that changes the DMA core to handle this gracefully.

## Steps to Rebuild

### 1. Verify Patch is Ready
```bash
cd /Users/christiandrappi/code/seismic-images
cat kernel/patches/0001-dma-fix-gfp-comp-with-tdx.patch
```

Should show the patch that clears `__GFP_COMP` instead of failing.

### 2. Clear Kernel Cache
```bash
# Force rebuild by removing cached kernel
rm -rf build/kernel-*
```

### 3. Rebuild Image
```bash
mkosi build
```

This will:
- Clone kernel 6.15.8
- Apply the patch from `kernel/patches/`
- Build patched kernel
- Create new image

### 4. Deploy and Test

After deploying the new image, run:
```bash
# Should NOT show DMA warning
dmesg | grep -i "dma_direct_alloc"

# Should complete without hanging
python3 /usr/local/lib/tdx-diagnostics/0_find_hang_point.py

# Should show "Cleared __GFP_COMP" debug message instead of warning
dmesg | grep -i "Cleared __GFP_COMP"
```

## Expected Results

**Before patch (current state):**
```
[    5.366257] WARNING: CPU: 3 PID: 332 at kernel/dma/direct.c:178
# Hangs on close()
```

**After patch:**
```
[    5.366257] DMA: Cleared __GFP_COMP flag for encrypted device
# No hang, operations complete normally
```

## Alternative: Try mem_encrypt=off

If you need a TEMPORARY workaround while rebuilding:

Edit `base/mkosi.conf`:
```
KernelCommandLine=console=ttyS0,115200 panic=-1 mem_encrypt=off
```

**WARNING:** This disables TDX entirely - only use for testing!

## Verification

After rebuilding, the machine should:
- ✅ No DMA warning in dmesg
- ✅ close() completes instantly
- ✅ No processes in D state
- ✅ All diagnostic tests pass
