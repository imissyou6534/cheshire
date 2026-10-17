# Unified ROM/SPM Firmware

The ROM-autoboot target compiles the loader and application separately and links
them once into `firmware.elf`. The loader executes in ROM. Application instructions
and initialized data execute in private SPM but are stored in the ROM image.
Changing application source changes the generated ROM and requires a new FPGA
bitstream. No CPU, Ara, DMA, interconnect or board RTL source is rewritten.

## Build Commands

From the Cheshire project root, build the default Ara Hello firmware only:

```bash
make chs-rom-autoboot
```

Select another application source with the same `main()`/CRT contract:

```bash
make chs-rom-autoboot CHS_ROM_APP=sw/tests/helloworld.c
```

`CHS_ROM_APP` now selects C/assembly source, not a prelinked ELF. An empty value
selects `sw/tests/vector_helloworld.c`. A prelinked ELF is explicitly rejected.
`CHS_ROM_EXTRA_SRCS` supplies additional source paths, `CHS_ROM_APP_MARCH` defaults
to `rv64gcv_zifencei`, and `CHS_ROM_CC` defaults to the project's RISC-V compiler.
The standard CRT, CLINT/UART drivers and printf are included; unreferenced code is
removed by the linker. Source files must not introduce another `_start` symbol.

Build a complete VCU118 bitstream with the same firmware selection:

```bash
make chs-xilinx-multi-tile-rom-vcu118 \
  CHS_ROM_APP=sw/tests/vector_helloworld.c \
  CHS_NUM_TILES=1 CHS_NUM_DMAS=1 CHS_XILINX_SYNTH_ONLY=0 \
  VIVADO=/opt/Xilinx/Vivado/2024.2/bin/vivado
```

The existing FPGA implementation uses the returned immutable ROM snapshot. Its
output remains `target/xilinx/out/multi_tile_rom.vcu118.bit` and `.ltx`. Firmware
generation alone does not update an existing bitstream.

For an isolated software build, including tests and alternate output directories:

```bash
python3 util/build_rom_firmware.py --out /tmp/cheshire-firmware \
  --app sw/tests/vector_helloworld.c --print-record
```

The shell entry `util/build_rom_autoboot.sh` forwards to this Python builder.
`--extra-source` is repeatable; `--cc` or `RISCV_CC` selects the toolchain.

## Layout and Startup

`hw/bootrom/autoboot/autoboot.ld` defines two ELF PT_LOAD segments:

| Content | Execution address (VMA) | Image address (LMA) |
|---|---|---|
| `.boot`, `.rom_checksum` | ROM at `0x02000000` | Same ROM address |
| Application `.app`, `.misc` | SPM at `0x10000000` | ROM immediately after loader/checksum |
| Application `.bss` | SPM after initialized data | No stored bytes |

The application has one contiguous loadable image, including any `.bulk` data.
BSS follows the file-backed bytes. Program/BSS are limited to the first 64 KiB
of the 128 KiB private SPM. The application stack uses `0x10010000..0x10018000`;
the upper 32 KiB remain available to the ROM loader. The initial application SP
is `0x10017ff8`, accounting for the existing CRT's 24-byte save before calling C.
The linker checks entry addresses, ROM capacity and SPM image/stack separation.
Applications must size their runtime stack usage within this reserved range.

The scalar loader is compiled with `rv64gc_zifencei -Os`; application objects
use the selected ISA and `-O2`. Loader entry is `_rom_start`; application entry
is `_start`. The loader has its own function and global-pointer symbols.

After the single link, Python computes FNV-1a over the application's PT_LOAD
bytes and uses `objcopy --update-section` to fill the `.rom_checksum` word in the
same ELF. This is packaging, not a second link. `objcopy -O binary` then extracts
the complete ROM image using load addresses. The builder validates the ELF
layout and binary bytes before generating ROM RTL with `gen_bootrom.py`.

On reset, the loader initializes SPM, checks the source checksum, copies the
application once through the uncached SPM alias at `0x14000000`, clears BSS and
checks the destination. It executes fences and jumps to `_start` in SPM.
The application's CRT initializes its context and calls `main()`.

## Artifacts

All normal outputs are in `target/rom_autoboot/`:

| File | Purpose |
|---|---|
| `firmware.elf` | Final unified, checksum-patched ELF |
| `firmware.bin` | Complete ROM image, at most 16 KiB |
| `firmware.dis` | Instruction disassembly at execution addresses |
| `firmware.dump` | Disassembly with source and line information |
| `firmware.map` | Linker layout and symbol map |
| `firmware.segments` | Program headers with ROM/SPM addresses |
| `firmware.log` | Compiler, linker and packaging command log |
| `cheshire_bootrom.sv` | Generated ROM RTL |
| `payload.json` | Address/size/checksum, compiler and source hashes |
| `snapshots/<hash>.sv`, `<hash>.json` | Immutable ROM and paired build records |

Temporary objects are deleted after building; compiler/link commands remain in
`firmware.log`. ELF permissions for the combined application segment are RWE,
which GNU ld may warn about; this bare-metal loader does not configure PMP from
ELF flags. Existing `application.elf`, `bootrom.*` and `rom_payload.h` from the old
two-link flow are not consumed by this builder. The original `sw/link/spm.ld`
and dedicated private-SPM test linkers are unchanged.

## Verification

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s util/tests -v
bash util/run_rom_autoboot_test.sh
```

The integration tests build real RISC-V firmware, inspect load/execution
addresses, independently decode the ROM RTL, check checksums, custom initialized
data and NOLOAD BSS, reject capacity overflow and verify stable ROM snapshots.
The VCS runner checks one tile, two tiles and a deliberately wrong-checksum
loader; it requires the exact UART/buffer results and actual Ara transactions.
Prepare dependency patches/generated RTL before running it: the runner checks
PLIC state and does not apply dependency patches or regenerate PLIC RTL.

`util/rom_bender.py` resolves source lists with a temporary wrapper manifest and
path overrides for every dependency already present in `.bender`. Bender runs
locally against those paths; it cannot restore these checkouts to lockfile
revisions or fetch missing repositories. Missing/ambiguous prepared directories
are errors. The main Bender manifests and dependency branches are not changed.
