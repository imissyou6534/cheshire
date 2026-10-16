"""CLI regression tests using small, self-contained ELF64 fixtures."""

import hashlib
import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


GENERATOR = Path(__file__).resolve().parents[1] / "gen_rom_payload.py"
SPM = 0x10000000
LIMIT = SPM + 0x10000


def segment(addr=SPM, data=b"\x01\x00\x13\x00", memsz=None, flags=5, **kwargs):
    result = dict(addr=addr, data=data, memsz=len(data) if memsz is None else memsz,
                  flags=flags, kind=1)
    result.update(kwargs)
    return result


def elf_bytes(segments=None, entry=SPM, symbols=False):
    """Pack fixtures independently of pyelftools and the generator."""
    if segments is None:
        segments = [segment()]
    ident = b"\x7fELF\x02\x01\x01" + bytes(9)
    blob = bytearray(64 + 56 * len(segments))
    for index, seg in enumerate(segments):
        offset = len(blob)
        blob.extend(seg["data"])
        struct.pack_into("<IIQQQQQQ", blob, 64 + index * 56,
                         seg["kind"], seg["flags"], seg.get("offset", offset),
                         seg["addr"], seg.get("paddr", seg["addr"]),
                         seg.get("filesz", len(seg["data"])), seg["memsz"], 1)
    shoff = shnum = 0
    if symbols:
        strings = b"\x00buf\x00_start\x00missing\x00"
        string_offset = len(blob)
        blob.extend(strings)
        symbol_offset = len(blob)
        blob.extend(bytes(24))
        for name, shndx, value in [(1, 3, SPM + 0x100), (5, 3, entry), (12, 0, 0)]:
            blob.extend(struct.pack("<IBBHQQ", name, 0x10, 0, shndx, value, 0))
        shoff = len(blob)
        shnum = 4
        blob.extend(bytes(64))
        blob.extend(struct.pack("<IIQQQQIIQQ", 0, 3, 0, 0,
                                string_offset, len(strings), 0, 0, 1, 0))
        blob.extend(struct.pack("<IIQQQQIIQQ", 0, 2, 0, 0,
                                symbol_offset, 96, 1, 1, 8, 24))
        blob.extend(struct.pack("<IIQQQQIIQQ", 0, 1, 6, SPM, 64 + 56 * len(segments),
                                4, 0, 0, 2, 0))
    struct.pack_into("<16sHHIQQQIHHHHHH", blob, 0, ident, 2, 243, 1, entry,
                     64, shoff, 1, 64, 56, len(segments), 64 if shnum else 0,
                     shnum, 0)
    return bytes(blob)


def patched(data, offset, fmt, value):
    result = bytearray(data)
    struct.pack_into(fmt, result, offset, value)
    return bytes(result)


