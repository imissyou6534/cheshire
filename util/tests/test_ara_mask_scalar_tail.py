# SPDX-License-Identifier: Apache-2.0
import importlib.util
from pathlib import Path
import struct
import unittest


class MaskScalarOracleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[1] / 'run_ara_mask_scalar_tail.py'
        spec = importlib.util.spec_from_file_location('mask_scalar_oracle', path)
        cls.oracle = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.oracle)

    def result(self, vl, pattern, mode):
        data, _, _ = self.oracle.expected()
        index = (self.oracle.LENGTHS.index(vl)*7 + pattern)*4 + mode
        return struct.unpack_from('<Ii', data, 16+index*8)

    def test_original_tail_ones_do_not_count(self):
        self.assertEqual(self.result(4, 5, 0), (2, 0))

    def test_tail_only_bit_does_not_create_a_first_match(self):
        self.assertEqual(self.result(4, 4, 0), (0, -1))
        self.assertEqual(self.result(17, 4, 0), (0, -1))

    def test_empty_vectors_and_execution_masks(self):
        self.assertEqual(self.result(0, 1, 0), (0, -1))
        self.assertEqual(self.result(32, 1, 2), (0, -1))
        self.assertEqual(self.result(17, 1, 3), (8, 1))

    def test_slice_and_word_boundaries(self):
        for vl in (15,16,17,127,128,129,255,256,257,511,512):
            with self.subTest(vl=vl):
                self.assertEqual(self.result(vl, 1, 0), (vl, 0))
                self.assertEqual(self.result(vl, 6, 0), (1, vl-1))

    def test_complete_fixed_size_axi_record(self):
        data, uart, cases = self.oracle.expected()
        self.assertEqual(cases, 1708)
        self.assertEqual(len(data), 16+2048*8)
        self.assertEqual(struct.unpack_from('<4I', data), (0x4d534b31, cases, 0, 0))
        self.assertEqual(data[16+cases*8:], bytes((2048-cases)*8))
        self.assertIn(b'cases=1708 checks=3416 failed=0\r\n', uart)


if __name__ == '__main__':
    unittest.main()
