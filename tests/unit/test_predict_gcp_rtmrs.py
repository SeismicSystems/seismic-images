"""Tests for scripts/predict_gcp_rtmrs.py."""

import hashlib
import json
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import predict_gcp_rtmrs as predictor  # noqa: E402

# The events of image seismic-dev_2026-09-30.596f15 and the registers its GCE guests showed.
CAPTURED = Path(__file__).with_name("gcp-rtmr-events.json")
PE_OFF = 0x40
OPT = PE_OFF + 24
CERT_ENTRY = OPT + 112 + 4 * 8
HEADERS = 0x400
LBA = predictor.LBA


def sha384(data: bytes) -> bytes:
    return hashlib.sha384(data).digest()


def pe(sections: dict[str, bytes], cert: bytes = b"") -> bytes:
    """A PE32+ image: the sections in order, 512-byte aligned, then the certificate table."""
    dos = bytearray(PE_OFF)
    dos[:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, PE_OFF)
    coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, len(sections), 0, 0, 0, 240, 0x22)
    opt = bytearray(240)
    struct.pack_into("<H", opt, 0, 0x20B)
    struct.pack_into("<I", opt, 60, HEADERS)
    struct.pack_into("<I", opt, 64, 0xDEADBEEF)
    struct.pack_into("<I", opt, 108, 16)
    table = bytearray()
    body = bytearray()
    raw_off = HEADERS
    for name, data in sections.items():
        raw_size = (len(data) + 511) // 512 * 512
        entry = bytearray(40)
        entry[:8] = name.encode().ljust(8, b"\0")
        struct.pack_into("<IIII", entry, 8, len(data), raw_off, raw_size, raw_off)
        table += entry
        body += data.ljust(raw_size, b"\0")
        raw_off += raw_size
    image = bytearray((dos + coff + opt + table).ljust(HEADERS, b"\0")) + body
    if cert:
        struct.pack_into("<II", image, CERT_ENTRY, len(image), len(cert))
        image += cert
    return bytes(image)


def gpt_disk(entries: list[bytes], guid: bytes) -> bytes:
    """34 LBAs: a blank MBR, the GPT header at LBA 1, 128 entries of 128 bytes from LBA 2."""
    header = bytearray(92)
    header[:8] = b"EFI PART"
    header[56:72] = guid
    struct.pack_into("<Q", header, 72, 2)
    struct.pack_into("<II", header, 80, 128, 128)
    table = b"".join(e.ljust(128, b"\0") for e in entries).ljust(128 * 128, b"\0")
    return bytes(LBA) + bytes(header).ljust(LBA, b"\0") + table


class Authenticode(unittest.TestCase):
    def test_sections_are_their_virtual_size(self):
        image = pe({".linux": b"kernel", ".cmdline": b"root=/dev/x\0"})
        self.assertEqual(
            predictor.sections(image), {".linux": b"kernel", ".cmdline": b"root=/dev/x\0"}
        )

    def test_checksum_and_certificate_table_are_not_hashed(self):
        plain = pe({".linux": b"kernel", ".initrd": b"initrd"})
        digest = predictor.authenticode_sha384(plain)
        rechecksummed = bytearray(plain)
        struct.pack_into("<I", rechecksummed, OPT + 64, 0)
        self.assertEqual(predictor.authenticode_sha384(bytes(rechecksummed)), digest)
        signed = pe({".linux": b"kernel", ".initrd": b"initrd"}, cert=b"signature" * 8)
        self.assertEqual(predictor.authenticode_sha384(signed), digest)
        edited = pe({".linux": b"kernem", ".initrd": b"initrd"})
        self.assertNotEqual(predictor.authenticode_sha384(edited), digest)


class Gpt(unittest.TestCase):
    def test_event_is_the_header_the_count_and_the_used_entries(self):
        guid = struct.pack("<IHH", 0x12345678, 0x1234, 0x5678) + bytes.fromhex("12345678" * 2)
        used = [b"\x01" * 16 + b"esp", b"\x02" * 16 + b"root"]
        disk = gpt_disk(used + [b""], guid)
        data, disk_guid = predictor.gpt_event_data(disk)
        header = disk[LBA : LBA + 92]
        entries = b"".join(e.ljust(128, b"\0") for e in used)
        self.assertEqual(data, header + struct.pack("<Q", 2) + entries)
        self.assertEqual(disk_guid, "12345678-1234-5678-1234-567812345678")


class Replay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.captured = json.loads(CAPTURED.read_text())

    def events(self, register: str) -> list:
        return [
            (e["type"], e["description"], bytes.fromhex(e["sha384"]))
            for e in self.captured["events"][register]
        ]

    def test_captured_events_fold_to_the_observed_registers(self):
        for register in ("rtmr1", "rtmr2"):
            expected = self.captured["measurements"][register]["expected"]
            self.assertEqual(predictor.replay(self.events(register)).hex(), expected, register)

    def test_constant_events_hash_as_captured(self):
        rtmr1 = {description: digest for _, description, digest in self.events("rtmr1")}
        self.assertEqual(rtmr1[predictor.ACTION_BOOT.decode()], sha384(predictor.ACTION_BOOT))
        self.assertEqual(rtmr1["00000000"], sha384(predictor.SEPARATOR))
        self.assertEqual(rtmr1[predictor.ACTION_EXIT_1.decode()], sha384(predictor.ACTION_EXIT_1))
        self.assertEqual(rtmr1[predictor.ACTION_EXIT_2.decode()], sha384(predictor.ACTION_EXIT_2))
        rtmr2 = {description: digest for _, description, digest in self.events("rtmr2")}
        for name in (".linux", ".cmdline", ".initrd", ".uname", ".sbat"):
            self.assertEqual(rtmr2[f"{name} name"], sha384(name.encode() + b"\0"))
        self.assertEqual(rtmr2["Linux initrd"], rtmr2[".initrd contents"])

    def test_prediction_orders_events_as_captured(self):
        kernel = pe({".text": b"vmlinuz"})
        uki = pe(
            {
                ".linux": kernel,
                ".cmdline": b"console=ttyS0\0",
                ".initrd": b"initrd",
                ".uname": b"6.17.0",
                ".sbat": b"sbat,1",
            }
        )
        disk = gpt_disk([b"\x01" * 16], bytes(range(16)))
        rtmr1, rtmr2 = predictor.predict(uki, disk)
        captured1 = [(e["type"], e["description"]) for e in self.captured["events"]["rtmr1"]]
        captured2 = [(e["type"], e["description"]) for e in self.captured["events"]["rtmr2"]]
        self.assertEqual(
            [(t, d) for t, d, _ in rtmr1 if t != "EV_EFI_GPT_EVENT"],
            [(t, d) for t, d in captured1 if t != "EV_EFI_GPT_EVENT"],
        )
        gpt = ("EV_EFI_GPT_EVENT", "disk 03020100-0504-0706-0809-0a0b0c0d0e0f")
        self.assertEqual(rtmr1[2][:2], gpt)
        self.assertEqual([(t, d) for t, d, _ in rtmr2], captured2)
        self.assertEqual(rtmr1[3][2], predictor.authenticode_sha384(uki))
        self.assertEqual(rtmr1[4][2], predictor.authenticode_sha384(kernel))
        self.assertEqual(rtmr2[1][2], sha384(kernel))
        self.assertEqual(rtmr2[10][2], sha384("console=ttyS0".encode("utf-16-le") + b"\0\0"))
        self.assertEqual(rtmr2[11][2], sha384(b"initrd"))


if __name__ == "__main__":
    unittest.main()
