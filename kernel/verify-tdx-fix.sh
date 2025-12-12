#!/bin/bash
# Verify TDX NVMe DMA fix is working

echo "========================================"
echo "TDX NVMe DMA Fix Verification"
echo "========================================"
echo ""

echo "1. Checking kernel command line..."
if grep -q "iommu=nopt" /proc/cmdline; then
    echo "   ✓ IOMMU passthrough disabled (iommu=nopt)"
elif grep -q "iommu=pt" /proc/cmdline; then
    echo "   ⚠ IOMMU passthrough enabled (iommu=pt) - may still see warning"
fi

echo ""
echo "2. Checking for DMA warning in dmesg..."
if dmesg | grep -q "WARNING.*dma_direct_alloc"; then
    echo "   ✗ DMA warning still present:"
    dmesg | grep -A 5 "WARNING.*dma_direct_alloc" | head -10
else
    echo "   ✓ No DMA allocation warnings found"
fi

echo ""
echo "3. Checking for blocked processes..."
blocked=$(ps aux | awk '$8 ~ /D/' | wc -l)
if [ "$blocked" -gt 0 ]; then
    echo "   ⚠ Found $blocked blocked processes:"
    ps aux | awk '$8 ~ /D/ {print "     " $0}'
else
    echo "   ✓ No blocked processes"
fi

echo ""
echo "4. Testing block device operations..."
if [ -e /dev/nvme0n1 ]; then
    echo "   Testing: dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=1 iflag=direct"
    if timeout 5 dd if=/dev/nvme0n1 of=/dev/null bs=4096 count=1 iflag=direct 2>/dev/null; then
        echo "   ✓ Direct I/O works"
    else
        echo "   ✗ Direct I/O failed or timed out"
    fi
else
    echo "   ⚠ /dev/nvme0n1 not found, skipping I/O test"
fi

echo ""
echo "========================================"
echo "Verification complete"
echo "========================================"
