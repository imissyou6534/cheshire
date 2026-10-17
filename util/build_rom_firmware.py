#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Compile loader/application objects, link once, and package a ROM/SPM firmware."""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

from elftools.elf.elffile import ELFFile

from rom_bender import prepared_paths


ROOT = Path(__file__).resolve().parents[1]
ROM_BASE, ROM_END = 0x02000000, 0x02004000
SPM_BASE, SPM_END = 0x10000000, 0x10010000


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fnv1a(data):
    value = 2166136261
    for byte in data:
        value = ((value ^ byte) * 16777619) & 0xffffffff
    return value


def publish(path, data, immutable=False):
    if path.exists():
        if path.read_bytes() == data:
            return
        if immutable:
            raise ValueError('immutable build artifact changed: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.publish-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
        if immutable:
            os.chmod(temporary, 0o444)
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def inspect_firmware(data):
    elf = ELFFile(io.BytesIO(data))
    if (elf.elfclass != 64 or not elf.little_endian or elf.header['e_machine'] != 'EM_RISCV'
            or elf.header['e_type'] != 'ET_EXEC' or elf.header['e_entry'] != ROM_BASE):
        raise ValueError('expected a linked RV64 firmware with ROM reset entry')
    loads = [p for p in elf.iter_segments() if p['p_type'] == 'PT_LOAD']
    if len(loads) != 2:
        raise ValueError('expected one ROM loader segment and one SPM application segment')
    boot, app = loads
    if (boot['p_vaddr'] != ROM_BASE or boot['p_paddr'] != ROM_BASE
            or boot['p_memsz'] != boot['p_filesz']
            or app['p_vaddr'] != SPM_BASE or not app['p_filesz']
            or app['p_filesz'] > app['p_memsz'] or app['p_memsz'] > SPM_END - SPM_BASE
            or app['p_paddr'] < ROM_BASE + boot['p_filesz']
            or app['p_paddr'] + app['p_filesz'] > ROM_END):
        raise ValueError('invalid ROM load addresses or SPM application bounds')
    allowed = {'.boot', '.rom_checksum', '.app', '.misc', '.bss'}
    for section in elf.iter_sections():
        if section['sh_flags'] & 2 and section['sh_size'] and section.name not in allowed:
            raise ValueError('unexpected allocated section: ' + section.name)
    symbols = {s.name: s['st_value'] for s in elf.get_section_by_name('.symtab').iter_symbols()
               if s.name and s['st_shndx'] != 'SHN_UNDEF' and s['st_info']['type'] != 'STT_FILE'}
    expected = {'_rom_start': ROM_BASE, '_start': SPM_BASE, '__app_start': SPM_BASE,
                '__app_load_start': app['p_paddr'], '__app_copy_size': app['p_filesz'],
                '__app_mem_size': app['p_memsz']}
    mismatches = {name: dict(symbol=symbols.get(name), segment=value)
                  for name, value in expected.items() if symbols.get(name) != value}
    if mismatches:
        raise ValueError('linker symbols disagree with the application segment: ' + str(mismatches))
    section = elf.get_section_by_name('.app')
    if section is None or section['sh_addr'] != SPM_BASE:
        raise ValueError('application code must start at the SPM base')
    checksum_section = elf.get_section_by_name('.rom_checksum')
    if checksum_section is None or checksum_section['sh_size'] != 4:
        raise ValueError('missing ROM checksum word')
    return app.data(), dict(entry=symbols['_start'], symbols=symbols,
                           rom_load_address=app['p_paddr'],
                           segments=[dict(load_addr=SPM_BASE, file_size=app['p_filesz'],
                                          mem_size=app['p_memsz'], checksum=fnv1a(app.data()))])


def build(args, out):
    cc = args.cc
    if not cc.endswith('gcc'):
        raise ValueError('--cc must name a RISC-V GCC executable ending in gcc')
    prefix = cc[:-3]
    app = Path(args.app or 'sw/tests/vector_helloworld.c')
    sources = [app] + [Path(path) for path in args.extra_source]
    sources = [(ROOT / path).resolve() if not path.is_absolute() else path.resolve() for path in sources]
    for path in sources:
        if path.suffix not in {'.c', '.S', '.s'} or not path.is_file():
            raise ValueError('--app/--extra-source require existing C or assembly source files: ' + str(path))
    common = ['-mabi=lp64d', '-mcmodel=medany', '-g', '-ffreestanding', '-fno-builtin',
              '-fno-common', '-fno-stack-protector', '-ffunction-sections', '-fdata-sections',
              '-msmall-data-limit=0', '-mno-relax', '-Wall', '-Wextra']
    compiler = subprocess.check_output([cc, '--version'], text=True).splitlines()[0]
    ara = prepared_paths()['ara']
    includes = ['-I' + str(ROOT / 'sw/include'), '-I' + str(ROOT / 'sw/deps/printf'),
                '-I' + str(Path(ara) / 'cheshire/sw/include')]
    inputs = [ROOT / 'hw/bootrom/autoboot/start.S', ROOT / 'hw/bootrom/autoboot/boot_main.c',
              ROOT / 'hw/bootrom/autoboot/autoboot.ld', ROOT / 'sw/link/common.ldh',
              ROOT / 'sw/lib/crt0.S', *sources, ROOT / 'sw/lib/dif/clint.c',
              ROOT / 'sw/lib/dif/uart.c', ROOT / 'sw/deps/printf/printf.c']
    with (out / 'firmware.log').open('w') as log, tempfile.TemporaryDirectory(prefix='.firmware-', dir=str(out)) as temporary:
        work = Path(temporary)
        objects = work / 'obj'
        objects.mkdir()

        def run(command, output=None):
            log.write(shlex.join([str(value) for value in command]) + '\n')
            log.flush()
            if output:
                with output.open('wb') as stream:
                    subprocess.run(command, cwd=str(ROOT), stdout=stream, stderr=log, check=True)
            else:
                subprocess.run(command, cwd=str(ROOT), stdout=log, stderr=log, check=True)

        object_files = []
        for name, source in [('boot_start', inputs[0]), ('boot_main', inputs[1])]:
            target = objects / (name + '.o')
            run([cc, *common, '-march=rv64gc_zifencei', '-Os',
                 '-DROM_AUTOBOOT_BAD_CHECKSUM=' + str(int(args.bad_checksum)), '-c', str(source), '-o', str(target)])
            object_files.append(str(target))
        app_sources = [ROOT / 'sw/lib/crt0.S', *sources, ROOT / 'sw/lib/dif/clint.c',
                       ROOT / 'sw/lib/dif/uart.c', ROOT / 'sw/deps/printf/printf.c']
        for index, source in enumerate(app_sources):
            target = objects / ('app_{}.o'.format(index))
            run([cc, *common, '-march=' + args.app_march, '-O2', *includes,
                 '-c', str(source), '-o', str(target)])
            object_files.append(str(target))
        elf_path = work / 'firmware.elf'
        run([cc, '-march=' + args.app_march, '-mabi=lp64d', '-nostdlib', '-nostartfiles',
             '-Wl,-L' + str(ROOT / 'sw/link'), '-Wl,--no-relax', '-Wl,--gc-sections',
             '-Wl,-Map=' + str(work / 'firmware.map'), '-T' + str(inputs[2]),
             *object_files, '-o', str(elf_path)])
        app_bytes, manifest = inspect_firmware(elf_path.read_bytes())
        checksum_file = work / 'checksum.bin'
        checksum_file.write_bytes(struct.pack('<I', fnv1a(app_bytes)))
        run([prefix + 'objcopy', '--update-section', '.rom_checksum=' + str(checksum_file), str(elf_path)])
        _, manifest = inspect_firmware(elf_path.read_bytes())
        run([prefix + 'objcopy', '-O', 'binary', str(elf_path), str(work / 'firmware.bin')])
        binary = (work / 'firmware.bin').read_bytes()
        expected_size = manifest['rom_load_address'] - ROM_BASE + len(app_bytes)
        if len(binary) != expected_size or len(binary) > ROM_END - ROM_BASE:
            raise ValueError('ROM binary size disagrees with linked load addresses')
        offset = manifest['rom_load_address'] - ROM_BASE
        if binary[offset:] != app_bytes:
            raise ValueError('objcopy ROM image disagrees with linked application bytes')
        run([prefix + 'objdump', '-d', str(elf_path)], work / 'firmware.dis')
        run([prefix + 'objdump', '-d', '-S', '-l', str(elf_path)], work / 'firmware.dump')
        run([prefix + 'readelf', '-lW', str(elf_path)], work / 'firmware.segments')
        run([sys.executable, str(ROOT / 'util/gen_bootrom.py'), '--sv-module', 'cheshire_bootrom',
             str(work / 'firmware.bin')], work / 'cheshire_bootrom.sv')
        sv = (work / 'cheshire_bootrom.sv').read_bytes()
        snapshot = out / 'snapshots' / (digest(sv) + '.sv')
        manifest.update(firmware_sha256=digest(elf_path.read_bytes()),
                        binary_sha256=digest(binary), rom_sha256=digest(sv),
                        rom_snapshot=str(snapshot), bad_checksum=args.bad_checksum,
                        rom_bytes=len(binary), compiler=compiler, app_march=args.app_march,
                        app_sources=[str(path) for path in sources],
                        source_sha256={str(path): digest(path.read_bytes()) for path in inputs})
        manifest_bytes = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
        record = out / 'snapshots' / (digest(manifest_bytes) + '.json')
        publish(snapshot, sv, immutable=True)
        publish(record, manifest_bytes, immutable=True)
        for name in ['firmware.elf', 'firmware.bin', 'firmware.dis', 'firmware.dump',
                     'firmware.map', 'firmware.segments', 'cheshire_bootrom.sv']:
            publish(out / name, (work / name).read_bytes())
        publish(out / 'application.bin', app_bytes)
        publish(out / 'payload.json', manifest_bytes)
    print('Unified ROM firmware: {} ({} bytes, checksum-negative={})'.format(
          out / 'firmware.elf', len(binary), int(args.bad_checksum)), file=sys.stderr)
    if args.print_snapshot:
        print(snapshot)
    elif args.print_record:
        print(record)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'target/rom_autoboot')
    parser.add_argument('--app', default='', help='application C/assembly source; default: vector_helloworld.c')
    parser.add_argument('--extra-source', action='append', default=[], help='additional application source (repeatable)')
    parser.add_argument('--cc', default=os.environ.get('RISCV_CC', 'riscv64-unknown-elf-gcc'))
    parser.add_argument('--app-march', default='rv64gcv_zifencei')
    parser.add_argument('--bad-checksum', action='store_true', help='build the negative loader test')
    printing = parser.add_mutually_exclusive_group()
    printing.add_argument('--print-snapshot', action='store_true')
    printing.add_argument('--print-record', action='store_true')
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    try:
        with (out / 'build.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            build(args, out)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, 'ROM firmware build failed: {}\nLog: {}\n'.format(error, out / 'firmware.log'))


if __name__ == '__main__':
    main()
