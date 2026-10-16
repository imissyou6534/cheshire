#!/usr/bin/env python3
"""Embed a validated RISC-V executable as ROM data for copying to private SPM."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import struct

from elftools.common.exceptions import ELFError
from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection


SPM_START = 0x10000000
SPM_END = 0x10010000
MAX_SEGMENTS = 8
UINT64_MAX = (1 << 64) - 1


def checked_end(start, size, description):
    end = start + size
    if start < 0 or size < 0 or end > UINT64_MAX:
        raise ValueError("{} overflows a 64-bit address".format(description))
    return end


def require_file_range(offset, size, file_size, description):
    end = checked_end(offset, size, description)
    if end > file_size:
        raise ValueError("truncated {}".format(description))


def fnv1a(data):
    checksum = 2166136261
    for byte in data:
        checksum = ((checksum ^ byte) * 16777619) & 0xFFFFFFFF
    return checksum


def parse_payload(data, spm_start=SPM_START, spm_end=SPM_END):
    """Parse through pyelftools, then enforce the loader's fixed-address contract."""
    if not 0 <= spm_start < spm_end <= UINT64_MAX:
        raise ValueError("invalid SPM bounds")
    elf = ELFFile(io.BytesIO(data))
    header = elf.header
    if (elf.elfclass != 64 or not elf.little_endian
            or header["e_type"] != "ET_EXEC" or header["e_machine"] != "EM_RISCV"
            or header["e_version"] != "EV_CURRENT"
            or header["e_ident"]["EI_VERSION"] != "EV_CURRENT"):
        raise ValueError("expected ELF64 little-endian RISC-V ET_EXEC version 1")
    if header["e_ehsize"] != elf.structs.Elf_Ehdr.sizeof():
        raise ValueError("invalid ELF header size")

    # Validate tables before iteration: pyelftools can otherwise return short data.
    section_count = 0
    if header["e_shoff"]:
        if header["e_shentsize"] != elf.structs.Elf_Shdr.sizeof():
            raise ValueError("invalid section header size")
        require_file_range(header["e_shoff"], header["e_shentsize"], len(data),
                           "section header table")
        section_count = elf.num_sections()
        require_file_range(header["e_shoff"], section_count * header["e_shentsize"],
                           len(data), "section header table")
    elif header["e_shnum"] or header["e_shstrndx"]:
        raise ValueError("missing section header table")

    segment_count = elf.num_segments()
    if segment_count:
        if header["e_phentsize"] != elf.structs.Elf_Phdr.sizeof():
            raise ValueError("invalid program header size")
        if header["e_phoff"] < header["e_ehsize"]:
            raise ValueError("invalid program header offset")
        require_file_range(header["e_phoff"], segment_count * header["e_phentsize"],
                           len(data), "program header table")

    segments = []
    executable_file_ranges = []
    for program in elf.iter_segments():
        if program["p_type"] != "PT_LOAD":
            continue
        if len(segments) == MAX_SEGMENTS:
            raise ValueError("at most {} PT_LOAD segments are supported".format(MAX_SEGMENTS))
        address = program["p_paddr"]
        file_size = program["p_filesz"]
        mem_size = program["p_memsz"]
        if address != program["p_vaddr"]:
            raise ValueError("PT_LOAD virtual and physical addresses differ; relocation unsupported")
        if mem_size == 0:
            raise ValueError("PT_LOAD memory size must be nonzero")
        if file_size > mem_size:
            raise ValueError("PT_LOAD file size exceeds memory size")
        end = checked_end(address, mem_size, "PT_LOAD memory range")
        if address < spm_start or address >= spm_end or end > spm_end:
            raise ValueError("PT_LOAD memory range is outside SPM [0x{:x}, 0x{:x})".format(
                spm_start, spm_end))
        if file_size:
            require_file_range(program["p_offset"], file_size, len(data), "PT_LOAD data")
        payload = program.data()
        if len(payload) != file_size:
            raise ValueError("truncated PT_LOAD data")
        segments.append(dict(load_addr=address, file_size=file_size, mem_size=mem_size,
                             checksum=fnv1a(payload), data=payload))
        if program["p_flags"] & 1:
            executable_file_ranges.append((address, address + file_size))

    segments.sort(key=lambda item: item["load_addr"])
    previous_end = spm_start
    for segment in segments:
        if segment["load_addr"] < previous_end:
            raise ValueError("PT_LOAD memory ranges overlap")
        previous_end = segment["load_addr"] + segment["mem_size"]
    entry = header["e_entry"]
    if entry & 1:
        raise ValueError("entry must be aligned to two bytes (RVC)")
    if not any(start <= entry < end for start, end in executable_file_ranges):
        raise ValueError("entry is not inside file-backed bytes of an executable PT_LOAD segment")

    symbols = {}
    for index in range(section_count):
        section = elf.get_section(index)
        if section["sh_type"] != "SHT_NOBITS":
            require_file_range(section["sh_offset"], section["sh_size"], len(data),
                               "section data")
        if not isinstance(section, SymbolTableSection):
            continue
        symbol_size = elf.structs.Elf_Sym.sizeof()
        if section["sh_entsize"] != symbol_size or section["sh_size"] % symbol_size:
            raise ValueError("invalid symbol table entry size")
        if section["sh_link"] >= section_count:
            raise ValueError("invalid symbol string table index")
        strings = elf.get_section(section["sh_link"])
        if strings["sh_type"] != "SHT_STRTAB":
            raise ValueError("symbol table does not link to a string table")
        require_file_range(strings["sh_offset"], strings["sh_size"], len(data),
                           "symbol string table")
        for symbol in section.iter_symbols():
            if symbol["st_name"] >= strings["sh_size"]:
                raise ValueError("invalid symbol name offset")
            if symbol.name and symbol["st_shndx"] != "SHN_UNDEF":
                symbols.setdefault(symbol.name, symbol["st_value"])
    return entry, segments, symbols