class PayloadCLITest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.elf = self.root / "app.elf"
        self.header = self.root / "payload.h"
        self.manifest = self.root / "payload.json"

    def run_cli(self, data, *options):
        self.elf.write_bytes(data)
        return subprocess.run(
            [sys.executable, "-B", str(GENERATOR), "--elf", str(self.elf),
             "--header", str(self.header), "--manifest", str(self.manifest), *options],
            capture_output=True, text=True, check=False)

    def assert_invalid(self, data, *options):
        self.header.write_bytes(b"existing header\n")
        self.manifest.write_bytes(b"existing manifest\n")
        result = self.run_cli(data, *options)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("error:", result.stderr.lower())
        self.assertNotIn("traceback", result.stderr.lower())
        self.assertEqual(self.header.read_bytes(), b"existing header\n")
        self.assertEqual(self.manifest.read_bytes(), b"existing manifest\n")

    def test_header_contract_and_manifest(self):
        data = elf_bytes([segment(data=b"hello", memsz=16)], symbols=True)
        result = self.run_cli(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.manifest.read_text())
        self.assertEqual(manifest, {
            "entry": SPM,
            "segments": [{"load_addr": SPM, "file_size": 5, "mem_size": 16,
                          "checksum": 0x4F9F2CAB}],
            "elf_sha256": hashlib.sha256(data).hexdigest(),
            "symbols": {"buf": SPM + 0x100, "_start": SPM},
        })
        header = self.header.read_text()
        for declaration in ["#include <stdint.h>", "#include <stddef.h>",
                            "uintptr_t load_addr;", "size_t file_size;",
                            "size_t mem_size;", "const uint8_t *data;",
                            "uint32_t checksum;", "} rom_payload_segment_t;",
                            "static const uint8_t", 'section(".rom_payload")',
                            "aligned(8)",
                            "static const rom_payload_segment_t rom_payload_segments[]",
                            'section(".rom_payload_meta")',
                            "#define ROM_PAYLOAD_NUM_SEGMENTS 1",
                            "#define ROM_PAYLOAD_ENTRY UINT64_C(0x10000000)",
                            "0x68, 0x65, 0x6c, 0x6c, 0x6f", "0x4f9f2cab"]:
            self.assertIn(declaration, header)

    def test_retains_zero_filesz_nonzero_memsz_data_segment(self):
        result = self.run_cli(elf_bytes([
            segment(), segment(SPM + 0x100, b"", memsz=32, flags=6)]))
        self.assertEqual(result.returncode, 0, result.stderr)
        segments = json.loads(self.manifest.read_text())["segments"]
        self.assertEqual(len(segments), 2)
        self.assertEqual(segments[1], dict(load_addr=SPM + 0x100,
                                          file_size=0, mem_size=32, checksum=2166136261))
        self.assertIn("[1]", self.header.read_text())
        self.assertIn("0x00", self.header.read_text())

    def test_rejects_zero_memsz_load_segments(self):
        for flags in [5, 6]:
            with self.subTest(flags=flags):
                self.assert_invalid(elf_bytes([
                    segment(), segment(SPM + 0x100, b"", memsz=0, flags=flags)]))

    def test_deterministic_and_does_not_rewrite_unchanged_outputs(self):
        data = elf_bytes(symbols=True)
        result = self.run_cli(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        paths = [self.header, self.manifest]
        contents = [path.read_bytes() for path in paths]
        import os
        for path in paths:
            os.utime(str(path), ns=(1000000000, 1000000000))
        result = self.run_cli(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([path.read_bytes() for path in paths], contents)
        self.assertEqual([path.stat().st_mtime_ns for path in paths], [1000000000] * 2)

    def test_changed_input_updates_outputs(self):
        self.assertEqual(self.run_cli(elf_bytes()).returncode, 0)
        before = [self.header.read_bytes(), self.manifest.read_bytes()]
        result = self.run_cli(elf_bytes([segment(data=b"abcd")]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(self.header.read_bytes(), before[0])
        self.assertNotEqual(self.manifest.read_bytes(), before[1])

    def test_accepts_rvc_entry_and_exact_upper_bound(self):
        result = self.run_cli(elf_bytes([segment(memsz=0x10000)], entry=SPM + 2))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_adjacent_segments_and_ignores_non_load(self):
        result = self.run_cli(elf_bytes([segment(), segment(SPM + 4, b"xyz", flags=6),
                                        segment(0, b"ignored", kind=4)]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(self.manifest.read_text())["segments"]), 2)

    def test_accepts_eight_load_segments(self):
        result = self.run_cli(elf_bytes([segment(SPM + i * 16) for i in range(8)]))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_nine_load_segments(self):
        self.assert_invalid(elf_bytes([segment(SPM + i * 16) for i in range(9)]))

    def test_rejects_out_of_bounds_memory_including_bss(self):
        for seg in [segment(SPM - 2), segment(LIMIT),
                    segment(LIMIT - 4, memsz=8), segment(SPM, memsz=0x10001)]:
            with self.subTest(segment=seg):
                self.assert_invalid(elf_bytes([seg], entry=seg["addr"]))

    def test_rejects_overlapping_memory_ranges(self):
        for segments in [[segment(memsz=32), segment(SPM + 16, flags=6)],
                         [segment(), segment()],
                         [segment(SPM + 8), segment(memsz=16)],
                         [segment(memsz=32), segment(SPM + 16, b"", memsz=8)]]:
            with self.subTest(segments=segments):
                self.assert_invalid(elf_bytes(segments))

    def test_rejects_filesz_larger_than_memsz(self):
        self.assert_invalid(elf_bytes([segment(memsz=2)]))

    def test_rejects_truncated_file_backed_data(self):
        for data in [elf_bytes()[:-1], elf_bytes([segment(offset=0x10000)]),
                     elf_bytes([segment(filesz=16, memsz=16)])]:
            with self.subTest(data=data):
                self.assert_invalid(data)

    def test_rejects_address_and_file_offset_overflow(self):
        for seg in [segment((1 << 64) - 2, memsz=4),
                    segment(offset=(1 << 64) - 2)]:
            with self.subTest(segment=seg):
                self.assert_invalid(elf_bytes([seg]))

    def test_rejects_vaddr_paddr_mismatch(self):
        self.assert_invalid(elf_bytes([segment(paddr=SPM + 4)]))

    def test_rejects_entry_without_executable_load_segment(self):
        for data in [elf_bytes([]), elf_bytes([segment(flags=6)]),
                     elf_bytes(entry=SPM + 4), elf_bytes(entry=SPM - 2),
                     elf_bytes([segment(), segment(SPM + 16, flags=6)], entry=SPM + 16)]:
            with self.subTest(data=data):
                self.assert_invalid(data)

    def test_rejects_entry_in_executable_zero_fill_tail(self):
        for entry in [SPM + 4, SPM + 6]:
            with self.subTest(entry=entry):
                self.assert_invalid(elf_bytes([segment(memsz=16)], entry=entry))

    def test_rejects_entry_in_zero_fill_only_executable_segment(self):
        self.assert_invalid(elf_bytes([segment(data=b"", memsz=16)]))

    def test_rejects_odd_entry(self):
        self.assert_invalid(elf_bytes(entry=SPM + 1))

    def test_rejects_invalid_elf_formats(self):
        good = elf_bytes()
        cases = [b"", b"not an ELF", good[:63],
                 patched(good, 0, "I", 0), patched(good, 4, "B", 1),
                 patched(good, 5, "B", 2), patched(good, 6, "B", 0),
                 patched(good, 16, "H", 3), patched(good, 18, "H", 62),
                 patched(good, 20, "I", 0), patched(good, 52, "H", 63),
                 patched(good, 54, "H", 55), patched(good, 32, "Q", len(good)),
                 patched(good, 56, "H", 2)]
        for data in cases:
            with self.subTest(data=data):
                self.assert_invalid(data)

    def test_rejects_truncated_symbol_and_section_tables(self):
        good = elf_bytes(symbols=True)
        shoff = struct.unpack_from("<Q", good, 40)[0]
        for data in [good[:-1], patched(good, 58, "H", 63),
                     patched(good, shoff + 2 * 64 + 24, "Q", len(good)),
                     patched(good, shoff + 2 * 64 + 56, "Q", 0)]:
            with self.subTest(data=data):
                self.assert_invalid(data)

    def test_invalid_input_does_not_create_outputs(self):
        result = self.run_cli(b"invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.header.exists())
        self.assertFalse(self.manifest.exists())


if __name__ == "__main__":
    unittest.main()
