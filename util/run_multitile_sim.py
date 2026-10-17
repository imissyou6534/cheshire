#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run one multi-tile VCS environment with ROM or external-SPM program loading."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def validate_result(status, log, rows, tiles, expected_return):
    if status != 0:
        return 'simulator exited with status {}'.format(status)
    if re.search(r'Fatal:|Error:|Error-\[|FAIL MULTITILE|Cannot open file|could not be opened', log):
        return 'simulator reported an error'
    if not re.search(r'^PASS MULTITILE(?:\s|$)', log, re.MULTILINE):
        return 'testbench PASS marker missing'
    if len(rows) != tiles or {row.get('tile') for row in rows} != set(range(tiles)):
        return 'missing, duplicate or invalid tile results'
    if any(not row.get('raw', 0) & 1 or row['raw'] >> 1 != expected_return for row in rows):
        return 'application return result mismatch'
    return None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run_timed(argv, timeout, cwd=None, stdout=None, stderr=None, text=False, check=False):
    process = subprocess.Popen(argv, cwd=cwd, stdout=stdout, stderr=stderr,
                               text=text, start_new_session=True)
    try:
        output, errors = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        for action in [signal.SIGTERM, signal.SIGKILL]:
            try:
                os.killpg(process.pid, action)
            except ProcessLookupError:
                pass
            if action == signal.SIGTERM:
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
        process.communicate()
        raise subprocess.TimeoutExpired(argv, timeout)
    result = subprocess.CompletedProcess(argv, process.returncode, output, errors)
    if check:
        result.check_returncode()
    return result


def hardware_state():
    from rom_bender import prepared_paths
    paths = prepared_paths()
    heads = {name: subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
             for name, path in paths.items()}
    hasher = hashlib.sha256()
    for directory in [ROOT / 'hw', ROOT / 'target/xilinx/src', *paths.values()]:
        for path in sorted(directory.rglob('*')):
            if path.is_file() and (path.suffix in {'.sv', '.svh', '.v', '.vh', '.hex', '.mem', '.hjson'}
                                   or path.name == 'Bender.yml'):
                hasher.update(str(path.relative_to(ROOT)).encode())
                hasher.update(path.read_bytes())
    for path in [ROOT / 'Bender.yml', ROOT / 'Bender.lock']:
        hasher.update(path.read_bytes())
    return dict(heads=heads, rtl_sha256=hasher.hexdigest())


