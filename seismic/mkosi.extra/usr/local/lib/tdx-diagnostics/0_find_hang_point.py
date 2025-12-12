#!/usr/bin/env python3
"""
Systematically test each operation to find where it hangs.
Prints timestamp before each operation so we know exactly where it stops.
"""

import os
import sys
import argparse
import time
import fcntl
import struct

def log(msg):
    """Print with timestamp."""
    print(f"[{time.time():.3f}] {msg}", flush=True)

def test_sequence(device_path, iteration=1):
    """Test the full sequence and report where it hangs."""
    log(f"=== ITERATION {iteration} ===")
    log(f"Device: {device_path}")

    # Step 1: Open without O_DIRECT
    log("STEP 1: open() without O_DIRECT")
    try:
        fd1 = os.open(device_path, os.O_RDONLY)
        log(f"  ✓ open() succeeded, fd={fd1}")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at open() without O_DIRECT: {e}")
        return "open_no_direct"

    # Step 2: Close it
    log("STEP 2: close()")
    try:
        os.close(fd1)
        log("  ✓ close() succeeded")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at close(): {e}")
        return "close"

    # Step 3: Open WITH O_DIRECT
    log("STEP 3: open() WITH O_DIRECT")
    try:
        fd2 = os.open(device_path, os.O_RDONLY | os.O_DIRECT)
        log(f"  ✓ open() with O_DIRECT succeeded, fd={fd2}")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at open() with O_DIRECT: {e}")
        return "open_direct"

    # Step 4: ioctl BLKGETSIZE64
    log("STEP 4: ioctl(BLKGETSIZE64)")
    try:
        BLKGETSIZE64 = 0x80081272
        result = fcntl.ioctl(fd2, BLKGETSIZE64, struct.pack('Q', 0))
        size = struct.unpack('Q', result)[0]
        log(f"  ✓ ioctl() succeeded, size={size}")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at ioctl(BLKGETSIZE64): {e}")
        return "ioctl_blkgetsize64"

    # Step 5: ioctl BLKSSZGET
    log("STEP 5: ioctl(BLKSSZGET)")
    try:
        BLKSSZGET = 0x1268
        result = fcntl.ioctl(fd2, BLKSSZGET, struct.pack('I', 0))
        sector_size = struct.unpack('I', result)[0]
        log(f"  ✓ ioctl() succeeded, sector_size={sector_size}")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at ioctl(BLKSSZGET): {e}")
        return "ioctl_blksszget"

    # Step 6: lseek SEEK_SET
    log("STEP 6: lseek(0, SEEK_SET)")
    try:
        pos = os.lseek(fd2, 0, os.SEEK_SET)
        log(f"  ✓ lseek() succeeded, pos={pos}")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at lseek(SEEK_SET): {e}")
        return "lseek_seek_set"

    # Step 7: lseek SEEK_CUR
    log("STEP 7: lseek(0, SEEK_CUR)")
    try:
        pos = os.lseek(fd2, 0, os.SEEK_CUR)
        log(f"  ✓ lseek() succeeded, pos={pos}")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at lseek(SEEK_CUR): {e}")
        return "lseek_seek_cur"

    # Step 8: lseek SEEK_END
    log("STEP 8: lseek(0, SEEK_END)")
    try:
        pos = os.lseek(fd2, 0, os.SEEK_END)
        log(f"  ✓ lseek() succeeded, pos={pos}")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at lseek(SEEK_END): {e}")
        return "lseek_seek_end"

    # Step 9: read
    log("STEP 9: read(512 bytes)")
    try:
        # Seek back to start
        os.lseek(fd2, 0, os.SEEK_SET)
        data = os.read(fd2, 512)
        log(f"  ✓ read() succeeded, got {len(data)} bytes")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at read(): {e}")
        return "read"

    # Step 10: close
    log("STEP 10: close()")
    try:
        os.close(fd2)
        log("  ✓ close() succeeded")
    except Exception as e:
        log(f"  ✗ HANG/FAIL at final close(): {e}")
        return "close_final"

    log("✓ ALL STEPS COMPLETED SUCCESSFULLY")
    return "success"

def main():
    parser = argparse.ArgumentParser(
        description='Find exact hang point in disk operations')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    parser.add_argument('--iterations', type=int, default=1,
                        help='Number of iterations (default: 1)')
    args = parser.parse_args()

    log("="*70)
    log("Disk Operations Hang Point Finder")
    log("="*70)
    log("This will test each operation step-by-step")
    log("If it hangs, the last printed line shows where")
    log("="*70)

    results = []

    for i in range(1, args.iterations + 1):
        result = test_sequence(args.disk, i)
        results.append(result)

        if result != "success":
            log(f"\n⚠ HUNG/FAILED AT: {result}")
            log("Check /proc/<pid>/stack to see kernel state")
            break

        if i < args.iterations:
            log(f"\nSleeping 1s before next iteration...\n")
            time.sleep(1)

    log("\n" + "="*70)
    log("SUMMARY")
    log("="*70)
    for i, result in enumerate(results, 1):
        log(f"  Iteration {i}: {result}")

    return 0 if all(r == "success" for r in results) else 1

if __name__ == "__main__":
    sys.exit(main())
