#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify Ara self-test from embedded ROM, including exact UART and AXI readback."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from ara_rom_reference import expected

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, default=ROOT / 'target/ara_rom_selftest/sim')
    p.add_argument('--inject-failure', action='store_true', help='corrupt first stored result; require one firmware FAIL and return=1')
    p.add_argument('--wrong-uart', action='store_true', help='require rejection of a deliberately wrong host UART expectation')
    p.add_argument('--reuse-build', action='store_true')
    p.add_argument('--board-baud', action='store_true', help='simulate the default board baud (115200); considerably slower')
    p.add_argument('--timeout', type=int, default=7200, help='wall timeout per VCS tool/run')
    args = p.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    # A failed build must never turn old mismatch evidence into a passing negative.
    for name in ('run.log', 'result.json'):
        (out / name).unlink(missing_ok=True)
    uart, summary = expected(args.inject_failure)
    if args.wrong_uart:
        actual = b'got=0xfffffffd' if args.inject_failure else b'got=0xfffffffc'
        uart = uart.replace(actual, b'got=0xfffffffb', 1)
    uart_path, summary_path = out / 'uart_expected.bin', out / 'summary_expected.bin'
    uart_path.write_bytes(uart)
    summary_path.write_bytes(summary)
    command = [sys.executable, str(ROOT / 'util/run_multitile_sim.py'),
               '--boot', 'rom', '--bus-profile', 'wide', '--tiles', '1', '--dmas', '1',
               '--app', 'sw/tests/ara_rom_selftest.c', '--out', str(out),
               '--require-ara', '--uart-expected', str(uart_path),
               '--check-buffer', 'ara_test_summary', str(summary_path),
               '--expected-return', str(int(args.inject_failure)),
               '--sim-timeout-ns', '3000000000', '--timeout', str(args.timeout)]
    if args.inject_failure:
        command += ['--extra-source', 'sw/tests/ara_rom_selftest_negative.c']
    if not args.board_baud:
        command += ['--extra-source', 'sw/tests/ara_rom_selftest_fast_uart.c', '--uart-bit-period-ns', '320']
    if args.reuse_build:
        command.append('--reuse-build')
    status = subprocess.call(command, cwd=ROOT)
    if args.wrong_uart:
        log = (out / 'run.log').read_text(errors='replace') if (out / 'run.log').exists() else ''
        result_path = out / 'result.json'
        result = json.loads(result_path.read_text()) if result_path.is_file() else {}
        if status and result.get('hardware_unchanged') and 'UART mismatch tile=0' in log:
            print('PASS Ara ROM negative: independent UART checker rejected wrong actual-result expectation')
            return 0
        print('FAIL: UART negative did not fail for the intended mismatch', file=sys.stderr)
        return 1
    return status


if __name__ == '__main__':
    raise SystemExit(main())
