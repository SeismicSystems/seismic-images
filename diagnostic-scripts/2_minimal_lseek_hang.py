#!/usr/bin/env python3
"""
Minimal test case to trigger the lseek hang.
Based on debugging, the simplest trigger is:
1. Open with O_DIRECT, close
2. Open again (with any flags)
3. lseek hangs
"""

import os
import sys
import argparse

def test_minimal_hang(device_path):
    """Minimal test case for lseek hang."""
    print("=" * 70)
    print("Minimal test case for lseek hang")
    print("=" * 70)
    print(f"Device: {device_path}\n")

    try:
        print("[1] Open device with O_DIRECT")
        fd = os.open(device_path, os.O_RDONLY | os.O_DIRECT)
        print(f"    Opened (fd={fd})")

        print("[2] Close device")
        os.close(fd)
        print("    Closed")

        print("\n[3] Open device again with O_DIRECT")
        fd = os.open(device_path, os.O_RDONLY | os.O_DIRECT)
        print(f"    Opened (fd={fd})")

        print("\n[4] Call lseek (this is where it hangs)...")
        print("    Calling lseek(fd, 0, SEEK_SET)...")
        pos = os.lseek(fd, 0, os.SEEK_SET)

        print(f"    ✓ SUCCESS! lseek returned {pos}")
        os.close(fd)
        print("\n✓ Test completed successfully")
        return True

    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        return False

def test_without_odirect(device_path):
    """Control test: same sequence without O_DIRECT."""
    print("\n" + "=" * 70)
    print("Control test: WITHOUT O_DIRECT")
    print("=" * 70)

    try:
        print("[1] Open device")
        fd = os.open(device_path, os.O_RDONLY)
        print(f"    Opened (fd={fd})")

        print("[2] Close device")
        os.close(fd)
        print("    Closed")

        print("\n[3] Open device again")
        fd = os.open(device_path, os.O_RDONLY)
        print(f"    Opened (fd={fd})")

        print("\n[4] Call lseek...")
        pos = os.lseek(fd, 0, os.SEEK_SET)
        print(f"    ✓ lseek returned {pos}")

        os.close(fd)
        print("\n✓ Control test passed")
        return True

    except Exception as e:
        print(f"\n✗ Control test failed: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description='Minimal test case for lseek hang')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    args = parser.parse_args()

    device_path = args.disk

    # Run both tests
    result1 = test_minimal_hang(device_path)
    result2 = test_without_odirect(device_path)

    print("\n" + "=" * 70)
    print("RESULTS")
    print("=" * 70)
    print(f"Minimal O_DIRECT test: {'PASS' if result1 else 'HANG'}")
    print(f"Control (no O_DIRECT): {'PASS' if result2 else 'FAIL'}")

    if not result1 and result2:
        print("\n⚠ Confirmed: O_DIRECT causes lseek to hang!")

if __name__ == "__main__":
    main()
