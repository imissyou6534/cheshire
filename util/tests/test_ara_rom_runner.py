# SPDX-License-Identifier: Apache-2.0
"""Check CLI rejection and fresh-evidence requirements without running VCS."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class RunnerTests(unittest.TestCase):
    def test_invalid_uart_timing_is_rejected_before_build(self):
        for options in (['--uart-bit-period-ns', '0'],
                        ['--uart-bit-period-ns', '-1'],
                        ['--boot', 'spm', '--testbench', 'fft-ddr', '--uart-bit-period-ns', '320']):
            with self.subTest(options=options):
                result = subprocess.run([sys.executable, str(ROOT / 'util/run_multitile_sim.py'), *options],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn('UART timing override requires', result.stderr)

    def test_stale_mismatch_cannot_pass_an_early_build_failure(self):
        with patch.object(sys, 'path', [str(ROOT / 'util'), *sys.path]):
            spec = importlib.util.spec_from_file_location('ara_rom_runner', ROOT / 'util/run_ara_rom_selftest.py')
            runner = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'util').mkdir()
            # A real subprocess failing before it writes any simulation evidence.
            (root / 'util/run_multitile_sim.py').write_text('raise SystemExit(1)\n')
            out = root / 'output'
            out.mkdir()
            (out / 'run.log').write_text('FAIL MULTITILE UART mismatch tile=0 byte=0\n')
            (out / 'result.json').write_text(json.dumps(dict(hardware_unchanged=True)))
            args = ['run_ara_rom_selftest.py', '--out', str(out), '--wrong-uart']
            with patch.object(runner, 'ROOT', root), patch.object(sys, 'argv', args), redirect_stderr(io.StringIO()):
                self.assertEqual(runner.main(), 1)
            self.assertFalse((out / 'run.log').exists())
            self.assertFalse((out / 'result.json').exists())


if __name__ == '__main__':
    unittest.main()
