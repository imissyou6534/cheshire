# SPDX-License-Identifier: Apache-2.0
"""Host-side contract for accepting hardware simulation results."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ResultContractTest(unittest.TestCase):
    def runner(self):
        path = ROOT / 'util/run_multitile_sim.py'
        self.assertTrue(path.is_file(), 'unified multi-tile runner is required')
        spec = importlib.util.spec_from_file_location('multitile_runner', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_accepts_complete_per_tile_result(self):
        runner = self.runner()
        rows = [dict(tile=0, raw=1), dict(tile=1, raw=1)]
        self.assertIsNone(runner.validate_result(0, 'PASS MULTITILE\n', rows, 2, 0))

    def test_rejects_exit_status_missing_tiles_and_false_pass(self):
        runner = self.runner()
        cases = [(1, 'PASS MULTITILE\n', [dict(tile=0, raw=1)]),
                 (0, 'PASS MULTITILE\n', []),
                 (0, 'PASS MULTITILE\n', [dict(tile=0, raw=3)]),
                 (0, 'PASS MULTITILE\nFatal: checker\n', [dict(tile=0, raw=1)]),
                 (0, 'Cannot open file cmem.hex\nPASS MULTITILE\n', [dict(tile=0, raw=1)]),
                 (0, 'firmware says PASS\n', [dict(tile=0, raw=1)])]
        for status, log, rows in cases:
            with self.subTest(status=status, log=log, rows=rows):
                self.assertIsNotNone(runner.validate_result(status, log, rows, 1, 0))

    def test_nonzero_expected_return_requires_exact_code(self):
        runner = self.runner()
        self.assertIsNone(runner.validate_result(0, 'PASS MULTITILE\n', [dict(tile=0, raw=15)], 1, 7))
        self.assertIsNotNone(runner.validate_result(0, 'PASS MULTITILE\n', [dict(tile=0, raw=1)], 1, 7))

    def test_rejects_duplicate_out_of_range_and_unfinished_tiles(self):
        runner = self.runner()
        self.assertIsNotNone(runner.validate_result(0, 'PASS MULTITILE\n', [dict(tile=0, raw=1)]*2, 2, 0))
        self.assertIsNotNone(runner.validate_result(0, 'PASS MULTITILE\n', [dict(tile=1, raw=1)], 1, 0))
        self.assertIsNotNone(runner.validate_result(0, 'PASS MULTITILE\n', [dict(tile=0, raw=2)], 1, 0))

    @unittest.skipUnless(hasattr(os, 'killpg'), 'POSIX process groups are required')
    def test_timeout_stops_tool_descendants(self):
        runner = self.runner()
        self.assertTrue(hasattr(runner, 'run_timed'), 'tool timeout must stop its process group')
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / 'survived'
            child = 'import time; from pathlib import Path; time.sleep(1); Path({!r}).write_text("bad")'.format(str(sentinel))
            parent = 'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",{!r}]); time.sleep(10)'.format(child)
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run_timed([sys.executable, '-c', parent], timeout=0.15)
            time.sleep(1.1)
            self.assertFalse(sentinel.exists())


if __name__ == '__main__':
    unittest.main()
