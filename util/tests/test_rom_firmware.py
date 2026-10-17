# SPDX-License-Identifier: Apache-2.0
"""Exercise the real RISC-V build and the ROM/SPM address contract."""
import hashlib
import io
import json
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from elftools.elf.elffile import ELFFile


ROOT = Path(__file__).resolve().parents[2]


def fnv1a(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


@unittest.skipUnless(shutil.which('riscv64-unknown-elf-gcc') and shutil.which('bender'),
                     'RISC-V GCC and Bender are required')
class FirmwareBuildTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='rom-firmware-test-')
        cls.directory = Path(cls.temporary.name)
        cls.out = cls.directory / 'hello'
        build = cls.build(cls.out)
        if build.returncode:
            raise RuntimeError(build.stdout + build.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    @staticmethod
    def build(out, *args):
        return subprocess.run(['bash', 'util/build_rom_autoboot.sh', '--out', str(out), *args],
                              cwd=ROOT, capture_output=True, text=True)

    def elf(self):
        path = self.out / 'firmware.elf'
        self.assertTrue(path.is_file(), 'unified firmware.elf must be generated')
        return ELFFile(io.BytesIO(path.read_bytes()))

    def test_separate_rom_and_spm_addresses_in_one_elf(self):
        elf = self.elf()
        loads = [p for p in elf.iter_segments() if p['p_type'] == 'PT_LOAD']
        self.assertEqual(elf.header['e_entry'], 0x02000000)
        self.assertEqual(len(loads), 2)
        boot, app = loads
        self.assertEqual(boot['p_vaddr'], 0x02000000)
        self.assertEqual(boot['p_paddr'], 0x02000000)
        self.assertEqual(app['p_vaddr'], 0x10000000)
        self.assertGreaterEqual(app['p_paddr'], boot['p_paddr'] + boot['p_filesz'])
        self.assertLessEqual(app['p_paddr'] + app['p_filesz'], 0x02004000)
        self.assertGreater(app['p_memsz'], app['p_filesz'])

    def test_binary_snapshot_manifest_and_checksum_agree(self):
        elf = self.elf()
        binary = (self.out / 'firmware.bin').read_bytes()
        manifest = json.loads((self.out / 'payload.json').read_text())
        for segment in elf.iter_segments():
            if segment['p_type'] == 'PT_LOAD':
                offset = segment['p_paddr'] - 0x02000000
                self.assertEqual(binary[offset:offset + segment['p_filesz']], segment.data())
        app = next(p.data() for p in elf.iter_segments()
                   if p['p_type'] == 'PT_LOAD' and p['p_vaddr'] == 0x10000000)
        self.assertTrue((self.out / 'application.bin').is_file(), 'external loading needs the same application bytes')
        self.assertEqual((self.out / 'application.bin').read_bytes(), app)
        self.assertEqual(elf.get_section_by_name('.rom_checksum').data(), struct.pack('<I', fnv1a(app)))
        self.assertEqual(manifest['firmware_sha256'], hashlib.sha256((self.out / 'firmware.elf').read_bytes()).hexdigest())
        self.assertEqual(manifest['entry'], 0x10000000)
        self.assertEqual(len(manifest['segments']), 1)
        self.assertEqual(manifest['segments'][0]['checksum'], fnv1a(app))
        snapshot = Path(manifest['rom_snapshot'])
        self.assertEqual(snapshot.stem, hashlib.sha256(snapshot.read_bytes()).hexdigest())
        words = re.findall(r'\d+: data_o = 32\x27h([0-9a-fA-F]{8})', snapshot.read_text())
        decoded = b''.join(struct.pack('<I', int(word, 16)) for word in words)
        self.assertEqual(decoded, binary + bytes(len(decoded) - len(binary)))

    def test_debug_artifacts_and_scalar_loader(self):
        self.elf()
        for name in ['firmware.dis', 'firmware.dump', 'firmware.map', 'firmware.segments']:
            self.assertGreater((self.out / name).stat().st_size, 0)
        disassembly = (self.out / 'firmware.dis').read_text()
        self.assertIn('vle8.v', disassembly)
        self.assertIn('vse8.v', disassembly)
        boot = subprocess.check_output(['riscv64-unknown-elf-objdump', '-d', '-j', '.boot',
                                        str(self.out / 'firmware.elf')], text=True)
        self.assertNotRegex(boot, r'\t[vV][a-z0-9.]+\s')
        self.assertFalse((self.out / 'rom_payload.h').exists())

    def test_custom_program_bulk_and_noload_bss(self):
        source = self.directory / 'custom.c'
        source.write_text('volatile unsigned char data[5] = {1,2,3,4,5};\n'
                          'volatile unsigned char bulk[4] __attribute__((section(".bulk"))) = {6,7,8,9};\n'
                          'volatile unsigned char zeros[4096];\n'
                          'int main(void) { return data[0] + bulk[0] + zeros[4095] - 7; }\n')
        out = self.directory / 'custom'
        build = self.build(out, '--app', str(source))
        self.assertEqual(build.returncode, 0, build.stderr)
        elf = ELFFile(io.BytesIO((out / 'firmware.elf').read_bytes()))
        self.assertEqual(elf.get_section_by_name('.bss')['sh_type'], 'SHT_NOBITS')
        app = next(s for s in elf.iter_segments() if s['p_type'] == 'PT_LOAD' and s['p_vaddr'] == 0x10000000)
        self.assertGreaterEqual(app['p_memsz'] - app['p_filesz'], 4096)

    def test_minimal_scalar_program_without_data_or_bss(self):
        source = self.directory / 'minimal.c'
        source.write_text('int main(void) { return 7; }\n')
        out = self.directory / 'minimal'
        build = self.build(out, '--app', str(source), '--app-march', 'rv64gc_zifencei')
        self.assertEqual(build.returncode, 0, build.stderr)
        elf = ELFFile(io.BytesIO((out / 'firmware.elf').read_bytes()))
        app = next(p for p in elf.iter_segments() if p['p_type'] == 'PT_LOAD' and p['p_vaddr'] == 0x10000000)
        self.assertEqual(app['p_filesz'], app['p_memsz'])
        self.assertEqual((out / 'application.bin').read_bytes(), app.data())

    def test_aligned_bss_preserves_load_and_execution_offset(self):
        source = self.directory / 'aligned_bss.c'
        source.write_text('volatile unsigned char zeros[4096] __attribute__((aligned(64)));\n'
                          'int main(void) { return zeros[0]; }\n')
        out = self.directory / 'aligned_bss'
        build = self.build(out, '--app', str(source), '--app-march', 'rv64gc_zifencei')
        self.assertEqual(build.returncode, 0, build.stderr)
        elf = ELFFile(io.BytesIO((out / 'firmware.elf').read_bytes()))
        app = next(p for p in elf.iter_segments() if p['p_type'] == 'PT_LOAD' and p['p_vaddr'] == 0x10000000)
        bss = elf.get_section_by_name('.bss')
        self.assertEqual(app['p_memsz'], bss['sh_addr'] + bss['sh_size'] - app['p_vaddr'])

    def test_high_alignment_keeps_rom_and_spm_offsets_equal(self):
        source = self.directory / 'aligned.c'
        source.write_text('volatile unsigned char aligned[4] __attribute__((aligned(4096))) = {1,2,3,4};\n'
                          'int main(void) { return aligned[0] - 1; }\n')
        out = self.directory / 'aligned'
        build = self.build(out, '--app', str(source))
        self.assertEqual(build.returncode, 0, build.stderr)
        elf = ELFFile(io.BytesIO((out / 'firmware.elf').read_bytes()))
        app = next(p for p in elf.iter_segments() if p['p_type'] == 'PT_LOAD' and p['p_vaddr'] == 0x10000000)
        symbols = {s.name: s['st_value'] for s in elf.get_section_by_name('.symtab').iter_symbols()}
        offset = symbols['aligned'] - app['p_vaddr']
        self.assertEqual(app.data()[offset:offset+4], bytes([1, 2, 3, 4]))

    def test_readonly_bender_manifest_preserves_dependency_heads(self):
        helper = ROOT / 'util/rom_bender.py'
        self.assertTrue(helper.is_file(), 'ROM builds need read-only dependency resolution')
        repositories = sorted((ROOT / '.bender/git/checkouts').iterdir())
        before = {str(path): subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'])
                  for path in repositories if (path / '.git').exists()}
        result = subprocess.run(['python3', str(helper), 'script', 'flist-plus', '--no-default-target',
                                 '-t', 'rtl', '-t', 'cva6', '-t', 'cv64a6_imafdcv_sv39',
                                 '-t', 'exclude_first_pass_decoder'], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(ROOT / 'hw/cheshire_soc.sv'), result.stdout)
        after = {path: subprocess.check_output(['git', '-C', path, 'rev-parse', 'HEAD']) for path in before}
        self.assertEqual(before, after)

    def test_rom_overflow_is_rejected(self):
        source = self.directory / 'oversize.c'
        source.write_text('volatile const unsigned char oversized[20000] = {1};\n'
                          'int main(void) { return oversized[0]; }\n')
        build = self.build(self.directory / 'oversize', '--app', str(source))
        self.assertNotEqual(build.returncode, 0)

    def test_prelinked_elf_is_rejected_explicitly(self):
        self.elf()
        build = self.build(self.directory / 'invalid', '--app', str(self.out / 'firmware.elf'))
        self.assertNotEqual(build.returncode, 0)
        self.assertIn('source', build.stderr.lower())

    def test_spm_bss_overflow_is_rejected(self):
        source = self.directory / 'spm_oversize.c'
        source.write_text('volatile unsigned char oversized[70000];\n'
                          'int main(void) { return oversized[69999]; }\n')
        build = self.build(self.directory / 'spm_oversize', '--app', str(source))
        self.assertNotEqual(build.returncode, 0)

    def test_negative_image_has_real_checksum_and_distinct_loader(self):
        self.elf()
        out = self.directory / 'negative'
        build = self.build(out, '--bad-checksum')
        self.assertEqual(build.returncode, 0, build.stderr)
        elf = ELFFile(io.BytesIO((out / 'firmware.elf').read_bytes()))
        app = next(p.data() for p in elf.iter_segments()
                   if p['p_type'] == 'PT_LOAD' and p['p_vaddr'] == 0x10000000)
        self.assertEqual(elf.get_section_by_name('.rom_checksum').data(), struct.pack('<I', fnv1a(app)))
        self.assertTrue(json.loads((out / 'payload.json').read_text())['bad_checksum'])
        self.assertNotEqual((out / 'firmware.bin').read_bytes(), (self.out / 'firmware.bin').read_bytes())

    def test_repeated_build_keeps_identical_rom_snapshot(self):
        self.elf()
        before = json.loads((self.out / 'payload.json').read_text())
        snapshot = Path(before['rom_snapshot'])
        modified = snapshot.stat().st_mtime_ns
        build = self.build(self.out)
        self.assertEqual(build.returncode, 0, build.stderr)
        after = json.loads((self.out / 'payload.json').read_text())
        self.assertEqual(before['binary_sha256'], after['binary_sha256'])
        self.assertEqual(before['rom_snapshot'], after['rom_snapshot'])
        self.assertEqual(modified, snapshot.stat().st_mtime_ns)


if __name__ == '__main__':
    unittest.main()
