# Diagnostic Scripts for Disk lseek Issue

These Python scripts help diagnose and reproduce the lseek hang issue that occurs with cryptsetup on certain TDX/NVMe configurations.

## Background

During testing, it was discovered that cryptsetup hangs when calling `lseek()` on NVMe devices in GCP TDX environments. The issue is related to:
- Opening block devices with `O_DIRECT` flag
- Performing certain ioctl operations
- Subsequent `lseek()` calls hanging indefinitely

## Recommended Test Sequence

Run the scripts in this order to systematically diagnose the issue:

### 1. `1_basic_disk_ops.py` - Start Here
**Purpose:** Verify basic disk operations work

This comprehensive test checks if fundamental operations succeed:
- Opening block devices
- Basic lseek operations (SEEK_SET, SEEK_CUR, SEEK_END)
- Reading LUKS headers
- Various seek patterns
- Block device ioctls (BLKGETSIZE64)

**Run this first** to establish a baseline. If this fails, you have basic I/O issues.

**Usage:**
```bash
# Use default device (/dev/nvme0n2)
./1_basic_disk_ops.py

# Or specify a different device
./1_basic_disk_ops.py --disk /dev/sdb
```

---

### 2. `2_minimal_lseek_hang.py` - Simplest Reproduction
**Purpose:** Minimal test case to trigger the hang

The simplest sequence that triggers the bug:
1. Open with `O_DIRECT`, close
2. Open again
3. lseek (hangs here)

Also includes a control test without `O_DIRECT` to confirm it's O_DIRECT-specific.

**Run this second** to see if you can reproduce the hang with the minimal case.

**Usage:**
```bash
# Uses default /dev/nvme0n2
timeout 10 ./2_minimal_lseek_hang.py

# Or specify device
timeout 10 ./2_minimal_lseek_hang.py --disk /dev/sdb
```

**Expected outcome:**
- If it hangs: Bug reproduced! Continue with other tests.
- If it passes: The specific conditions to trigger the bug aren't present.

---

### 3. `3_odirect_combinations.py` - Narrow Down the Trigger
**Purpose:** Test all combinations of O_DIRECT flag usage

Runs 5 different tests to identify which flag combination triggers the hang:
1. Both opens WITH O_DIRECT
2. First WITHOUT, second WITH
3. First WITH, second WITHOUT
4. Both WITHOUT O_DIRECT
5. First WITH O_DIRECT, second WITHOUT O_DIRECT but with O_NONBLOCK (like cryptsetup)

**Run this third** to understand which specific combination causes the issue.

**Usage:**
```bash
# Uses default /dev/nvme0n2
./3_odirect_combinations.py

# Or specify device
./3_odirect_combinations.py --disk /dev/sdb
```

**Expected outcome:** Shows which O_DIRECT patterns trigger the hang.

---

### 4. `4_cryptsetup_ioctl_sequence.py` - Full Cryptsetup Behavior
**Purpose:** Replicate the exact ioctl sequence that cryptsetup uses

This script mimics cryptsetup's behavior from strace output:
1. Open with `O_DIRECT`, get sector size, close
2. Open without `O_DIRECT` (with `O_NONBLOCK`)
3. Call ioctls: `BLKGETSIZE64`, `BLKGETZONESZ`, `BLKIOOPT`, `BLKIOMIN`
4. Call lseek (this is where cryptsetup hangs)

**Run this fourth** to confirm the exact cryptsetup sequence triggers the hang.

**Usage:**
```bash
# Use default device (/dev/nvme0n2)
timeout 10 ./4_cryptsetup_ioctl_sequence.py

# Or specify a different device
timeout 10 ./4_cryptsetup_ioctl_sequence.py --disk /dev/sdb
```

**Expected outcome:** Should hang exactly like cryptsetup does.

---

### 5. `5_with_crypto_sockets.py` - Test Crypto Socket Interaction
**Purpose:** Test if AF_ALG crypto sockets affect the hang

