# SPDX-License-Identifier: Apache-2.0
import importlib.util
from pathlib import Path
import struct
import unittest


class ReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[1] / 'ara_rom_reference.py'
        cls.path = path
        cls.ref = None
        if path.is_file():
            spec = importlib.util.spec_from_file_location('ara_rom_reference', path)
            cls.ref = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.ref)

    def reference(self):
        self.assertIsNotNone(self.ref, 'independent Ara ROM reference is missing')
        return self.ref

    def test_signed_division_rounds_toward_zero(self):
        r = self.reference()
        self.assertEqual(r.integer('vdiv', 0xfffffff9, 3), 0xfffffffe)
        self.assertEqual(r.integer('vrem', 0xfffffff9, 3), 0xffffffff)

    def test_division_architectural_edges(self):
        r = self.reference()
        self.assertEqual(r.integer('vdiv', 0x80000000, 0xffffffff), 0x80000000)
        self.assertEqual(r.integer('vrem', 0x80000000, 0xffffffff), 0)
        self.assertEqual(r.integer('vdiv', 12, 0), 0xffffffff)
        self.assertEqual(r.integer('vrem', 12, 0), 12)
        self.assertEqual(r.integer('vdivu', 12, 0), 0xffffffff)

    def test_wrap_and_shift(self):
        r = self.reference()
        self.assertEqual(r.integer('vadd', 0xffffffff, 2), 1)
        self.assertEqual(r.integer('vsra', 0x80000000, 36), 0xf8000000)
        self.assertEqual(r.integer('vsrl', 0x80000000, 36), 0x08000000)

    def test_ieee_bits(self):
        r = self.reference()
        self.assertEqual(r.fp_bits(-2.5, 32), 0xc0200000)
        self.assertEqual(r.fp_bits(0.5, 64), 0x3fe0000000000000)

    def test_uart_and_summary(self):
        r = self.reference()
        uart, summary = r.expected()
        self.assertIn(b'vadd.vv e32 m1', uart)
        self.assertIn(b'a=0xfffffff9 b=0x00000003 got=0xfffffffc exp=0xfffffffc PASS\r\n', uart)
        self.assertNotIn(b'FAIL', uart)
        self.assertTrue(uart.endswith(b' failed=0\r\n'))
        magic, cases, checks, failures = struct.unpack('<4I', summary)
        self.assertEqual(magic, 0x41524131)
        self.assertGreaterEqual(cases, 35)
        self.assertGreater(checks, cases)
        self.assertEqual(failures, 0)

    def test_injected_failure_changes_actual_not_reference(self):
        r = self.reference()
        uart, summary = r.expected(inject_failure=True)
        self.assertIn(b'got=0xfffffffd exp=0xfffffffc FAIL\r\n', uart)
        self.assertEqual(uart.count(b' FAIL\r\n'), 1)
        self.assertEqual(struct.unpack('<4I', summary)[3], 1)


if __name__ == '__main__':
    unittest.main()
