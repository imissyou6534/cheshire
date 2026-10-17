#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read prepared paths and emit source lists without checking out dependencies."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml


ROOT = Path(__file__).resolve().parents[1]


def prepared_paths():
    packages = yaml.safe_load((ROOT / 'Bender.lock').read_text())['packages']
    checkouts = ROOT / '.bender/git/checkouts'
    result = {}
    for name in packages:
        matches = [path for path in checkouts.glob(name + '-*') if (path / 'Bender.yml').is_file()]
        if len(matches) != 1:
            raise ValueError('expected one prepared checkout for {}; found {}. '
                             'Prepare dependencies explicitly before this build.'.format(name, len(matches)))
        result[name] = matches[0].resolve()
    return result


def main():
    args = sys.argv[1:]
    if args == ['check']:
        prepared_paths()
        print('prepared')
        return
    if len(args) == 2 and args[0] == 'path':
        paths = prepared_paths()
        paths['cheshire'] = ROOT
        if args[1] not in paths:
            raise ValueError('unknown prepared package: ' + args[1])
        print(paths[args[1]])
        return
    if len(args) < 2 or args[0] != 'script' or args[1] not in {
            'vivado', 'vcs', 'vsim', 'verilator', 'flist', 'flist-plus'}:
        raise ValueError('only check, path PACKAGE and script TOOL are allowed; '
                         'checkout/update and other raw Bender commands are disabled')
    # Global directory overrides could redirect Bender to the real lock file.
    if any(arg.startswith(('-d', '--dir', '--manifest', '--config', '--database'))
           for arg in args[2:]):
        raise ValueError('Bender directory/configuration overrides are disabled')
    paths = prepared_paths()
    with tempfile.TemporaryDirectory(prefix='cheshire-rom-sources-') as temporary:
        work = Path(temporary)
        # Path overrides apply transitively, including dependencies of dependencies.
        (work / 'Bender.yml').write_text(json.dumps({
            'package': {'name': 'cheshire_rom_sources'},
            'dependencies': {'cheshire': {'path': str(ROOT)}}}))
        (work / '.bender.yml').write_text(json.dumps({
            'database': str(work / '.bender'),
            'overrides': {name: {'path': str(path)} for name, path in paths.items()}}))
        subprocess.run(['bender', '--local', '-d', str(work), *args,
                        '--package', 'cheshire'], check=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit('Dependency protection: ' + str(error))
