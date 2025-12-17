#!/bin/bash
# Diagnostic script to check dmesg for TDX/IOMMU/SWIOTLB/NVMe errors
# Recommended by Google Cloud engineer for troubleshooting TDX CVM disk issues
#
# Usage: Run this script after booting your TDX CVM to check for relevant errors
#        /usr/local/lib/tdx-diagnostics/check_dmesg_errors.sh

set -e

echo "================================================================"
echo "TDX CVM Diagnostic - Checking dmesg for relevant errors"
echo "================================================================"
echo ""

echo "1. Checking for SWIOTLB messages..."
echo "-----------------------------------"
dmesg | grep -i swiotlb || echo "No SWIOTLB messages found"
echo ""

echo "2. Checking for IOMMU messages..."
echo "---------------------------------"
dmesg | grep -i iommu || echo "No IOMMU messages found"
echo ""

echo "3. Checking for DMAR messages..."
echo "--------------------------------"
dmesg | grep -i dmar || echo "No DMAR messages found"
echo ""

echo "4. Checking for NVMe messages..."
echo "--------------------------------"
dmesg | grep -i nvme || echo "No NVMe messages found"
echo ""

echo "5. Checking for NVMe device nvme0n2 specifically..."
echo "---------------------------------------------------"
dmesg | grep -i nvme0n2 || echo "No nvme0n2 messages found"
echo ""

echo "6. Checking for DMA-related errors..."
echo "-------------------------------------"
dmesg | grep -iE "(dma|direct\.c)" || echo "No DMA messages found"
echo ""

echo "7. Checking for TDX-related messages..."
echo "---------------------------------------"
dmesg | grep -i tdx || echo "No TDX messages found"
echo ""

echo "8. Checking for memory encryption messages..."
echo "---------------------------------------------"
dmesg | grep -iE "(memory.*encryption|encrypted)" || echo "No memory encryption messages found"
echo ""

echo "9. Checking for any errors or warnings (last 50 lines)..."
echo "---------------------------------------------------------"
dmesg | grep -iE "(error|warning|failed)" | tail -50 || echo "No errors or warnings found"
echo ""

echo "================================================================"
echo "Diagnostic complete. Review the output above for any issues."
echo "================================================================"
echo ""
echo "Additional useful commands to run:"
echo "  - Check io_timeout: cat /sys/devices/pci0000:00/0000:00:04.0/nvme/nvme0/nvme0n2/queue/io_timeout"
echo "  - Check /proc/cmdline: cat /proc/cmdline"
echo "  - Full dmesg: dmesg | less"
echo "  - NVMe devices: nvme list"
