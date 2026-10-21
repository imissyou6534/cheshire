#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Synthesize direct/cut downsizer boundaries and check Vivado LUTLP-1."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
from rom_bender import prepared_paths
from run_multitile_sim import ROOT, hardware_state, run_timed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--vivado', default='vivado')
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('--timeout', type=int, default=1800)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    paths = prepared_paths()
    before = hardware_state()
    report = dict(status='failed', hardware=before, cases={})
    probe = ROOT / 'target/sim/src/dw_loop_probe.sv'
    tcl = ROOT / 'util/tests/axi_dw_cut_drc.tcl'
    try:
        includes = [str(paths[p] / 'include') for p in ['axi', 'common_cells', 'register_interface']]
        first = [paths['common_cells'] / 'src/cf_math_pkg.sv', paths['axi'] / 'src/axi_pkg.sv']
        sources = [str(p) for p in first]
        argv = [args.verilator, '--json-only', '--timing', '-Wno-fatal', '-DSYNTHESIS',
                '--top-module', 'dw_loop_probe', '--Mdir', str(out / 'json'),
                '--json-only-output', str(out / 'probe.tree.json'),
                '--json-only-meta-output', str(out / 'probe.meta.json')]
        for package, include in zip(['axi', 'common_cells', 'register_interface'], includes):
            argv += ['-I' + include, '-y', str(paths[package] / 'src')]
        argv += sources + [str(ROOT / 'hw/cheshire_axi_dw_bridge.sv'), str(probe)]
        for debug in [0, 1]:
            with (out / ('resolve-' + str(debug) + '.log')).open('w') as stream:
                run_timed(argv + ['-GDebugMode=' + str(debug)], cwd=out, stdout=stream,
                          stderr=subprocess.STDOUT, timeout=120, check=True)
            metadata = json.loads((out / 'probe.meta.json').read_text())
            for record in metadata['files'].values():
                filename = record['filename']
                if filename.endswith('.sv') and Path(filename).is_file() and filename not in sources:
                    sources.append(filename)
        if any(any(c in p for c in '{}\n\r') for p in [*includes, *sources]):
            raise ValueError('unsupported Tcl metacharacters in source paths')
        (out / 'sources.tcl').write_text(
            'set probe_includes [list ' + ' '.join('{' + s + '}' for s in includes) + ']\n' +
            'set probe_sources [list ' + ' '.join('{' + s + '}' for s in sources) + ']\n')
        report['source_sha256'] = {s: hashlib.sha256(Path(s).read_bytes()).hexdigest() for s in sources}
        report['tcl_sha256'] = hashlib.sha256(tcl.read_bytes()).hexdigest()
        with (out / 'driver.log').open('w') as stream:
            result = run_timed([args.vivado, '-mode', 'batch', '-source', str(tcl),
                                '-log', 'synth.log', '-journal', 'synth.jou', '-tclargs', str(out)],
                               cwd=out, stdout=stream, stderr=subprocess.STDOUT, timeout=args.timeout)
        log = (out / 'synth.log').read_text(errors='replace')
        if result.returncode or re.search(r'^ERROR:', log, re.MULTILINE):
            raise RuntimeError('Vivado failed; inspect ' + str(out / 'synth.log'))
        results = re.findall(r'^PROBE_RESULT (periph|debug)-(direct|cut) loops=(\d+)$', log, re.MULTILINE)
        if len(results) != 4:
            raise RuntimeError('four distinct Vivado DRC results are required')
        for kind, mode, count in results:
            name = kind + '-' + mode
            if name in report['cases']:
                raise RuntimeError('duplicate DRC result: ' + name)
            loops = int(count)
            if (mode == 'cut' and loops != 0) or (mode == 'direct' and loops < 1):
                raise RuntimeError('unexpected loop count for ' + name)
            report['cases'][name] = dict(loops=loops, expected_failure=mode == 'direct')
            print(name + ': LUTLP-1=' + str(loops), flush=True)
        report['status'] = 'passed'
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        report['reason'] = str(error)
        print(error, file=sys.stderr)
        return 1
    finally:
        report['hardware_unchanged'] = hardware_state() == before
        if not report['hardware_unchanged']:
            report['status'] = 'failed'
        (out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        if not report['hardware_unchanged']:
            raise RuntimeError('RTL or dependencies changed during boundary DRC')


if __name__ == '__main__':
    raise SystemExit(main())
