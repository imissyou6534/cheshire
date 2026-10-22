# SPDX-License-Identifier: Apache-2.0
"""Build the board image and guard the FS-off CRT entry contract."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which('riscv64-unknown-elf-gcc'), 'requires the prepared RISC-V build environment')
class FirmwareTests(unittest.TestCase):
    def test_board_rom_fits_and_main_enables_fs_before_fp(self):
        with tempfile.TemporaryDirectory() as directory:
            subprocess.run([sys.executable, str(ROOT / 'util/build_rom_firmware.py'),
                            '--out', directory, '--app', 'sw/tests/ara_rom_selftest.c'],
                           cwd=ROOT, capture_output=True, text=True, check=True)
            out = Path(directory)
            record = json.loads((out / 'payload.json').read_text())
            self.assertLessEqual(record['rom_bytes'], 16384)
            self.assertEqual(record['app_sources'], [str(ROOT / 'sw/tests/ara_rom_selftest.c')])
            disassembly = (out / 'firmware.dis').read_text()
            main = disassembly.split('<main>:\n', 1)[1].split('\n\n', 1)[0]
            enabled = re.search(r'csrs\s+mstatus,', main)
            self.assertIsNotNone(enabled, 'main must enable vector/FP state')
            before_enable = main[:enabled.start()]
            mnemonics = re.findall(r'^\s*[0-9a-f]+:\s+[0-9a-f]+\s+(\S+)', before_enable, re.MULTILINE)
            fp_instructions = [m for m in mnemonics if m.startswith(('f', 'c.f')) and not m.startswith('fence')]
            self.assertFalse(fp_instructions, 'FP spill before FS enable traps with the existing CRT')
            self.assertIn('<floating_point>:', disassembly)


if __name__ == '__main__':
    unittest.main()
