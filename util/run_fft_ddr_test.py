#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Compare multi-tile FFT DDR readbacks against NumPy's floating-point FFT."""
import argparse
import csv
import hashlib
import json
import math
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
N = 4096
SCALE = 1 / 32
DDR_BASE = 0x80000000
TILE_STRIDE = 0x100000
JOB_STRIDE = 0x10000
OUTPUT_OFFSET = 0x4000
CASE_NAMES = ('cosine', 'sine', 'random_real')


def make_inputs(seed, tile):
    samples = np.arange(N)
    rng = np.random.default_rng(seed + tile)
    return dict(cosine=np.asarray(np.rint(8192 * np.cos(2*np.pi*7*samples/N)), dtype='<i2'),
                sine=np.asarray(np.rint(8192 * np.sin(2*np.pi*123*samples/N)), dtype='<i2'),
                random_real=rng.integers(-12000, 12001, size=N, dtype=np.int16).astype('<i2'))


def reference(samples, mode):
    values = np.asarray(samples, dtype=np.float64)
    if mode == 'fft':
        return np.fft.fft(values) * SCALE
    if mode == 'ifft':
        return np.fft.ifft(values) * (N * SCALE)
    raise ValueError('unknown FFT direction: ' + mode)


def evaluate(samples, actual, mode, min_snr_db, max_abs_error):
    expected = reference(samples, mode)
    actual = np.asarray(actual, dtype=np.complex128)
    if actual.shape != (N,) or not np.isfinite(actual).all():
        raise ValueError('expected exactly 4096 finite complex output values')
    error = actual - expected
    signal = float(np.vdot(expected, expected).real)
    noise = float(np.vdot(error, error).real)
    snr = math.inf if noise == 0 else (-math.inf if signal == 0 else 10*math.log10(signal/noise))
    absolute = np.abs(error)
    gain = float(np.vdot(expected, actual).real / signal) if signal else None
    result = dict(snr_db=snr, relative_rms_error_db=-snr,
                  relative_error_percent=100*math.sqrt(noise/signal) if signal else None,
                  rmse=math.sqrt(noise/N), reference_rms=math.sqrt(signal/N),
                  max_abs_error=float(absolute.max()), mean_abs_error=float(absolute.mean()),
                  max_real_abs_error=float(np.abs(error.real).max()),
                  max_imag_abs_error=float(np.abs(error.imag).max()),
                  worst_bin=int(absolute.argmax()), gain_fit_diagnostic=gain,
                  expected_scale=SCALE, min_snr_db=min_snr_db, max_abs_error_limit=max_abs_error)
    result['pass'] = result['max_abs_error'] <= max_abs_error and snr >= min_snr_db
    return result


def read_dump(path, address):
    with Path(path).open() as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ['index', 'address', 'word']:
            raise ValueError('invalid DDR dump header: ' + str(path))
        rows = list(reader)
    if len(rows) != N:
        raise ValueError('incomplete DDR dump: ' + str(path))
    result = np.empty(N, dtype=np.complex128)
    for index, row in enumerate(rows):
        if int(row['index']) != index or int(row['address'], 0) != address + 8*index:
            raise ValueError('DDR dump index/address mismatch: ' + str(path))
        word = int(row['word'], 0)
        if not 0 <= word < 1 << 64:
            raise ValueError('DDR dump word outside 64 bits')
        parts = []
        for shift in (0, 32):
            value = (word >> shift) & 0xffffffff
            if value & 0x80000000:
                value -= 1 << 32
            if not -(1 << 22) <= value < 1 << 22:
                raise ValueError('FFT output is not a sign-extended 23-bit integer')
            parts.append(value)
        result[index] = complex(*parts)
    return result


