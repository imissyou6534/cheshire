"""Exercise Make dependency protection with disposable checkouts and a fake Bender."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ('register_interface', 'serial_link', 'axi_llc', 'opentitan_peripherals',
            'clint', 'axi_rt', 'axi_vga', 'idma', 'dram_rtl_sim')


@unittest.skipUnless(shutil.which('make'), 'GNU Make is required')
class MakeDependencyGuardTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='make-dependency-guard-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ('Makefile', 'cheshire.mk', 'target/xilinx/xilinx.mk', 'util/rom_bender.py'):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        (self.root / 'sw').mkdir()
        (self.root / 'sw/sw.mk').write_text('')
        (self.root / 'Bender.yml').write_text('package: {name: cheshire}\n')
        (self.root / 'Bender.lock').write_text(json.dumps({'packages': dict.fromkeys(PACKAGES, {})}))
        self.paths = {}
        for name in PACKAGES:
            checkout = self.root / '.bender/git/checkouts' / (name + '-fixture')
            checkout.mkdir(parents=True)
            (checkout / 'Bender.yml').write_text('package: {name: ' + name + '}\n')
            (checkout / '.generated').touch()
            self.paths[name] = checkout
        for package, name in [('clint', 'clint.mk'), ('axi_rt', 'axirt.mk'),
                              ('axi_vga', 'axi_vga.mk'), ('opentitan_peripherals', 'otp.mk'),
                              ('dram_rtl_sim', 'dram_rtl_sim.mk')]:
            (self.paths[package] / name).write_text('')
        (self.paths['idma'] / 'idma.mk').write_text(
            'IDMA_FULL_RTL := $(IDMA_ROOT)/target/rtl/idma_generated.sv\n')
        (self.paths['idma'] / 'target/rtl').mkdir(parents=True)
        (self.paths['idma'] / 'target/rtl/idma_generated.sv').touch()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.record = self.root / 'bender-calls.jsonl'
        fake = self.bin / 'bender'
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['GUARD_FIXTURE_ROOT'])
with (root / 'bender-calls.jsonl').open('a') as output:
    output.write(json.dumps(args) + '\\n')
if 'path' in args:
    name = args[args.index('path') + 1]
    print(root if name == 'cheshire' else root / '.bender/git/checkouts' / (name + '-fixture'))
elif 'checkout' in args:
    (root / '.bender/.chs_deps').touch()
elif 'script' in args:
    assert '--local' in args
    work = pathlib.Path(args[args.index('-d') + 1])
    config = json.loads((work / '.bender.yml').read_text())
    assert len(config['overrides']) == 9
    assert all(value['path'].startswith(str(root / '.bender/git/checkouts'))
               for value in config['overrides'].values())
    print('SAFE_SOURCE_LIST')
''')
        fake.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        GUARD_FIXTURE_ROOT=str(self.root), PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('MAKEFLAGS', None)
        self.env.pop('MFLAGS', None)

    def make(self, *args):
        return subprocess.run(['make', '--no-print-directory', *args], cwd=self.root,
                              env=self.env, text=True, capture_output=True, timeout=20)

    def wrapper(self, *args):
        return subprocess.run([sys.executable, str(self.root / 'util/rom_bender.py'), *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True, timeout=20)

    def test_help_does_not_bootstrap_or_invoke_bender_even_with_override(self):
        result = self.make('help', 'BENDER=bender')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.record.exists(), 'Make parsing invoked original Bender')
        self.assertFalse((self.root / '.bender/.chs_deps').exists())

    def test_clean_deps_and_bootstrap_are_blocked(self):
        for target in ('chs-clean-deps', 'clean-deps', str(self.root / '.bender/.chs_deps')):
            with self.subTest(target=target):
                result = self.make(target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Dependency protection', result.stderr)
                self.assertTrue(self.paths['idma'].is_dir())
                self.assertFalse(self.record.exists())

    def test_legacy_mutating_runners_and_regeneration_are_blocked(self):
        for target in ('chs-shared-dma-test', 'chs-shared-dma-system-test',
                       'chs-private-spm-system-test', 'clint', 'otp', 'axirt_regs', 'axi_vga'):
            with self.subTest(target=target):
                result = self.make(target)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Dependency protection', result.stderr)
                self.assertFalse(self.record.exists())

    def test_path_queries_never_invoke_bender(self):
        for name, path in [('cheshire', self.root), *self.paths.items()]:
            with self.subTest(name=name):
                result = self.wrapper('path', name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Path(result.stdout.strip()), path)
        self.assertFalse(self.record.exists())

    def test_mutating_commands_and_directory_overrides_are_rejected(self):
        for args in [('checkout',), ('update',), ('sources',),
                     ('script', 'vivado', '-d', str(self.root)),
                     ('script', 'vivado', '--dir=' + str(self.root))]:
            with self.subTest(args=args):
                result = self.wrapper(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Dependency protection', result.stderr)
        self.assertFalse(self.record.exists())

    def test_make_source_generation_uses_only_local_path_overrides(self):
        output = self.root / 'target/xilinx/scripts/add_sources.vcu118.tcl'
        output.parent.mkdir(parents=True)
        result = self.make(str(output), 'BENDER=bender')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text().strip(), 'SAFE_SOURCE_LIST')
        calls = [json.loads(line) for line in self.record.read_text().splitlines()]
        self.assertEqual(len(calls), 1)
        self.assertIn('--local', calls[0])

    def test_missing_checkout_fails_without_bootstrap(self):
        shutil.rmtree(self.paths['clint'])
        result = self.make('help')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Dependency protection', result.stderr)
        self.assertFalse(self.record.exists())

    def test_missing_generated_artifact_is_not_regenerated(self):
        marker = self.paths['clint'] / '.generated'
        marker.unlink()
        result = self.make(str(marker))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Dependency protection', result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse(self.record.exists())


if __name__ == '__main__':
    unittest.main()
