#!/usr/bin/env python3
"""
Test basic disk operations that cryptsetup performs.
This script tests opening, seeking, and reading from block devices.
"""

import os
import sys
import errno
import fcntl
import struct
import argparse

def test_open_device(device_path):
    """Test opening a block device."""
    print(f"[TEST] Opening device: {device_path}")
    try:
        fd = os.open(device_path, os.O_RDONLY | os.O_CLOEXEC)
        print(f"  ✓ Successfully opened device (fd={fd})")
        return fd
    except OSError as e:
        print(f"  ✗ Failed to open device: {e}")
        return None

def test_lseek(fd, offset, whence_name, whence):
    """Test lseek operation on a file descriptor."""
    print(f"[TEST] lseek(fd={fd}, offset={offset}, whence={whence_name})")
    try:
        result = os.lseek(fd, offset, whence)
        print(f"  ✓ lseek succeeded, new position: {result}")
        return result
    except OSError as e:
        print(f"  ✗ lseek failed: {e} (errno={e.errno}, {errno.errorcode.get(e.errno, 'UNKNOWN')})")
        return None

def test_read(fd, size):
    """Test reading from a file descriptor."""
    print(f"[TEST] read(fd={fd}, size={size})")
    try:
        data = os.read(fd, size)
        print(f"  ✓ read succeeded, got {len(data)} bytes")
        return data
    except OSError as e:
        print(f"  ✗ read failed: {e}")
        return None

def test_get_device_size(fd):
    """Get the size of a block device using ioctl."""
    print(f"[TEST] Getting device size via BLKGETSIZE64 ioctl")
    try:
        # BLKGETSIZE64 = 0x80081272
        BLKGETSIZE64 = 0x80081272
        buf = bytearray(8)
        fcntl.ioctl(fd, BLKGETSIZE64, buf)
        size = struct.unpack('Q', buf)[0]
        print(f"  ✓ Device size: {size} bytes ({size // (1024**3)} GB)")
        return size
    except OSError as e:
        print(f"  ✗ ioctl failed: {e}")
        return None

def test_luks_header_read(fd):
    """Test reading the LUKS header (first 4KB)."""
    print("[TEST] Reading LUKS header (first 4KB)")

    # Seek to beginning
    pos = test_lseek(fd, 0, "SEEK_SET", os.SEEK_SET)
    if pos is None:
        return None

    # Read LUKS header
    data = test_read(fd, 4096)
    if data is None:
        return None

    # Check for LUKS magic
    if data[:6] == b'LUKS\xba\xbe':
        print("  ✓ Found LUKS1 magic signature")
        return data
    elif data[:6] == b'LUKSV2':
        print("  ✓ Found LUKS2 magic signature")
        return data
    else:
        print(f"  ! No LUKS signature found. First 16 bytes: {data[:16].hex()}")
        return data

def test_seek_patterns(fd, device_size):
    """Test various seek patterns that cryptsetup might use."""
    print("\n[TEST] Testing various seek patterns")

    test_positions = [
        (0, "Start of device", os.SEEK_SET),
        (512, "First sector", os.SEEK_SET),
        (4096, "First 4K block", os.SEEK_SET),
        (16 * 1024 * 1024, "16MB offset (typical LUKS data start)", os.SEEK_SET),
    ]

    if device_size:
        test_positions.append((device_size - 512, "Last sector", os.SEEK_SET))
        test_positions.append((-512, "Last sector (from end)", os.SEEK_END))

    for offset, description, whence in test_positions:
        print(f"\n  Testing: {description}")
        pos = test_lseek(fd, offset, "SEEK_SET" if whence == os.SEEK_SET else "SEEK_END", whence)
        if pos is not None:
            # Try to read a small amount
            data = test_read(fd, 512)
            if data:
                print(f"    First 16 bytes: {data[:16].hex()}")

def main():
    parser = argparse.ArgumentParser(description='Test basic disk operations')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    args = parser.parse_args()

    device_path = args.disk

    print("=" * 70)
    print("Disk Operations Test Suite")
    print("=" * 70)
    print(f"Target device: {device_path}")
    print()

    # Test 1: Open device
    fd = test_open_device(device_path)
    if fd is None:
        print("\n[FATAL] Cannot open device, aborting tests")
        sys.exit(1)

    try:
        # Test 2: Get device size
        device_size = test_get_device_size(fd)
        print()

        # Test 3: Basic lseek operations
        print("\n" + "=" * 70)
        print("Basic lseek tests")
        print("=" * 70)
        test_lseek(fd, 0, "SEEK_SET", os.SEEK_SET)
        test_lseek(fd, 0, "SEEK_CUR", os.SEEK_CUR)
        if device_size:
            test_lseek(fd, 0, "SEEK_END", os.SEEK_END)

        # Test 4: Read LUKS header
        print("\n" + "=" * 70)
        print("LUKS Header Test")
        print("=" * 70)
        test_luks_header_read(fd)

        # Test 5: Various seek patterns
        print("\n" + "=" * 70)
        print("Seek Pattern Tests")
        print("=" * 70)
        test_seek_patterns(fd, device_size)

        print("\n" + "=" * 70)
        print("Test suite completed")
        print("=" * 70)

    finally:
        os.close(fd)
        print(f"\nClosed device descriptor")

if __name__ == "__main__":
    main()
