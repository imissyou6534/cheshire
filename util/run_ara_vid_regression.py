#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run VID and neighboring-mask checks on fresh legacy/wide CVA6/Ara models."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
from run_multitile_sim import ROOT, hardware_state, run_timed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--profile', choices=['legacy', 'wide', 'both'], default='both')
    parser.add_argument('--timeout', type=int, default=900)
    args = parser.parse_args()
    root = args.out.resolve()
    root.mkdir(parents=True, exist_ok=True)
    before = hardware_state()
    profiles = ['legacy', 'wide'] if args.profile == 'both' else [args.profile]
    report = dict(status='failed', hardware=before, cases={})
    try:
        for profile in profiles:
            model = root / profile / 'model'
            workloads = [('vid', 'sw/tests/ara_vid_regression.c'),
                         ('overlap', 'target/sim/sw/ara_mask_overlap_repro.c'),
                         ('hello', None)]
            for index, (name, app) in enumerate(workloads):
                result_dir = root / profile / name
                result_dir.mkdir(parents=True, exist_ok=False)
                argv = [sys.executable, str(ROOT / 'util/run_multitile_sim.py'),
                        '--boot', 'spm', '--bus-profile', profile, '--tiles', '1', '--dmas', '1',
                        '--require-ara', '--sim-timeout-ns', '100000000',
                        '--timeout', str(args.timeout), '--out', str(model)]
                if app:
                    argv += ['--app', app]
                if index:
                    argv += ['--reuse-build']
                with (result_dir / 'driver.log').open('w') as stream:
                    result = run_timed(argv, cwd=ROOT, stdout=stream,
                                       stderr=subprocess.STDOUT, timeout=args.timeout * 4)
                for filename in ['result.json', 'result.csv', 'run.log', 'build.log']:
                    if (model / filename).is_file():
                        shutil.copyfile(model / filename, result_dir / filename)
                if (model / 'firmware').is_dir():
                    shutil.copytree(model / 'firmware', result_dir / 'firmware')
                details = json.loads((result_dir / 'result.json').read_text())
                report['cases'][profile + '/' + name] = details
                (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
                if result.returncode or details['status'] != 'passed' or not details['hardware_unchanged']:
                    raise RuntimeError('{} failed; see {}'.format(profile + '/' + name, result_dir))
                print('PASS ' + profile + '/' + name, flush=True)
            monitor = root / profile / 'monitor'
            with (root / profile / 'monitor_driver.log').open('w') as stream:
                result = run_timed([sys.executable, str(ROOT / 'util/run_ara_vid_monitor.py'),
                                    '--profile', profile, '--model', str(model),
                                    '--firmware', str(root / profile / 'overlap/firmware'),
                                    '--out', str(monitor)], cwd=ROOT, stdout=stream,
                                   stderr=subprocess.STDOUT, timeout=args.timeout * 2)
            if result.returncode:
                raise RuntimeError('{} monitor failed; see {}'.format(profile, monitor))
            details = json.loads((monitor / 'report.json').read_text())
            report['cases'][profile + '/monitor'] = details
            if details['status'] != 'passed' or not details['hardware_unchanged']:
                raise RuntimeError('{} monitor result mismatch'.format(profile))
            print('PASS ' + profile + '/monitor', flush=True)
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
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        if not report['hardware_unchanged']:
            raise RuntimeError('RTL or dependency state changed during regression')


if __name__ == '__main__':
    raise SystemExit(main())