Tests whether creating AF_ALG (crypto API) sockets between disk operations changes the behavior. The initial successful test had crypto sockets created between opens, so this checks if that's a workaround.

**Run this fifth** (optional) to see if crypto operations affect the issue.

**Usage:**
```bash
# Use default device (/dev/nvme0n2)
timeout 10 ./5_with_crypto_sockets.py

# Or specify a different device
timeout 10 ./5_with_crypto_sockets.py --disk /dev/sdb
```

**Expected outcome:** May reveal if crypto operations mask or trigger the issue.

---

### `check_kernel_hang_state.py` - Monitoring Tool (No Number)
**Purpose:** Monitor a hanging process to see where it's stuck in the kernel

Run this in a **separate terminal** while another test is hanging. It reads:
- `/proc/<pid>/stack` - kernel stack trace
- `/proc/<pid>/syscall` - current syscall
- `/proc/<pid>/status` - process status
- `/proc/<pid>/wchan` - wait channel

**Usage:**
```bash
# While another test is hanging in terminal 1, run in terminal 2:
./check_kernel_hang_state.py <pid>

# Or let it auto-detect:
./check_kernel_hang_state.py
```

---

## Quick Start - Run All Tests

Run this script to execute all tests in sequence:

```bash
#!/bin/bash
# run_all_tests.sh - Execute all diagnostic tests in sequence

echo "=========================================="
echo "Disk lseek Diagnostic Test Suite"
echo "=========================================="
echo "Device: ${1:-/dev/nvme0n2} (default)"
echo ""

DISK_ARG=""
if [ -n "$1" ]; then
    DISK_ARG="--disk $1"
fi

echo "[1/5] Basic disk operations..."
./1_basic_disk_ops.py $DISK_ARG
BASIC_RESULT=$?
echo ""

echo "[2/5] Minimal lseek hang test..."
timeout 10 ./2_minimal_lseek_hang.py $DISK_ARG
MINIMAL_RESULT=$?
echo ""

echo "[3/5] O_DIRECT combinations test..."
timeout 30 ./3_odirect_combinations.py $DISK_ARG
COMBINATIONS_RESULT=$?
echo ""

echo "[4/5] Cryptsetup ioctl sequence..."
timeout 10 ./4_cryptsetup_ioctl_sequence.py $DISK_ARG
CRYPTSETUP_RESULT=$?
echo ""

echo "[5/5] With crypto sockets..."
timeout 10 ./5_with_crypto_sockets.py $DISK_ARG
CRYPTO_RESULT=$?
echo ""

echo "=========================================="
echo "Test Results Summary"
echo "=========================================="
echo "1. Basic disk ops:        $([ $BASIC_RESULT -eq 0 ] && echo 'PASS ✓' || echo 'FAIL ✗')"
echo "2. Minimal hang:          $([ $MINIMAL_RESULT -eq 0 ] && echo 'PASS ✓' || echo 'HANG ⚠ (expected if bug present)')"
echo "3. O_DIRECT combos:       $([ $COMBINATIONS_RESULT -eq 0 ] && echo 'PASS ✓' || echo 'HANG ⚠')"
echo "4. Cryptsetup sequence:   $([ $CRYPTSETUP_RESULT -eq 0 ] && echo 'PASS ✓' || echo 'HANG ⚠ (expected if bug present)')"
echo "5. With crypto sockets:   $([ $CRYPTO_RESULT -eq 0 ] && echo 'PASS ✓' || echo 'HANG ⚠')"
echo ""

if [ $MINIMAL_RESULT -ne 0 ] || [ $CRYPTSETUP_RESULT -ne 0 ]; then
    echo "⚠ Bug reproduced! lseek hangs detected."
    echo "Run check_kernel_hang_state.py in another terminal while a test hangs to diagnose."
else
    echo "✓ All tests passed. Bug not reproduced on this system."
fi
```