def render_header(entry, segments):
    lines = [
        "/* Generated by gen_rom_payload.py. */",
        "#ifndef ROM_PAYLOAD_GENERATED_H",
        "#define ROM_PAYLOAD_GENERATED_H",
        "",
        "#include <stdint.h>",
        "#include <stddef.h>",
        "",
        "typedef struct {",
        "    uintptr_t load_addr;",
        "    size_t file_size;",
        "    size_t mem_size;",
        "    const uint8_t *data;",
        "    uint32_t checksum;",
        "} rom_payload_segment_t;",
        "",
        "#define ROM_PAYLOAD_NUM_SEGMENTS {}".format(len(segments)),
        "#define ROM_PAYLOAD_ENTRY UINT64_C(0x{:x})".format(entry),
        "",
    ]
    for index, segment in enumerate(segments):
        payload = segment["data"] or b"\x00"
        lines.extend([
            "static const uint8_t rom_payload_data_{}[{}]".format(index, len(payload)),
            '    __attribute__((section(".rom_payload"), aligned(8), used)) = {',
        ])
        for offset in range(0, len(payload), 12):
            lines.append("    " + ", ".join("0x{:02x}".format(byte)
                                               for byte in payload[offset:offset + 12]) + ",")
        lines.extend(["};", ""])
    lines.extend([
        "static const rom_payload_segment_t rom_payload_segments[]",
        '    __attribute__((section(".rom_payload_meta"), aligned(8), used)) = {',
    ])
    for index, segment in enumerate(segments):
        lines.append(
            "    {{ UINT64_C(0x{:x}), {}, {}, rom_payload_data_{}, UINT32_C(0x{:08x}) }},".format(
                segment["load_addr"], segment["file_size"], segment["mem_size"],
                index, segment["checksum"]))
    lines.extend(["};", "", "#endif /* ROM_PAYLOAD_GENERATED_H */", ""])
    return "\n".join(lines).encode("ascii")


def write_if_changed(path, content):
    try:
        if path.read_bytes() == content:
            return
    except FileNotFoundError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elf", required=True, type=Path)
    parser.add_argument("--header", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--spm-start", type=lambda value: int(value, 0), default=SPM_START)
    parser.add_argument("--spm-end", type=lambda value: int(value, 0), default=SPM_END)
    args = parser.parse_args(argv)
    try:
        paths = [path.resolve() for path in (args.elf, args.header, args.manifest)]
        if len(set(paths)) != 3:
            raise ValueError("ELF, header and manifest paths must be distinct")
        data = args.elf.read_bytes()
        entry, segments, symbols = parse_payload(data, args.spm_start, args.spm_end)
        header = render_header(entry, segments)
        manifest = dict(entry=entry,
                        segments=[{key: value for key, value in segment.items() if key != "data"}
                                  for segment in segments],
                        elf_sha256=hashlib.sha256(data).hexdigest(), symbols=symbols)
        manifest_data = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
        write_if_changed(args.header, header)
        write_if_changed(args.manifest, manifest_data)
    except (OSError, ValueError, ELFError, struct.error, AssertionError, KeyError,
            IndexError, TypeError) as error:
        parser.error(str(error) or "invalid ELF format")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
