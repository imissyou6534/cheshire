#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check mask scalar boundary results against an independent full AXI oracle."""
import argparse
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
LENGTHS = (0,1,4,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512)


def expected():
    rows = []
    full = (1 << 512)-1
    alternating = int.from_bytes(bytes([0x55])*64, 'little')
    predicate = full ^ alternating
    for maximum in (512,128,64,32):
        for vl in LENGTHS:
            if vl > maximum:
                continue
            active = (1 << vl)-1
            patterns = (0, full, alternating, 1, (1 << vl) & full,
                        (full ^ active) | 5, (1 << (vl-1)) if vl else 0)
            for source in patterns:
                for execution in (full,full,0,predicate):
                    value = source & execution & active
                    rows.append((bin(value).count('1'), (value & -value).bit_length()-1 if value else -1))
    assert len(rows) <= 2048
    data = struct.pack('<4I', 0x4d534b31, len(rows), 0, 0)
    data += b''.join(struct.pack('<Ii', *row) for row in rows) + bytes((2048-len(rows))*8)
    uart = f'[MASK] scalar tail regression\r\n[MASK] cases={len(rows)} checks={len(rows)*2} failed=0\r\n'.encode()
    return data, uart, len(rows)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--profile', choices=['legacy','wide'], default='wide')
    p.add_argument('--boot', choices=['spm','rom'], default='spm')
    p.add_argument('--reuse-build', action='store_true')
    args = p.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    data, uart, count = expected()
    (out/'mask_expected.bin').write_bytes(data)
    (out/'uart_expected.bin').write_bytes(uart)
    print(f'Expect {count} mask cases, {count*2} scalar results', flush=True)
    command = [sys.executable, str(ROOT/'util/run_multitile_sim.py'), '--boot', args.boot,
               '--bus-profile', args.profile, '--app', 'sw/tests/ara_mask_scalar_tail.c',
               '--extra-source', 'sw/tests/ara_rom_selftest_fast_uart.c',
               '--uart-bit-period-ns', '320', '--require-ara',
               '--check-buffer', 'mask_scalar_report', str(out/'mask_expected.bin'),
               '--uart-expected', str(out/'uart_expected.bin'), '--timeout', '1800',
               '--sim-timeout-ns', '1000000000', '--out', str(out)]
    if args.reuse_build:
        command.append('--reuse-build')
    return subprocess.call(command, cwd=ROOT)


if __name__ == '__main__':
    raise SystemExit(main())