def run(args):
    from rom_bender import prepared_paths
    paths = prepared_paths()
    out = args.out.resolve() if args.out else ROOT / 'target/sim/build/multitile' / args.boot / '{}x{}'.format(args.tiles, args.dmas)
    out.mkdir(parents=True, exist_ok=True)
    import fcntl
    lock = (out / 'runner.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    baseline = hardware_state()
    report = dict(status='failed', boot=args.boot, tiles=args.tiles, dmas=args.dmas,
                  expected_return=args.expected_return, hardware=baseline)
    result_csv = out / 'result.csv'
    result_csv.unlink(missing_ok=True)
    try:
        with (out / 'build.log').open('w') as build_log:
            def command(argv, cwd=ROOT, capture=False):
                build_log.write(shlex.join([str(v) for v in argv]) + '\n')
                build_log.flush()
                result = run_timed(argv, cwd=str(cwd), stdout=subprocess.PIPE if capture else build_log,
                                   stderr=build_log, text=True, timeout=args.timeout, check=True)
                return result.stdout if capture else None

            plic = (paths['opentitan_peripherals'] / 'src/rv_plic/rtl/rv_plic_reg_pkg.sv').read_text()
            if not re.search(r'parameter\s+int\s+NumSrc\s*=\s*64\s*;', plic):
                raise ValueError('prepared PLIC must have 64 sources; this runner does not regenerate dependencies')
            firmware = out / 'firmware'
            argv = [sys.executable, str(ROOT / 'util/build_rom_firmware.py'), '--out', str(firmware),
                    '--app', args.app or 'sw/tests/vector_helloworld.c', '--app-march', args.app_march]
            for source in args.extra_source:
                argv += ['--extra-source', source]
            command(argv)
            manifest = json.loads((firmware / 'payload.json').read_text())
            report.update(application_sha256=sha((firmware / 'application.bin').read_bytes()),
                          rom_sha256=manifest['rom_sha256'], firmware_sha256=manifest['firmware_sha256'])
            tb_name = 'tb_fft_ddr' if args.testbench == 'fft-ddr' else 'tb_multitile'
            tb_target = 'fft_ddr_test' if args.testbench == 'fft-ddr' else 'multitile_system_test'
            tb_files = [ROOT / 'target/sim/src/vip_multitile.sv', ROOT / ('target/sim/src/' + tb_name + '.sv')]
            compile_config = dict(boot=args.boot, tiles=args.tiles, dmas=args.dmas, hardware=baseline, top=tb_name,
                                  testbench={str(path): sha(path.read_bytes()) for path in tb_files},
                                  scripts={str(path): sha(path.read_bytes()) for path in
                                           [Path(__file__), ROOT / 'util/rom_bender.py']},
                                  tools={tool: dict(path=shutil.which(tool),
                                                    mtime=Path(shutil.which(tool)).stat().st_mtime_ns)
                                         for tool in ['vcs', 'vlogan']})
            if args.boot == 'rom':
                compile_config['rom_sha256'] = manifest['rom_sha256']
            signature = sha(json.dumps(compile_config, sort_keys=True).encode())
            cached = out / 'compile.json'
            simv = out / 'simv'
            if args.reuse_build:
                if not cached.is_file() or not simv.is_file() or json.loads(cached.read_text()).get('signature') != signature:
                    raise ValueError('no matching compiled simulation; rerun without --reuse-build')
            else:
                argv = [sys.executable, str(ROOT / 'util/rom_bender.py'), 'script', 'vcs',
                        '--no-default-target', '-t', 'rtl', '-t', 'simulation', '-t', 'test', '-t', 'cva6',
                        '-t', tb_target,
                        '-t', 'cv64a6_imafdcv_sv39', '-t', 'exclude_first_pass_decoder', '-D', 'VCS', '-D', 'SYNTHESIS',
                        '--define', r'CHESHIRE_FFT_COEFF_ROOT=\"' + str(ROOT / 'hw/fft/rtl') + r'\"',
                        '--vlogan-args=-full64 -timescale=1ns/1ps -assert svaext']
                if args.boot == 'rom':
                    argv += ['-t', 'rom_autoboot']
                sources = command(argv, capture=True)
                if args.boot == 'rom':
                    mutable = str(ROOT / 'target/rom_autoboot/cheshire_bootrom.sv')
                    if sources.count(mutable) != 1:
                        raise ValueError('generated source list must contain exactly one ROM source')
                    sources = sources.replace(mutable, manifest['rom_snapshot'])
                script = out / 'compile_deps.sh'
                script.write_text(sources)
                command(['bash', str(script)], cwd=out)
                command(['vcs', '-full64', '-timescale=1ns/1ps', '-assert', 'svaext', '-top', tb_name,
                         '-pvalue+' + tb_name + '.NumTiles=' + str(args.tiles),
                         '-pvalue+' + tb_name + '.NumDmas=' + str(args.dmas),
                         '-pvalue+' + tb_name + '.RomEmbedded=' + str(int(args.boot == 'rom')),
                         '-o', str(simv)], cwd=out)
                cached.write_text(json.dumps(dict(signature=signature, config=compile_config), indent=2) + '\n')
            if args.build_only:
                report['status'] = 'built'
                return 0

            argv = [str(simv), '+RESULT=' + str(result_csv), '+EXPECTED_RETURN=' + str(args.expected_return),
                    '+TIMEOUT_NS=' + str(args.sim_timeout_ns), '+UART_ALL=' + str(int(args.uart_tiles == 'all')),
                    '+ALLOW_TRAPS=' + str(int(args.allow_traps))]
            is_hello = args.app is None
            if args.require_ara or is_hello:
                argv.append('+REQUIRE_ARA=1')
            if args.require_fft:
                argv.append('+REQUIRE_FFT=1')
            uart_expected = args.uart_expected.resolve() if args.uart_expected else None
            if is_hello and uart_expected is None:
                uart_expected = out / 'uart_expected.bin'
                uart_expected.write_bytes(b'Hello Vector World!\r\n')
            if uart_expected:
                argv += ['+UART_EXPECTED=' + str(uart_expected)]
            check = args.check_buffer
            if is_hello and check is None:
                expected = out / 'buffer_expected.bin'
                expected.write_bytes(b'Hello Vector World!\r\n' + bytes(43))
                check = ['buf', str(expected)]
            if check:
                symbol, filename = check
                if symbol not in manifest['symbols']:
                    raise ValueError('memory checker symbol missing: ' + symbol)
                argv += ['+CHECK_ADDR={:x}'.format(manifest['symbols'][symbol]),
                         '+CHECK_FILE=' + str(Path(filename).resolve())]
            if args.boot == 'spm':
                segment = manifest['segments'][0]
                argv += ['+APP_BIN=' + str(firmware / 'application.bin'),
                         '+APP_ADDR={:x}'.format(segment['load_addr']),
                         '+APP_ENTRY={:x}'.format(manifest['entry']), '+APP_MEM_SIZE=' + str(segment['mem_size'])]
            argv += args.sim_arg
            report['command'] = argv
            with (out / 'run.log').open('w') as log:
                try:
                    completed = run_timed(argv, cwd=str(out), stdout=log, stderr=subprocess.STDOUT,
                                          timeout=args.timeout)
                    status = completed.returncode
                except subprocess.TimeoutExpired:
                    status = 124
            text = (out / 'run.log').read_text(errors='replace')
            rows = []
            if result_csv.is_file():
                with result_csv.open() as stream:
                    rows = [{key: int(value, 0) for key, value in row.items()} for row in csv.DictReader(stream)]
            reason = validate_result(status, text, rows, args.tiles, args.expected_return)
            report.update(status='failed' if reason else 'passed', reason=reason, results=rows,
                          simulator_returncode=status)
            for line in text.splitlines():
                if line.startswith(('FW UART', 'TB loaded', 'PASS MULTITILE')) or 'FAIL MULTITILE' in line:
                    print(line)
            if reason:
                print(text[-4000:], file=sys.stderr)
            return 1 if reason else 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report['reason'] = str(error)
        print('Simulation failed: {}\nArtifacts: {}'.format(error, out), file=sys.stderr)
        return 1
    finally:
        after = hardware_state()
        report['hardware_unchanged'] = after == baseline
        if after != baseline:
            report.update(status='failed', reason='hardware or dependency state changed during simulation')
        (out / 'result.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
        lock.close()
        print('Result: {} ({})'.format(report['status'], out / 'result.json'))
        if after != baseline:
            raise RuntimeError('hardware or dependency state changed during simulation')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boot', choices=['rom', 'spm'], default='rom')
    parser.add_argument('--testbench', choices=['multitile', 'fft-ddr'], default='multitile')
    parser.add_argument('--sim-arg', action='append', default=[], help='extra simulator plusarg for a specialized testbench')
    parser.add_argument('--tiles', type=int, default=1)
    parser.add_argument('--dmas', type=int, default=1)
    parser.add_argument('--app', help='custom application source; default: checked Ara Hello workload')
    parser.add_argument('--app-march', default='rv64gcv_zifencei')
    parser.add_argument('--extra-source', action='append', default=[])
    parser.add_argument('--out', type=Path)
    parser.add_argument('--expected-return', type=int, default=0)
    parser.add_argument('--uart-expected', type=Path)
    parser.add_argument('--uart-tiles', choices=['tile0', 'all'], default='tile0')
    parser.add_argument('--check-buffer', nargs=2, metavar=('SYMBOL', 'EXPECTED_BINARY'))
    parser.add_argument('--require-ara', action='store_true')
    parser.add_argument('--require-fft', action='store_true')
    parser.add_argument('--allow-traps', action='store_true')
    parser.add_argument('--timeout', type=int, default=900, help='wall timeout per tool/simulation, seconds')
    parser.add_argument('--sim-timeout-ns', type=int, default=100000000)
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--reuse-build', action='store_true')
    args = parser.parse_args()
    if args.testbench == 'fft-ddr' and args.boot != 'spm':
        parser.error('FFT DDR testbench requires external SPM loading')
    if any(not arg.startswith('+FFT_') for arg in args.sim_arg):
        parser.error('specialized simulator arguments must start with +FFT_')
    if not (1 <= args.tiles <= 64 and 1 <= args.dmas <= 65536 and
            0 <= args.expected_return < (1 << 30) and args.timeout > 0 and args.sim_timeout_ns > 0):
        parser.error('invalid counts, return code or timeout')
    for tool in ['vlogan', 'vcs', 'bender', 'riscv64-unknown-elf-gcc']:
        if not shutil.which(tool):
            parser.error('required tool not found: ' + tool)
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
