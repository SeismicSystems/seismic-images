#!/usr/bin/env python3
"""
Test multiple variations of open() to find where it hangs.
Since the hang location is not deterministic, try different patterns.
"""

import os
import sys
import argparse
import time

def test_open_pattern(test_num, description, device_path, flags, do_ioctl=False):
    """Test a specific open pattern."""
    print(f"\n[TEST {test_num}] {description}")
    print(f"  Flags: {flags}")

    try:
        start = time.time()
        print(f"  [{time.time():.3f}] Calling open()...")
        fd = os.open(device_path, flags)
        elapsed = time.time() - start
        print(f"  [{time.time():.3f}] ✓ Opened in {elapsed:.3f}s (fd={fd})")

        if do_ioctl:
            import fcntl
            import struct
            BLKSSZGET = 0x1268
            print(f"  [{time.time():.3f}] Calling BLKSSZGET ioctl...")
            result = fcntl.ioctl(fd, BLKSSZGET, struct.pack('I', 0))
            sector_size = struct.unpack('I', result)[0]
            print(f"  [{time.time():.3f}] ✓ ioctl succeeded, sector_size={sector_size}")

        print(f"  [{time.time():.3f}] Closing...")
        os.close(fd)
        print(f"  [{time.time():.3f}] ✓ Closed")
        return True

    except Exception as e:
        print(f"  ✗ Failed: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(
        description='Test various open() patterns to find non-deterministic hang')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    parser.add_argument('--iterations', type=int, default=5,
                        help='Number of times to repeat (default: 5)')
    args = parser.parse_args()

    print("=" * 70)
    print("Testing Open() Variations")
    print("=" * 70)
    print(f"Device: {args.disk}")
    print(f"Iterations: {args.iterations}")
    print()

    tests = [
        ("Open without O_DIRECT", os.O_RDONLY, False),
        ("Open with O_DIRECT", os.O_RDONLY | os.O_DIRECT, False),
        ("Open with O_DIRECT + O_CLOEXEC", os.O_RDONLY | os.O_DIRECT | os.O_CLOEXEC, False),
        ("Open with O_DIRECT + NONBLOCK", os.O_RDONLY | os.O_DIRECT | os.O_NONBLOCK, False),
        ("Open with O_DIRECT + ioctl", os.O_RDONLY | os.O_DIRECT, True),
    ]

    for iteration in range(1, args.iterations + 1):
        print(f"\n{'='*70}")
        print(f"ITERATION {iteration}/{args.iterations}")
        print(f"{'='*70}")

        for idx, (desc, flags, do_ioctl) in enumerate(tests, 1):
            success = test_open_pattern(idx, desc, args.disk, flags, do_ioctl)
            if not success:
                print(f"\n⚠ Test {idx} failed on iteration {iteration}")
                return 1
            time.sleep(0.1)  # Small delay between tests

        if iteration < args.iterations:
            print(f"\nWaiting 1s before next iteration...")
            time.sleep(1)

    print(f"\n{'='*70}")
    print(f"✓ All tests passed across {args.iterations} iterations")
    print(f"{'='*70}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
