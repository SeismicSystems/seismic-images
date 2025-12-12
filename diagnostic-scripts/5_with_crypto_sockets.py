#!/usr/bin/env python3
"""
Test if creating AF_ALG crypto sockets between disk operations affects lseek.
The initial successful test had AF_ALG sockets created between opens.
This tests if that makes a difference.
"""

import os
import socket
import sys
import argparse

def test_with_crypto_sockets(device_path):
    """Test disk operations with AF_ALG sockets in between."""
    print("=" * 70)
    print("Testing disk operations with AF_ALG crypto sockets")
    print("=" * 70)

    try:
        print("\n[1] First open with O_DIRECT and close")
        fd = os.open(device_path, os.O_RDONLY | os.O_DIRECT)
        print(f"    Opened (fd={fd})")
        os.close(fd)
        print("    Closed")

        print("\n[2] Creating multiple AF_ALG crypto sockets...")
        algos = ["sha256", "sha512", "sha1"]
        sockets = []

        for algo in algos:
            try:
                sock = socket.socket(socket.AF_ALG, socket.SOCK_SEQPACKET, 0)
                sock.bind(("hash", algo))
                accept_sock = sock.accept()[0]
                sockets.append((sock, accept_sock))
                print(f"    Created {algo} socket")
            except Exception as e:
                print(f"    Failed to create {algo}: {e}")

        print("\n[3] Second open with O_DIRECT")
        fd = os.open(device_path, os.O_RDONLY | os.O_DIRECT)
        print(f"    Opened (fd={fd})")

        print("\n[4] Calling lseek...")
        pos = os.lseek(fd, 0, os.SEEK_SET)
        print(f"    ✓ SUCCESS! lseek returned {pos}")

        os.close(fd)

        # Clean up sockets
        print("\n[5] Cleaning up crypto sockets...")
        for sock, accept_sock in sockets:
            accept_sock.close()
            sock.close()
        print("    Closed all sockets")

        print("\n✓ Test completed successfully")
        return True

    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        # Try to clean up
        try:
            for sock, accept_sock in sockets:
                accept_sock.close()
                sock.close()
        except:
            pass
        return False

def main():
    parser = argparse.ArgumentParser(description='Test disk operations with AF_ALG crypto sockets')
    parser.add_argument('--disk', default='/dev/nvme0n2',
                        help='Block device path (default: /dev/nvme0n2)')
    args = parser.parse_args()

    device_path = args.disk
    print(f"Target device: {device_path}\n")

    success = test_with_crypto_sockets(device_path)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
