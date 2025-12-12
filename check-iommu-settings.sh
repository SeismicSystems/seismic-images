#!/bin/bash
# Check IOMMU settings on a running system

echo "========================================="
echo "IOMMU Configuration Check"
echo "========================================="
echo ""

echo "1. Kernel Command Line:"
cat /proc/cmdline
echo ""

echo "2. IOMMU Parameters (from cmdline):"
cat /proc/cmdline | grep -o "iommu=[^ ]*" || echo "  (no iommu= parameter)"
cat /proc/cmdline | grep -o "intel_iommu=[^ ]*" || echo "  (no intel_iommu= parameter)"
cat /proc/cmdline | grep -o "swiotlb=[^ ]*" || echo "  (no swiotlb= parameter)"
echo ""

echo "3. IOMMU Status from dmesg:"
dmesg | grep -i "iommu" | grep -i "mode\|enabled\|passthrough\|default" | head -5
echo ""

echo "4. IOMMU Domain Type:"
dmesg | grep -i "default domain type" || echo "  (not found in dmesg)"
echo ""

echo "5. SWIOTLB Status:"
dmesg | grep -i "swiotlb" | head -3
echo ""

echo "6. IOMMU Groups (if available):"
if [ -d /sys/kernel/iommu_groups ]; then
    echo "  Found $(find /sys/kernel/iommu_groups -type l | wc -l) IOMMU groups"
else
    echo "  /sys/kernel/iommu_groups not found"
fi
echo ""

echo "7. Intel IOMMU Sysfs:"
if [ -d /sys/devices/virtual/iommu ]; then
    ls -la /sys/devices/virtual/iommu/ 2>/dev/null | head -5
else
    echo "  /sys/devices/virtual/iommu not found"
fi
echo ""

echo "========================================="
echo "Summary:"
echo "========================================="

# Determine mode
if cat /proc/cmdline | grep -q "iommu=pt"; then
    echo "Mode: PASSTHROUGH (iommu=pt)"
elif cat /proc/cmdline | grep -q "iommu=nopt"; then
    echo "Mode: TRANSLATION (iommu=nopt)"
else
    if dmesg | grep -qi "passthrough"; then
        echo "Mode: PASSTHROUGH (default or detected)"
    else
        echo "Mode: TRANSLATION (default)"
    fi
fi

# Check SWIOTLB
if dmesg | grep -qi "swiotlb"; then
    echo "SWIOTLB: ACTIVE"
else
    echo "SWIOTLB: NOT DETECTED"
fi

# Check TDX
if dmesg | grep -qi "tdx"; then
    echo "TDX: DETECTED"
else
    echo "TDX: NOT DETECTED"
fi

echo ""
