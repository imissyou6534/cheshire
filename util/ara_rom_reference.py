#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Independent deterministic UART and summary oracle for ara_rom_selftest.c."""
import struct

A = (0xfffffff9, 0x80000000, 0x7fffffff, 0)
B = (3, 0xffffffff, 2, 0)
OPS = ('vadd', 'vsub', 'vmul', 'vdiv', 'vdivu', 'vrem', 'vremu',
       'vand', 'vor', 'vxor', 'vsll', 'vsrl', 'vsra', 'vmin', 'vmax',
       'vminu', 'vmaxu')


def signed(x):
    return x - (1 << 32) if x & (1 << 31) else x


def integer(op, a, b):
    a, b = a & 0xffffffff, b & 0xffffffff
    x, y = signed(a), signed(b)
    if op in ('vdiv', 'vrem'):
        q = -1 if not y else (abs(x) // abs(y)) * (-1 if (x < 0) != (y < 0) else 1)
        result = q if op == 'vdiv' else x if not y else x - q * y
    else:
        result = {
            'vadd': lambda: a + b, 'vsub': lambda: a - b, 'vmul': lambda: a * b,
            'vdivu': lambda: a // b if b else 0xffffffff,
            'vremu': lambda: a % b if b else a,
            'vand': lambda: a & b, 'vor': lambda: a | b, 'vxor': lambda: a ^ b,
            'vsll': lambda: a << (b & 31), 'vsrl': lambda: a >> (b & 31),
            'vsra': lambda: x >> (b & 31), 'vmin': lambda: min(x, y),
            'vmax': lambda: max(x, y), 'vminu': lambda: min(a, b),
            'vmaxu': lambda: max(a, b),
        }[op]()
    return result & 0xffffffff


def fp_bits(value, bits):
    return int.from_bytes(struct.pack('<f' if bits == 32 else '<d', value), 'little')


def expected(inject_failure=False):
    lines = ['[ARA] ROM selftest v1\r\n']
    cases, checks = 0, 0

    def start(name, bits=32, lmul=1):
        nonlocal cases
        cases += 1
        lines.append(f'[ARA] START {name} e{bits} m{lmul}\r\n')

    def row(i, a, b, got, bits=32, show=True, corrupt=False):
        nonlocal checks
        checks += 1
        if show:
            w = bits // 4
            mask = (1 << bits) - 1
            lines.append(f'[ARA] i={i} a=0x{a & mask:0{w}x} b=0x{b & mask:0{w}x} '
                         f'got=0x{(got ^ int(corrupt)) & mask:0{w}x} exp=0x{got & mask:0{w}x} '
                         f'{"FAIL" if corrupt else "PASS"}\r\n')

    for op in OPS:
        start(op + '.vv')
        for i, (a, b) in enumerate(zip(A, B)):
            row(i, a, b, integer(op, a, b), corrupt=inject_failure and op == 'vadd' and i == 0)
        if inject_failure:
            lines.append('[ARA] SUMMARY cases=1 checks=4 failed=1\r\n')
            return ''.join(lines).encode('ascii'), struct.pack('<4I', 0x41524131, 1, 4, 1)

    for name, result in (
        ('vadd.vx', [(a + 5) & 0xffffffff for a in A]),
        ('vadd.vi', [(a - 3) & 0xffffffff for a in A]),
        ('vmacc.vv', [(a * b + 11) & 0xffffffff for a, b in zip(A, B)]),
        ('vmslt+vmerge', [a if signed(a) < signed(b) else b for a, b in zip(A, B)]),
        ('vadd.masked', [(a + b) & 0xffffffff if i % 2 == 0 else 0x55 for i, (a, b) in enumerate(zip(A, B))]),
        ('vslideup.vi', [0x55, *A[:3]]),
        ('vslidedown.vi', [A[1], A[2], A[3], 0x55]),
        ('vrgather.vv', list(reversed(A))),
        ('vid.v', list(range(4))),
        ('vmv.v.x', [9] * 4),
    ):
        start(name)
        if name == 'vmacc.vv':
            lines.append('[ARA] accumulator=11\r\n')
        if name == 'vadd.masked':
            lines.append('[ARA] mask=0x5 inactive=0x55\r\n')
        if name == 'vslideup.vi':
            lines.append('[ARA] old_destination=0x55\r\n')
        for i, (a, b, value) in enumerate(zip(A, B, result)):
            if name == 'vadd.vx': b = 5
            if name == 'vadd.vi': b = 0xfffffffd
            if name in ('vslideup.vi', 'vslidedown.vi'): b = 1
            if name == 'vrgather.vv': b = 3-i
            if name == 'vid.v': a = b = 0
            if name == 'vmv.v.x': a, b = 9, 0
            row(i, a, b, value)

    start('vredsum+vmv.x.s')
    lines.append('[ARA] input=0xfffffff9,0x80000000,0x7fffffff,0x00000000 initial=11\r\n')
    row(0, A[0], 11, (sum(A) + 11) & 0xffffffff)
    start('vcpop+vfirst')
    row(0, 5, 0, 2)
    row(1, 5, 0, 0)
    start('tail-undisturbed')
    for i in range(4):
        row(i, A[i], B[i], (A[i] + B[i]) & 0xffffffff if i < 3 else 0x55)
    start('vl-zero')
    for i in range(4):
        row(i, A[i], B[i], 0x55)

    for bits in (8, 16, 32, 64):
        start('load-store', bits)
        for i, value in enumerate((0, 1, (1 << (bits - 1)), (1 << bits) - 1)):
            row(i, value, 0, value, bits)

    for name, values in (
        ('vlse32+vsse32', [21, 22, 23, 24]),
        ('vluxei32+vsuxei32', [24, 21, 23, 22]),
    ):
        start(name)
        for i, value in enumerate(values):
            row(i, value, i * 8, value)

    start('stripmine-add', lmul=2)
    for i in range(145):
        row(i, i * 3 + 1, 7, i * 3 + 8, show=i < 4)
    lines.append('[ARA] checked=145 guards=PASS\r\n')

    for bits in (32, 64):
        for op in ('vfadd', 'vfsub', 'vfmul', 'vfdiv', 'vfmacc'):
            start(op + '.vv', bits)
            if op == 'vfmacc':
                lines.append('[ARA] accumulator=1.00\r\n')
            for i, (a, b) in enumerate(zip((1.5, -2.0, 4.0, 0.0), (0.5, 2.0, -2.0, 4.0))):
                value = {'vfadd': a+b, 'vfsub': a-b, 'vfmul': a*b,
                         'vfdiv': a/b, 'vfmacc': a*b+1.0}[op]
                # RNE cancellation produces +0 for the chosen inputs.
                w = bits // 4
                lines.append(f'[ARA] i={i} a={a:.2f} b={b:.2f} '
                             f'got={value:.2f} exp={value:.2f} '
                             f'got_bits=0x{fp_bits(value,bits):0{w}x} '
                             f'exp_bits=0x{fp_bits(value,bits):0{w}x} PASS\r\n')
                checks += 1

    failures = int(inject_failure)
    lines.append(f'[ARA] SUMMARY cases={cases} checks={checks} failed={failures}\r\n')
    return ''.join(lines).encode('ascii'), struct.pack('<4I', 0x41524131, cases, checks, failures)


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('out', type=Path)
    args = p.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    uart, summary = expected()
    (args.out / 'uart_expected.bin').write_bytes(uart)
    (args.out / 'summary_expected.bin').write_bytes(summary)
    print(f'{len(uart)} UART bytes; summary={struct.unpack("<4I", summary)}')
