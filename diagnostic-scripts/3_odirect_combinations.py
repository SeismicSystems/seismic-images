#!/usr/bin/env python3
"""
Test different combinations of O_DIRECT flag usage to identify the trigger.
Tests all permutations:
1. Both opens WITH O_DIRECT
2. First WITHOUT, second WITH
3. First WITH, second WITHOUT
4. Both WITHOUT O_DIRECT
"""

import os
import fcntl
import struct
import sys
import argparse

def run_test(device_path, test_num, first_flags, second_flags, description):
    """Run a single test with specific flags."""
    print(f"\n{'='*70}")
    print(f"Test {test_num}: {description}")
    print(f"{'='*70}")

    BLKSSZGET = 0x1268

    try:
        print(f"[1] First open: {first_flags}")
        fd = os.open(device_path, first_flags)
        print(f"    fd={fd}")

        # Do an ioctl like cryptsetup does
        result = fcntl.ioctl(fd, BLKSSZGET, struct.pack('I', 0))
        sector_size = struct.unpack('I', result)[0]
        print(f"    BLKSSZGET returned {sector_size}")

        os.close(fd)
        print("    Closed")

        print(f"\n[2] Second open: {second_flags}")
        fd = os.open(device_path, second_flags)
        print(f"    fd={fd}")

        print("\n[3] Calling lseek...")
        pos = os.lseek(fd, 0, os.SEEK_SET)
        print(f"    ✓ lseek succeeded! Returned {pos}")

        os.close(fd)
        print("    Closed")
        print(f"\n✓ Test {test_num} PASSED\n")
        return True

    except Exception as e:
        print(f"\n✗ Test {test_num} FAILED: {e}\n")
        try:
            os.close(fd)
        except:
            pass
        return False

def main():
    parser = argparse.ArgumentParser(description='Test O_DIRECT flag combinations')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    args = parser.parse_args()

    device_path = args.disk

    print("=" * 70)
    print("Testing O_DIRECT flag combinations")
    print("=" * 70)
    print(f"Target device: {device_path}")

    tests = [
        (1, os.O_RDONLY | os.O_DIRECT, os.O_RDONLY | os.O_DIRECT,
         "Both opens WITH O_DIRECT"),

        (2, os.O_RDONLY, os.O_RDONLY | os.O_DIRECT,
         "First WITHOUT O_DIRECT, second WITH O_DIRECT"),

        (3, os.O_RDONLY | os.O_DIRECT, os.O_RDONLY,
         "First WITH O_DIRECT, second WITHOUT"),

        (4, os.O_RDONLY, os.O_RDONLY,
         "Both opens WITHOUT O_DIRECT"),

        (5, os.O_RDONLY | os.O_DIRECT, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC,
         "First WITH O_DIRECT, second WITHOUT O_DIRECT but with O_NONBLOCK (like cryptsetup)"),
    ]

    results = []
    for test_num, first_flags, second_flags, description in tests:
        result = run_test(device_path, test_num, first_flags, second_flags, description)
        results.append((test_num, description, result))

    # Summary
    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    for test_num, description, result in results:
        status = "✓ PASS" if result else "✗ FAIL (HANG)"
        print(f"Test {test_num}: {status}")
        print(f"  {description}")
        print()

if __name__ == "__main__":
    main()
