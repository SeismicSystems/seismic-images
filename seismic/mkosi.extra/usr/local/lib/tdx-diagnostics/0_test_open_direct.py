#!/usr/bin/env python3
"""
Test if open() with O_DIRECT hangs.
Based on strace showing cryptsetup hanging at the open() call itself.
"""

import os
import sys
import argparse
import time

def test_open_direct(device_path):
    """Test opening with O_DIRECT - this is where cryptsetup hangs."""
    print("=" * 70)
    print("Testing open() with O_DIRECT")
    print("=" * 70)
    print(f"Device: {device_path}\n")

    print("[TEST 1] Open WITHOUT O_DIRECT (baseline)")
    try:
        start = time.time()
        fd = os.open(device_path, os.O_RDONLY)
        elapsed = time.time() - start
        print(f"  ✓ Opened successfully in {elapsed:.3f}s (fd={fd})")
        os.close(fd)
        print(f"  ✓ Closed")
    except Exception as e:
        print(f"  ✗ Failed: {e}")
        return False

    print("\n[TEST 2] Open WITH O_DIRECT (cryptsetup hangs here)")
    try:
        start = time.time()
        print("  Calling open() with O_RDONLY|O_DIRECT...")
        fd = os.open(device_path, os.O_RDONLY | os.O_DIRECT)
        elapsed = time.time() - start
        print(f"  ✓ Opened successfully in {elapsed:.3f}s (fd={fd})")
        os.close(fd)
        print(f"  ✓ Closed")
        print("\n✓ Test passed - no hang!")
        return True
    except Exception as e:
        print(f"  ✗ Failed: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(
        description='Test if open() with O_DIRECT hangs (cryptsetup issue)')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    args = parser.parse_args()

    success = test_open_direct(args.disk)

    if not success:
        print("\n⚠ If this test hangs, cryptsetup will also hang!")
        print("The issue is at open(), not lseek().")

    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
