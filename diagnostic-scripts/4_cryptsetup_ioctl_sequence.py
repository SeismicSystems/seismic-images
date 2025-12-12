#!/usr/bin/env python3
"""
Replicate the exact ioctl sequence that cryptsetup uses before lseek.
This mimics cryptsetup's behavior from the strace output:
1. Open with O_DIRECT, get sector size, close
2. Open without O_DIRECT (with O_NONBLOCK)
3. Call multiple ioctls: BLKGETSIZE64, BLKGETZONESZ, BLKIOOPT, BLKIOMIN
4. lseek (hangs here)
"""

import os
import fcntl
import struct
import sys
import argparse

def test_cryptsetup_ioctls(device_path):
    """Test the exact ioctl sequence that cryptsetup uses."""
    print("=" * 70)
    print("Replicating cryptsetup's ioctl sequence")
    print("=" * 70)

    # ioctl codes from linux/fs.h
    BLKSSZGET = 0x1268        # _IO(0x12,104) - get sector size
    BLKGETSIZE64 = 0x80081272 # _IOR(0x12,114,size_t) - get device size
    BLKIOMIN = 0x1278         # _IO(0x12,120) - get minimum IO size
    BLKIOOPT = 0x1279         # _IO(0x12,121) - get optimal IO size
    BLKGETZONESZ = 0x80041280 # _IOR(0x12,128,__u32) - get zone size

    try:
        print("\n[PHASE 1] First open with O_DIRECT")
        fd = os.open(device_path, os.O_RDONLY | os.O_DIRECT)
        print(f"  Opened with O_DIRECT (fd={fd})")

        result = fcntl.ioctl(fd, BLKSSZGET, struct.pack('I', 0))
        sector_size = struct.unpack('I', result)[0]
        print(f"  BLKSSZGET: sector_size={sector_size}")

        os.close(fd)
        print("  Closed\n")

        print("[PHASE 2] Second open WITHOUT O_DIRECT (like cryptsetup)")
        fd = os.open(device_path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        print(f"  Opened with O_NONBLOCK|O_CLOEXEC (fd={fd})\n")

        print("[PHASE 3] Running cryptsetup's ioctl sequence:")

        print("  Calling BLKGETSIZE64...")
        result = fcntl.ioctl(fd, BLKGETSIZE64, struct.pack('Q', 0))
        size64 = struct.unpack('Q', result)[0]
        print(f"    Device size: {size64} bytes ({size64 // (1024**3)} GB)")

        print("  Calling BLKGETZONESZ...")
        try:
            result = fcntl.ioctl(fd, BLKGETZONESZ, struct.pack('I', 0))
            zone_size = struct.unpack('I', result)[0]
            print(f"    Zone size: {zone_size}")
        except OSError as e:
            print(f"    Failed (expected): {e}")

        print("  Calling BLKIOOPT...")
        try:
            result = fcntl.ioctl(fd, BLKIOOPT, struct.pack('I', 0))
            ioopt = struct.unpack('I', result)[0]
            print(f"    IO optimal: {ioopt}")
        except OSError as e:
            print(f"    Failed: {e}")

        print("  Calling BLKIOMIN...")
        try:
            result = fcntl.ioctl(fd, BLKIOMIN, struct.pack('I', 0))
            iomin = struct.unpack('I', result)[0]
            print(f"    IO minimum: {iomin}")
        except OSError as e:
            print(f"    Failed: {e}")

        print("\n[PHASE 4] Calling lseek (cryptsetup hangs here)...")
        pos = os.lseek(fd, 0, os.SEEK_SET)
        print(f"  ✓ SUCCESS! lseek returned {pos}")

        os.close(fd)
        print("\n✓ Test completed successfully")
        return True

    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        return False

def main():
    parser = argparse.ArgumentParser(description='Replicate cryptsetup ioctl sequence')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    args = parser.parse_args()

    device_path = args.disk
    print(f"Target device: {device_path}\n")

    success = test_cryptsetup_ioctls(device_path)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
