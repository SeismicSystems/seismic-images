#!/usr/bin/env python3
"""Predict RTMR1 for a Seismic UKI booted as a GCP TDX confidential VM.

GCP's TDVF extends RTMR1 with seven events, all derivable from the build:
the boot-option action string, a separator, the boot disk's GPT, the UKI's
authenticode hash, the embedded kernel's authenticode hash, and the two
exit-boot-services strings. Replaying them yields the value a live quote
carries. Verified against seismic-tee-gcp-1 (2026-09-14).
"""

import argparse
import hashlib
import json
import os
import struct
import sys
import tarfile

ACTION_BOOT = b"Calling EFI Application from Boot Option"
ACTION_EXIT_1 = b"Exit Boot Services Invocation"
ACTION_EXIT_2 = b"Exit Boot Services Returned with Success"
SEPARATOR = b"\x00\x00\x00\x00"
LBA = 512


def sha384(data: bytes) -> bytes:
    return hashlib.sha384(data).digest()


def authenticode_sha384(pe: bytes) -> bytes:
    pe_off = struct.unpack_from("<I", pe, 0x3C)[0]
    opt = pe_off + 24
    magic = struct.unpack_from("<H", pe, opt)[0]
    checksum = opt + 64
    data_dirs = opt + (112 if magic == 0x20B else 96)
    cert_entry = data_dirs + 4 * 8
    headers_size = struct.unpack_from("<I", pe, opt + 60)[0]
    cert_addr, cert_size = struct.unpack_from("<II", pe, cert_entry)
    h = hashlib.sha384()
    h.update(pe[:checksum])
    h.update(pe[checksum + 4 : cert_entry])
    h.update(pe[cert_entry + 8 : headers_size])
    nsec = struct.unpack_from("<H", pe, pe_off + 6)[0]
    sec_tbl = opt + struct.unpack_from("<H", pe, pe_off + 20)[0]
    sections = []
    for i in range(nsec):
        raw_size, raw_off = struct.unpack_from("<II", pe, sec_tbl + 40 * i + 16)
        if raw_size:
            sections.append((raw_off, raw_size))
    hashed = headers_size
    for raw_off, raw_size in sorted(sections):
        h.update(pe[raw_off : raw_off + raw_size])
        hashed += raw_size
    trailing = len(pe) - hashed - (cert_size if cert_addr else 0)
    if trailing > 0:
        h.update(pe[hashed : hashed + trailing])
    return h.digest()


def linux_section(uki: bytes) -> bytes:
    pe_off = struct.unpack_from("<I", uki, 0x3C)[0]
    nsec = struct.unpack_from("<H", uki, pe_off + 6)[0]
    sec_tbl = pe_off + 24 + struct.unpack_from("<H", uki, pe_off + 20)[0]
    for i in range(nsec):
        off = sec_tbl + 40 * i
        name = uki[off : off + 8].rstrip(b"\0")
        vsize, _, _, raw_off = struct.unpack_from("<IIII", uki, off + 8)
        if name == b".linux":
            return uki[raw_off : raw_off + vsize]
    sys.exit("no .linux section in UKI")


def disk_head(path: str, nbytes: int) -> bytes:
    if path.endswith((".tar.gz", ".tgz")):
        with tarfile.open(path, "r:gz") as tar:
            member = next(m for m in tar if m.name.endswith("disk.raw"))
            return tar.extractfile(member).read(nbytes)
    with open(path, "rb") as f:
        return f.read(nbytes)


def gpt_event_data(disk: bytes) -> tuple[bytes, str]:
    header = disk[LBA : LBA + 92]
    if header[:8] != b"EFI PART":
        sys.exit("no GPT header at LBA 1")
    entries_lba = struct.unpack_from("<Q", header, 72)[0]
    num_entries, entry_size = struct.unpack_from("<II", header, 80)
    start = entries_lba * LBA
    entries = [
        disk[start + i * entry_size : start + (i + 1) * entry_size] for i in range(num_entries)
    ]
    used = [e for e in entries if any(e[:16])]
    guid = header[56:72]
    disk_guid = "%08x-%04x-%04x-%s-%s" % (
        struct.unpack_from("<I", guid, 0)[0],
        struct.unpack_from("<H", guid, 4)[0],
        struct.unpack_from("<H", guid, 6)[0],
        guid[8:10].hex(),
        guid[10:16].hex(),
    )
    return header + struct.pack("<Q", len(used)) + b"".join(used), disk_guid


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--efi", required=True, help="the UKI, build/<id>_<version>.efi")
    ap.add_argument("--disk", help="GCE disk image (.tar.gz or .raw); default: <efi>.tar.gz")
    ap.add_argument("--expect", help="observed rtmr1 hex to compare against")
    ap.add_argument("--out", help="write JSON here instead of stdout")
    args = ap.parse_args()
    disk_path = args.disk or os.path.splitext(args.efi)[0] + ".tar.gz"

    uki = open(args.efi, "rb").read()
    gpt, disk_guid = gpt_event_data(disk_head(disk_path, 34 * LBA))
    uki_hash = authenticode_sha384(uki)
    kernel_hash = authenticode_sha384(linux_section(uki))

    events = [
        ("EV_EFI_ACTION", ACTION_BOOT.decode(), sha384(ACTION_BOOT)),
        ("EV_SEPARATOR", "00000000", sha384(SEPARATOR)),
        ("EV_EFI_GPT_EVENT", f"disk {disk_guid}", sha384(gpt)),
        ("EV_EFI_BOOT_SERVICES_APPLICATION", "UKI authenticode", uki_hash),
        ("EV_EFI_BOOT_SERVICES_APPLICATION", ".linux authenticode", kernel_hash),
        ("EV_EFI_ACTION", ACTION_EXIT_1.decode(), sha384(ACTION_EXIT_1)),
        ("EV_EFI_ACTION", ACTION_EXIT_2.decode(), sha384(ACTION_EXIT_2)),
    ]
    rtmr1 = b"\0" * 48
    for _, _, digest in events:
        rtmr1 = sha384(rtmr1 + digest)

    base = os.path.basename(args.efi)
    stem = base[: -len(".efi")] if base.endswith(".efi") else base
    result = {
        "attestation_type": "gcp-tdx",
        "measurement_id": stem + ".tar.gz",
        "measurements": {"rtmr1": {"expected": rtmr1.hex()}},
        "events": [
            {"type": t, "description": d, "sha384": h.hex()} for t, d, h in events
        ],
    }
    text = json.dumps(result, indent=2) + "\n"
    if args.out:
        open(args.out, "w").write(text)
    else:
        sys.stdout.write(text)
    if args.expect:
        ok = args.expect.lower().removeprefix("0x") == rtmr1.hex()
        print(f"rtmr1 {'matches' if ok else 'DIFFERS FROM'} expected", file=sys.stderr)
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
