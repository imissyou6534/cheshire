#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify VCU118 board wiring using real JTAG/SBA and protected prepared sources."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

sys.dont_write_bytecode = True
from rom_bender import prepared_paths
from run_multitile_sim import hardware_state, run_timed

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--timeout', type=int, default=1800)
    parser.add_argument('--reuse-build', action='store_true', help='run existing simulator binaries only')
    args = parser.parse_args()
    out = (args.out or ROOT / 'target/sim/build/wide_bus/board' /
           datetime.now().strftime('%Y%m%d-%H%M%S')).resolve()
    out.mkdir(parents=True, exist_ok=True)
    import fcntl
    lock = (out / 'runner.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    before = hardware_state()
    build_inputs = dict(hardware=before, sources={str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in [Path(__file__), ROOT / 'target/sim/src/tb_xilinx_multitile.sv',
                                     ROOT / 'target/sim/src/xilinx_multitile_test_models.sv',
                                     ROOT / 'target/sim/src/elfloader.cpp', ROOT / 'sw/tests/vector_helloworld.c',
                                     ROOT / 'sw/link/ara_hello_spm.ld']})
    report = dict(status='failed', hardware=before, widths=dict(debug=64, tile=128,
                  dma=128, shared=256, mig=512, ara_lanes=4), runs={})
    try:
        paths = prepared_paths()
        plic = (paths['opentitan_peripherals'] / 'src/rv_plic/rtl/rv_plic_reg_pkg.sv').read_text()
        if not re.search(r'parameter\s+int\s+NumSrc\s*=\s*64\s*;', plic):
            raise ValueError('prepared PLIC needs 64 sources; dependency regeneration is disabled')
        with (out / 'build.log').open('a' if args.reuse_build else 'w') as log:
            def command(argv, capture=False, cwd=ROOT):
                argv = [str(value) for value in argv]
                log.write(shlex.join(argv) + '\n')
                log.flush()
                result = run_timed(argv, cwd=str(cwd), timeout=args.timeout, check=True,
                                   stdout=subprocess.PIPE if capture else log, stderr=log, text=True)
                return result.stdout if capture else None

            cc = os.environ.get('RISCV_CC', 'riscv64-unknown-elf-gcc')
            compiled = out / 'compile.json'
            if args.reuse_build:
                if not compiled.is_file() or json.loads(compiled.read_text()) != build_inputs:
                    raise ValueError('reuse requires matching compiled hardware, firmware, and testbench sources')
            if not args.reuse_build:
                # This standalone SPM image deliberately has no embedded ROM segment.
                command([cc, '-march=rv64gcv_zifencei', '-mabi=lp64d', '-mcmodel=medany', '-O2', '-g',
                         '-ffreestanding', '-fno-builtin', '-fno-common', '-ffunction-sections', '-fdata-sections',
                         '-nostdlib', '-nostartfiles', '-Isw/include', '-Isw/deps/printf',
                         '-I' + str(paths['ara'] / 'cheshire/sw/include'), '-Wl,-Lsw/link',
                         '-Wl,--no-relax', '-Wl,--gc-sections', '-Tsw/link/ara_hello_spm.ld',
                         'sw/lib/crt0.S', 'sw/tests/vector_helloworld.c', 'sw/lib/dif/clint.c',
                         'sw/lib/dif/uart.c', 'sw/deps/printf/printf.c', '-o', out / 'hello.elf'])
                sources = command([sys.executable, ROOT / 'util/rom_bender.py', 'script', 'vcs',
                                   '--no-default-target', '-t', 'rtl', '-t', 'simulation', '-t', 'test',
                                   '-t', 'cva6', '-t', 'cv64a6_imafdcv_sv39', '-t', 'exclude_first_pass_decoder',
                                   '-D', 'VCS', '-D', 'SYNTHESIS', '--define',
                                   r'CHESHIRE_FFT_COEFF_ROOT=\"' + str(ROOT / 'hw/fft/rtl') + r'\"',
                                   '--vlogan-args=-full64 -timescale=1ns/1ps -assert svaext'], capture=True)
                (out / 'compile_deps.sh').write_text(sources)
                command(['bash', out / 'compile_deps.sh'], cwd=out)
                command(['vlogan', '-full64', '-sverilog', '-timescale=1ns/1ps', '-assert', 'svaext',
                         '+define+VCS+SYNTHESIS+TARGET_VCU118+ARA+FFT_ACCEL+NR_LANES=4+VLEN=2048',
                         '+define+CHESHIRE_FFT_COEFF_ROOT="' + str(ROOT / 'hw/fft/rtl') + '"',
                         '+incdir+' + str(paths['axi'] / 'include'),
                         '+incdir+' + str(paths['register_interface'] / 'include'),
                         '+incdir+' + str(paths['common_cells'] / 'include'),
                         '+incdir+' + str(ROOT / 'hw/include'), '+incdir+' + str(ROOT / 'target/xilinx/src'),
                         ROOT / 'target/sim/src/xilinx_multitile_test_models.sv',
                         ROOT / 'target/xilinx/src/dram_wrapper_xilinx.sv',
                         ROOT / 'target/xilinx/src/multi_tile_top_xilinx.sv',
                         ROOT / 'target/sim/src/tb_xilinx_multitile.sv'], cwd=out)
                for name, tiles, dmas in [('simv', 1, 1), ('simv_links', 2, 2)]:
                    command(['vcs', '-full64', '-timescale=1ns/1ps', '-assert', 'svaext',
                             '-top', 'tb_xilinx_multitile',
                             '-pvalue+tb_xilinx_multitile.NumTiles=' + str(tiles),
                             '-pvalue+tb_xilinx_multitile.NumDmas=' + str(dmas),
                             ROOT / 'target/sim/src/elfloader.cpp', '-o', out / name], cwd=out)
                compiled.write_text(json.dumps(build_inputs, indent=2) + '\n')
            symbols = command([cc.removesuffix('gcc') + 'nm', '--defined-only', out / 'hello.elf'], capture=True)
            addresses = {parts[2]: int(parts[0], 16) for line in symbols.splitlines()
                         if len(parts := line.split()) == 3}
            if addresses.get('_start') != 0x10000000 or not 0x10000000 <= addresses['buf'] < 0x10020000:
                raise ValueError('standalone firmware entry and vector buffer must be in private SPM')
            report['symbols'] = dict(entry=addresses['_start'], buf=addresses['buf'])
            for name, plusargs, marker in [
                ('simv', ['+BINARY=' + str(out / 'hello.elf'), '+BUF={:x}'.format(addresses['buf'])],
                 'PASS Xilinx multi-tile board smoke 1 tile x 1 DMA'),
                ('simv_links', ['+LINKS_ONLY'], 'PASS Xilinx multi-tile JTAG/UART links 2 tiles x 2 DMA')]:
                run_log = out / ('run.log' if name == 'simv' else 'run_links.log')
                with run_log.open('w') as output:
                    result = run_timed([str(out / name), *plusargs], cwd=str(out),
                                       stdout=output, stderr=subprocess.STDOUT, timeout=args.timeout)
                text = run_log.read_text(errors='replace')
                if result.returncode or re.search(r'Fatal:|Error:|Error-\[|Cannot open file', text):
                    raise ValueError('{} simulation failed; inspect {}'.format(name, run_log))
                required = [marker]
                if name == 'simv':
                    required += ['PASS FPGA UART passive ACK', '[JTAG] Halted hart 0', '[JTAG] Preload complete',
                                 '[JTAG] SUCCESS', 'widths Debug64 Tile128 DMA128 Shared256 MIG512 Ara4']
                if any(item not in text for item in required):
                    raise ValueError('{} missing verification marker'.format(name))
                report['runs'][name] = dict(status='passed', log=str(run_log))
                print('\n'.join(line for line in text.splitlines() if line.startswith(('FPGA ', 'PASS ', '[JTAG]'))))
        after = hardware_state()
        report['hardware_unchanged'] = before == after
        if before != after:
            raise ValueError('production RTL or prepared dependencies changed during smoke verification')
        report['status'] = 'passed'
        print('PASS protected wide board smoke; report=' + str(out / 'report.json'))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report['error'] = str(error)
        print('FAIL wide board smoke: ' + str(error), file=sys.stderr)
        return 1
    finally:
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    raise SystemExit(main())