def serializable(value):
    if isinstance(value, dict):
        return {key: serializable(item) for key, item in value.items()}
    if isinstance(value, list):
        return [serializable(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        return str(value)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tiles', type=int, default=2)
    parser.add_argument('--dmas', type=int, default=2)
    parser.add_argument('--mode', choices=['fft', 'ifft'], default='fft')
    parser.add_argument('--seed', type=int, default=2026)
    parser.add_argument('--min-snr-db', type=float, default=40)
    parser.add_argument('--max-abs-error', type=float, default=128)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--sim-timeout-ns', type=int, default=200000000)
    parser.add_argument('--build-python', default='python3', help='Python with PyYAML and pyelftools for the build runner')
    parser.add_argument('--reuse-build', action='store_true')
    parser.add_argument('--out', type=Path, default=ROOT / 'target/sim/build/fft_ddr')
    args = parser.parse_args()
    if not (1 <= args.tiles <= 64 and 1 <= args.dmas <= 65536 and args.seed >= 0 and
            args.timeout > 0 and args.sim_timeout_ns > 0 and
            math.isfinite(args.min_snr_db) and math.isfinite(args.max_abs_error) and args.max_abs_error >= 0):
        parser.error('invalid counts, seed, timeout or error limits')
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    import fcntl
    from run_multitile_sim import run_timed
    with (out / 'runner.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        arrays = out / args.mode
        arrays.mkdir(exist_ok=True)
        summary_file = arrays / 'summary.json'
        summary = dict(status='failed', mode=args.mode, tiles=args.tiles, dmas=args.dmas,
                       n=N, scale=SCALE, numpy_version=np.__version__, seed=args.seed,
                       reference='NumPy FFT of the exact quantized int16 input; fixed scale 1/32; natural order',
                       results=[])
        try:
            # Old dumps cannot be accepted as outputs of a new simulator invocation.
            for pattern in ('tile*.job*.csv', 'tile*.comparison.csv', 'tile*.npz',
                            'summary.csv', 'sim_result.json', 'simulation.log'):
                for path in arrays.glob(pattern):
                    path.unlink()
            inputs = [make_inputs(args.seed, tile) for tile in range(args.tiles)]
            summary['input_sha256'] = {}
            for tile, cases in enumerate(inputs):
                data = b''.join(values.tobytes() for values in cases.values())
                (arrays / f'tile{tile}.input.bin').write_bytes(data)
                summary['input_sha256'][str(tile)] = hashlib.sha256(data).hexdigest()
            sim = out / 'sim'
            (sim / 'run.log').unlink(missing_ok=True)
            command = [args.build_python, str(ROOT / 'util/run_multitile_sim.py'),
                       '--boot', 'spm', '--testbench', 'fft-ddr', '--tiles', str(args.tiles),
                       '--dmas', str(args.dmas), '--app', 'target/sim/sw/fft_ddr.c',
                       '--app-march', 'rv64gc_zifencei', '--require-fft', '--out', str(sim),
                       '--timeout', str(args.timeout), '--sim-timeout-ns', str(args.sim_timeout_ns),
                       '--sim-arg=+FFT_DDR_DIR=' + str(arrays),
                       '--sim-arg=+FFT_INVERSE=' + str(int(args.mode == 'ifft'))]
            if args.reuse_build:
                command.append('--reuse-build')
            summary['command'] = command
            completed = run_timed(command, cwd=ROOT, timeout=args.timeout*4)
            if (sim / 'result.json').exists():
                shutil.copyfile(sim / 'result.json', arrays / 'sim_result.json')
            if (sim / 'run.log').exists():
                shutil.copyfile(sim / 'run.log', arrays / 'simulation.log')
            if completed.returncode:
                raise ValueError('FFT system simulation failed; inspect ' + str(sim / 'result.json'))
            sim_report = json.loads((sim / 'result.json').read_text())
            if sim_report['status'] != 'passed' or not sim_report['hardware_unchanged']:
                raise ValueError('FFT simulator report did not pass hardware/return checks')
            summary['hardware_unchanged'] = True
            for tile, cases in enumerate(inputs):
                for job, (name, values) in enumerate(cases.items()):
                    address = DDR_BASE + tile*TILE_STRIDE + job*JOB_STRIDE + OUTPUT_OFFSET
                    path = arrays / f'tile{tile}.job{job}.csv'
                    actual = read_dump(path, address)
                    result = dict(tile=tile, case=name, mode=args.mode, address=hex(address),
                                  output_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                                  **evaluate(values, actual, args.mode, args.min_snr_db, args.max_abs_error))
                    summary['results'].append(result)
                    expected = reference(values, args.mode)
                    np.savez(arrays / f'tile{tile}.{name}.npz', input=values, actual=actual,
                             reference=expected, error=actual-expected)
                    np.savetxt(arrays / f'tile{tile}.{name}.comparison.csv',
                               np.column_stack((np.arange(N), actual.real, actual.imag,
                                                expected.real, expected.imag, np.abs(actual-expected))),
                               delimiter=',', header='bin,dut_real,dut_imag,ref_real,ref_imag,abs_error', comments='')
                    print('{} tile={} {}: SNR={:.2f} dB, relative_error={:.2f} dB, '
                          'RMSE={:.4f}, max={:.4f}'.format(
                              'PASS' if result['pass'] else 'FAIL', tile, name, result['snr_db'],
                              result['relative_rms_error_db'], result['rmse'], result['max_abs_error']), flush=True)
            summary['status'] = 'passed' if all(row['pass'] for row in summary['results']) else 'failed'
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            summary['reason'] = str(error)
            print(str(error), file=sys.stderr)
        finally:
            summary_file.write_text(json.dumps(serializable(summary), indent=2, allow_nan=False) + '\n')
            if summary['results']:
                with (arrays / 'summary.csv').open('w', newline='') as stream:
                    writer = csv.DictWriter(stream, fieldnames=list(summary['results'][0]))
                    writer.writeheader()
                    writer.writerows(summary['results'])
            print('FFT accuracy: {} ({})'.format(summary['status'], summary_file), flush=True)
        return 0 if summary['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
