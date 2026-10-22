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

    def test_missing_required_rtl_is_not_regenerated(self):
        rtl = self.paths['idma'] / 'target/rtl/idma_generated.sv'
        rtl.unlink()
        result = self.make(str(rtl))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Dependency protection', result.stderr)
        self.assertFalse(rtl.exists())
        self.assertFalse(self.record.exists())

    def test_fpga_build_runs_without_untracked_generation_markers(self):
        markers = [self.paths[name] / '.generated' for name in
                   ('clint', 'opentitan_peripherals', 'axi_rt', 'axi_vga', 'serial_link')]
        for marker in markers:
            marker.unlink()
        regs = self.root / 'hw/regs'
        regs.mkdir(parents=True)
        (regs / 'cheshire_regs.hjson').write_text('{}')
        for name in ('cheshire_reg_pkg.sv', 'cheshire_reg_top.sv'):
            (regs / name).write_text('')
        scripts = self.root / 'target/xilinx/scripts'
        scripts.mkdir(parents=True)
        (scripts / 'impl_ip.tcl').write_text('')
        for name in ('clkwiz', 'vio', 'ddr4'):
            ip = self.root / ('target/xilinx/build/vcu118.' + name)
            ip.mkdir(parents=True)
            (ip / 'out.xci').write_text('fixture')
        (self.root / 'fixture_rom.sv').write_text('')
        (self.root / 'util/build_rom_autoboot.sh').write_text(
            'printf "%s\\n" "$GUARD_FIXTURE_ROOT/fixture_rom.sv"\n')
        (self.root / 'util/prepare_shared_dma_plic.sh').write_text('exit 0\n')
        vivado = self.bin / 'vivado'
        vivado.write_text('#!/bin/sh\n'
                          'printf "%s\\n" "$*" > "$GUARD_FIXTURE_ROOT/vivado-call"\n')
        vivado.chmod(0o755)
        result = self.make('chs-xilinx-multi-tile-rom-vcu118', 'VIVADO=' + str(vivado))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'vivado-call').is_file())
        self.assertTrue(all(not marker.exists() for marker in markers))
        self.assertFalse((self.root / '.bender/.chs_deps').exists())

    def test_software_headers_do_not_require_generation_markers(self):
        shutil.copyfile(ROOT / 'sw/sw.mk', self.root / 'sw/sw.mk')
        for path in self.paths.values():
            (path / '.generated').unlink()
        source = self.paths['clint'] / 'src/clint.hjson'
        source.parent.mkdir(parents=True)
        source.write_text('{}')
        regtool = self.bin / 'regtool'
        regtool.write_text('#!/bin/sh\nprintf "HEADER_FIXTURE\\n"\n')
        regtool.chmod(0o755)
        output = self.root / 'sw/include/regs/clint.h'
        result = self.make(str(output), 'REGTOOL=' + str(regtool))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text().strip(), 'HEADER_FIXTURE')
        probe = self.root / 'probe.mk'
        probe.write_text('guard-headers:\n\t@printf "%s\\n" $(CHS_SW_GEN_HDRS)\n')
        result = self.make('-f', 'Makefile', '-f', str(probe), 'guard-headers')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('.generated', result.stdout)
        for name in ('gpio_regs.h', 'i2c_regs.h', 'spi_host_regs.h', 'rv_plic_regs.h'):
            self.assertIn(str(self.paths['opentitan_peripherals'] / 'sw/include' / name),
                          result.stdout)
        self.assertTrue(all(not (path / '.generated').exists() for path in self.paths.values()))


if __name__ == '__main__':
    unittest.main()
