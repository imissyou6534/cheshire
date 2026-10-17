"""Numerical and DDR dump acceptance tests, independent of the DUT implementation."""
import csv
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

try:
    import numpy as np
except ImportError:
    np = None

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipIf(np is None, 'NumPy is required for FFT reference checks')
class FftDdrTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('fft_ddr', ROOT / 'util/run_fft_ddr_test.py')
        cls.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.mod)

    def test_inputs_are_quantized_and_reproducible(self):
        first = self.mod.make_inputs(2026, 0)
        again = self.mod.make_inputs(2026, 0)
        other = self.mod.make_inputs(2026, 1)
        self.assertEqual(list(first), ['cosine', 'sine', 'random_real'])
        for name, values in first.items():
            self.assertEqual(values.dtype, np.dtype('<i2'))
            self.assertEqual(values.shape, (4096,))
            np.testing.assert_array_equal(values, again[name])
        self.assertFalse(np.array_equal(first['random_real'], other['random_real']))

    def test_reference_impulse_and_fixed_scale(self):
        values = np.zeros(4096, dtype=np.int16)
        values[0] = 32000
        np.testing.assert_allclose(self.mod.reference(values, 'fft'), 1000)
        np.testing.assert_allclose(self.mod.reference(values, 'ifft'), 1000)

    def test_exact_and_known_error_db(self):
        values = np.zeros(4096, dtype=np.int16)
        values[0] = 32000
        ideal = self.mod.reference(values, 'fft')
        good = self.mod.evaluate(values, ideal, 'fft', 40, 128)
        self.assertTrue(good['pass'])
        self.assertEqual(good['max_abs_error'], 0)
        noisy = self.mod.evaluate(values, ideal + 10, 'fft', 40, 128)
        self.assertAlmostEqual(noisy['snr_db'], 40)
        self.assertAlmostEqual(noisy['relative_rms_error_db'], -40)
        self.assertAlmostEqual(noisy['relative_error_percent'], 1)

    def test_wrong_gain_is_not_fitted_away(self):
        values = self.mod.make_inputs(2026, 0)['cosine']
        result = self.mod.evaluate(values, 2 * self.mod.reference(values, 'fft'), 'fft', 40, 128)
        self.assertFalse(result['pass'])
        self.assertAlmostEqual(result['snr_db'], 0)
        self.assertAlmostEqual(result['gain_fit_diagnostic'], 2)

    def test_wrong_order_or_sign_is_rejected(self):
        values = self.mod.make_inputs(2026, 0)['random_real']
        ideal = self.mod.reference(values, 'fft')
        for wrong in (ideal[::-1], ideal.conjugate()):
            self.assertFalse(self.mod.evaluate(values, wrong, 'fft', 40, 128)['pass'])

    def dump(self, path, rows):
        with path.open('w', newline='') as stream:
            writer = csv.writer(stream)
            writer.writerow(['index', 'address', 'word'])
            writer.writerows(rows)

    def test_dump_sign_unpacking_and_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'output.csv'
            rows = [(i, hex(0x80004000 + 8*i), '0xfffffffe00000003') for i in range(4096)]
            self.dump(path, rows)
            actual = self.mod.read_dump(path, 0x80004000)
            np.testing.assert_array_equal(actual, 3 - 2j)

    def test_partial_duplicate_wrong_address_unknown_or_noncanonical_dump_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'output.csv'
            rows = [(i, hex(0x80004000 + 8*i), '0x0000000000000000') for i in range(4096)]
            bad_sets = [rows[:-1], [rows[0]] + rows[:-1],
                        [(0, '0x80004008', rows[0][2])] + rows[1:],
                        [(0, rows[0][1], '0x00000000xxxxxxxx')] + rows[1:],
                        [(0, rows[0][1], '0x0000000000800000')] + rows[1:]]
            for bad in bad_sets:
                with self.subTest(first=bad[0], count=len(bad)):
                    self.dump(path, bad)
                    with self.assertRaises(ValueError):
                        self.mod.read_dump(path, 0x80004000)


if __name__ == '__main__':
    unittest.main()
