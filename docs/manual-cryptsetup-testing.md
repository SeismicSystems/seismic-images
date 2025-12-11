# Manual Cryptsetup Testing on Standard GCP TDX Image

This guide walks through setting up disk encryption manually on a standard (non-mkosi) GCP TDX VM to isolate whether the issue is mkosi-specific or a general TDX/GCP problem.

## Prerequisites

1. Create a standard Ubuntu 22.04/24.04 TDX VM on GCP
2. Attach a persistent NVMe disk as secondary device
3. SSH into the VM as root or use sudo

## Step 1: Install Required Packages

```bash
apt-get update
apt-get install -y cryptsetup nvme-cli
```

## Step 2: Identify the Disk

```bash
# List all NVMe devices
nvme list

# Check udev info
udevadm info /dev/nvme0n2

# Verify device exists and is ready
ls -la /dev/nvme0n2
cat /sys/class/nvme/nvme0/state  # Should show "live"
```

## Step 3: Check Kernel Configuration

```bash
# Check if DMA coherent pool is supported
zcat /proc/config.gz | grep -i "DMA_COHERENT_POOL\|DMA_RESTRICTED_POOL"

# Check current kernel command line
cat /proc/cmdline

# Check for DMA warnings in dmesg
dmesg | grep -i "dma\|coherent\|swiotlb"
```

## Step 4: Test Basic Disk I/O (Critical Diagnostic Step)

```bash
# This will hang if the DMA issue exists
timeout 10 dd if=/dev/nvme0n2 of=/dev/null bs=512 count=1 iflag=direct 2>&1

# If the above hangs, you've confirmed the DMA issue
# Check dmesg for warnings:
dmesg | tail -50
```

## Step 5: Initialize LUKS Encryption

**⚠️ WARNING: This will erase all data on the disk!**

```bash
# Generate a random encryption key (32 bytes = 256 bits)
dd if=/dev/urandom of=/root/disk.key bs=32 count=1

# Initialize LUKS container (this will hang if DMA issue exists)
# Using timeout to detect hangs
timeout 120 cryptsetup luksFormat \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha256 \
  --pbkdf pbkdf2 \
  --key-file /root/disk.key \
  /dev/nvme0n2

# Check return code
if [ $? -eq 124 ]; then
  echo "ERROR: cryptsetup timed out - DMA issue confirmed"
  dmesg | tail -50
  exit 1
fi
```

## Step 6: Open the LUKS Container

```bash
# Open the encrypted device
timeout 60 cryptsetup luksOpen \
  --key-file /root/disk.key \
  /dev/nvme0n2 \
  encrypted-disk

# Verify it opened
ls -la /dev/mapper/encrypted-disk
```

## Step 7: Create Filesystem and Mount

```bash
# Create ext4 filesystem
mkfs.ext4 /dev/mapper/encrypted-disk

# Create mount point
mkdir -p /mnt/encrypted

# Mount the encrypted disk
mount /dev/mapper/encrypted-disk /mnt/encrypted

# Verify mount
df -h /mnt/encrypted
```

## Step 8: Test Read/Write Operations

```bash
# Write test data
dd if=/dev/urandom of=/mnt/encrypted/test.dat bs=1M count=100

# Verify write
ls -lh /mnt/encrypted/test.dat

# Read back and verify
dd if=/mnt/encrypted/test.dat of=/dev/null bs=1M

# Clean up test file
rm /mnt/encrypted/test.dat
```

## Step 9: Unmount and Close

```bash
# Unmount
umount /mnt/encrypted

# Close LUKS container
cryptsetup luksClose encrypted-disk

# Verify it's closed
ls /dev/mapper/encrypted-disk  # Should not exist
```

## Troubleshooting: If Steps Hang

### Check DMA allocation failures:
```bash
dmesg | grep -A 10 "dma_direct_alloc\|dma_pool_alloc"
```

### Check if coherent_pool parameter is active:
```bash
# Should NOT show coherent_pool as unknown parameter
dmesg | grep "Unknown kernel command line"
```

### Check SWIOTLB status:
```bash
dmesg | grep -i swiotlb
cat /sys/kernel/debug/swiotlb/io_tlb_nslabs 2>/dev/null
```

### Increase DMA pool sizes (requires reboot):

Edit GRUB config:
```bash
# Edit /etc/default/grub
# Add to GRUB_CMDLINE_LINUX:
coherent_pool=256M swiotlb=524288,force intel_iommu=on iommu.strict=0

# Update grub
update-grub

# Reboot
reboot
```

After reboot, verify:
```bash
cat /proc/cmdline | grep coherent_pool
dmesg | grep coherent_pool
```

## Expected Results

### If DMA issue exists:
- ❌ `dd if=/dev/nvme0n2` hangs
- ❌ `cryptsetup luksFormat` hangs
- ❌ dmesg shows `dma_direct_alloc` warnings

### If DMA issue is fixed:
- ✅ `dd if=/dev/nvme0n2` completes in < 1 second
- ✅ `cryptsetup luksFormat` completes in < 30 seconds
- ✅ No DMA warnings in dmesg
- ✅ Read/write operations work normally

## Quick One-Liner Test

```bash
# Run this to quickly test if the disk is working:
(timeout 10 dd if=/dev/nvme0n2 of=/dev/null bs=512 count=1 iflag=direct 2>&1 && echo "✅ Disk I/O works") || (echo "❌ Disk I/O hangs - DMA issue confirmed" && dmesg | tail -20)
```

## Notes for GCP Testing

- This procedure isolates the issue from mkosi-specific configurations
- If this fails on standard Ubuntu TDX images, it confirms a TDX/IOMMU/NVMe issue
- Share results (especially dmesg output) with GCP support
- Test on multiple instance types (n2d, c2d) to see if it's instance-specific

---
**Note:** Always back up important data before testing disk encryption operations.