Save as `run_all_tests.sh`, make executable, and run:
```bash
chmod +x run_all_tests.sh
./run_all_tests.sh              # Uses default /dev/nvme0n2
./run_all_tests.sh /dev/sdb     # Or specify device
```

---

## Common Usage Patterns

### Quick reproduction test:
```bash
# Start with minimal test
timeout 10 ./2_minimal_lseek_hang.py
```

### Full diagnostic workflow:
```bash
# Run in sequence
./1_basic_disk_ops.py
timeout 10 ./2_minimal_lseek_hang.py
./3_odirect_combinations.py
timeout 10 ./4_cryptsetup_ioctl_sequence.py
```

### Monitor a hanging test:
```bash
# Terminal 1:
./4_cryptsetup_ioctl_sequence.py

# Terminal 2 (while it's hanging):
./check_kernel_hang_state.py
```

---

## Understanding the Results

### If Test 1 (basic_disk_ops) fails:
- You have fundamental I/O problems
- Check dmesg for device errors
- Verify device exists: `ls -l /dev/nvme0n2`

### If Test 2 (minimal_lseek_hang) hangs:
- **Bug reproduced!** The O_DIRECT pattern triggers the issue
- This is the core bug
- Continue with other tests to gather more data

### If Test 2 passes but Test 4 (cryptsetup_sequence) hangs:
- The bug requires the specific ioctl sequence cryptsetup uses
- The additional ioctls are part of the trigger

### If all tests pass:
- Bug not present on this system
- May be specific to certain kernel versions or TDX configurations

---

## Debugging Tips

1. **Always use `timeout`** when running tests that might hang:
   ```bash
   timeout 10 ./2_minimal_lseek_hang.py
   ```

2. **Check dmesg for kernel messages** after a hang:
   ```bash
   dmesg | tail -50
   ```

3. **Look for hung tasks** in the kernel log:
   ```bash
   dmesg | grep -i "blocked\|hung"
   ```

4. **Monitor the kernel stack** of a hanging process:
   ```bash
   cat /proc/<pid>/stack
   ```

5. **Check if the device is in a bad state**:
   ```bash
   cat /proc/partitions
   lsblk
   ```

6. **If device gets stuck**, you may need to reboot to reset it

---

## Expected Behavior

- ✓ **Working correctly**: Scripts complete and return success (exit code 0)
- ⚠ **Bug triggered**: Scripts hang at the lseek() call and timeout (exit code 124)

If scripts hang, the bug is reproduced. Use `check_kernel_hang_state.py` to see where the process is stuck in the kernel.

---

## Technical Details

### What triggers the hang?
Based on testing, the hang occurs when:
1. A block device is opened with `O_DIRECT` flag
2. Certain ioctls are called (especially `BLKSSZGET`, `BLKGETSIZE64`)
3. The device is closed
4. The device is opened again (with or without `O_DIRECT`)
5. `lseek()` is called on the new file descriptor → **hangs indefinitely**

### Why does this affect cryptsetup?
Cryptsetup performs exactly this sequence:
1. Opens device with `O_DIRECT` to check sector size
2. Closes it
3. Opens again to read LUKS header
4. Calls `lseek()` → hangs

### Related kernel subsystems:
- Block layer (`block/`)
- Direct I/O (`fs/direct-io.c`)
- NVMe driver (`drivers/nvme/`)
- DMA/IOMMU (in TDX environments)

---

## Related Issues

This issue was discovered while debugging why cryptsetup operations hang on GCP TDX instances with NVMe storage. The root cause appears to be related to:
- TDX-specific kernel behavior
- NVMe driver interaction with O_DIRECT
- Possible DMA or IOMMU issues in the TDX guest
- Block layer request queue handling

---

## See Also

- Original debugging context: See git history for full debugging session
- Kernel documentation: `Documentation/block/`
- cryptsetup source: `lib/utils_device.c`
- NVMe driver: `drivers/nvme/host/core.c`
