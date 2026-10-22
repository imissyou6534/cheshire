# Ara Mask Scalar Boundary Fix (2026-10-22)

This fixes the prepared Ara checkout used by the server project at
`/home/user06/work/xinkailai/cheshire`, based on commit
`bf042ed7fa2ef87dd8db821d9ebb951fd419d166`.
Verification preserved the dependency HEAD and Bender manifests. The RTL fix
was subsequently committed as `a51caad9302cbf74ff4119f4ebac28a835b4ae3b`.
Only
`hardware/src/masku/masku.sv` and `hardware/src/ara_dispatcher.sv` are modified.
The portable diff is `util/patches/ara-mask-scalar-tail.patch`.

## Defects and Changes

1. **Partial scalar slices:** VCPOP/VFIRST processed all 16 bits even when
   fewer than 16 body elements remained. The slice inputs are now ANDed with
   a per-bit validity check against the remaining element count. This excludes
   legal tail-agnostic ones without changing execution-mask semantics.
2. **Empty vectors:** VL=0 scalar mask operations waited for a backend result
   that never arrived. The dispatcher now returns 0 for VCPOP and -1 for VFIRST
   through the existing request/response handshake without issuing backend work.
3. **VFIRST index:** Empty LZC input produces an unusable index (15 here), not
   the skipped slice length (16). The running index now advances a full slice.
4. **VFIRST operand leftovers:** Lanes request complete source/predicate words
   for VL. Early scalar return consumed just the current word, leaving later
   untagged operand words to contaminate the next instruction. VFIRST now
   latches its first match/index and drains all requested slices before
   responding. No-match still returns -1, including a match in the final slice.

The last change trades VFIRST's early-match latency optimization for correct
operand consumption. No extra VRF writes or memory traffic are introduced;
already-requested operand data is consumed before accepting subsequent work.

## Regression

`sw/tests/ara_mask_scalar_tail.c` exercises 1,708 instruction pairs, producing
3,416 scalar results per hardware profile:

- SEW 8/16/32/64, LMUL=2 for e8 and LMUL=1 for the other widths.
- VL 0,1,4,7,8,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512,
  clipped to the configuration's VLMAX.
- Zero/all-one/alternating masks, bit 0, a bit just outside VL, a bit at VL-1,
  and active low bits with every tail bit set.
- Unmasked operations, explicit all-one execution mask, zero execution mask,
  and alternating execution mask; repeated back-to-back operations.

The C reference uses scalar word operations. The independent Python oracle in
`util/run_ara_mask_scalar_tail.py` uses arbitrary-precision integer bitsets.
The system TB reads every result through AXI and checks the complete 16,400-byte
report against that oracle, along with exact UART summary and return zero.
Five host tests cover oracle edge cases and output layout.

```bash
cd /home/user06/work/xinkailai/cheshire
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s util/tests -p test_ara_mask_scalar_tail.py -v
python3 util/run_ara_mask_scalar_tail.py --profile wide \
  --out target/ara_mask_tail_fix/green/wide
python3 util/run_ara_mask_scalar_tail.py --profile legacy \
  --out target/ara_mask_tail_fix/green/legacy
python3 util/run_ara_rom_selftest.py --out target/ara_mask_tail_fix/rom
```

The focused matrix uses external-SPM program loading to shorten runtime. The
unchanged 48-case/328-check application is separately booted from embedded ROM,
with the original independent UART and AXI summary checks. Simulation uses the
existing fast UART variant; the normal board application remains 115200 baud.

## Evidence Before the Fix

- The original complete ROM test reported mask 0x5, VL=4, popcount 14 instead
  of 2 and returned 1 (`target/ara_rom_selftest/verification.json`).
- The new matrix hung on its first VL=0 VCPOP. A bounded 5 ms simulation ended
  with a watchdog and the last retired instruction setting VL=0. Evidence:
  `target/ara_mask_tail_fix/red/wide/probe.log` and `trace_hart_0.log`.
- After partial-slice/VL=0 changes, the matrix exposed stale operands first at
  VL=129 on two lanes and VL=257 on four lanes. Saved logs:
  `green/legacy/run_before_drain.log` and `green/wide/run_before_drain.log`.
  For example, a zero execution mask returned popcount 128/256 instead of 0.

## Verified Results

All five VCS system regressions passed on 2026-10-22:

| Regression | Cases / Checks | Independent Check | Result |
| --- | --- | --- | --- |
| 2-lane scalar boundaries | 1,708 / 3,416 | All 16,400 report bytes via AXI, exact UART, return 0 | PASS |
| 4-lane scalar boundaries | 1,708 / 3,416 | All 16,400 report bytes via AXI, exact UART, return 0 | PASS |
| Embedded-ROM wide self-test | 48 / 328 | Exact 16,174 UART bytes, AXI summary, ROM startup, return 0 | PASS |
| Existing VID/mask neighbors, 2 lanes | 217 | Return 0 and AXI readback of completed case count | PASS |
| Existing VID/mask neighbors, 4 lanes | 217 | Return 0 and AXI readback of completed case count | PASS |

Nineteen host/build tests also passed. The existing neighbor workload is
`sw/tests/ara_vid_regression.c` and includes VIOTA, VMSBF, VMSOF and VMSIF.
It ran on the same freshly compiled SPM models with separate result/log
directories under `target/ara_mask_tail_fix/neighbors/`.

The original failing ROM case now prints:

```text
[ARA] START vcpop+vfirst e32 m1
[ARA] i=0 a=0x00000005 b=0x00000000 got=0x00000002 exp=0x00000002 PASS
[ARA] i=1 a=0x00000005 b=0x00000000 got=0x00000000 exp=0x00000000 PASS
...
[ARA] SUMMARY cases=48 checks=328 failed=0
PASS MULTITILE boot=rom tiles=1 dmas=1
```

The ROM program binary and its UART reference are byte-for-byte identical to
the pre-fix run. The expected value was not changed. Every run checked that
hardware contents stayed constant during simulation. Dependency HEADs and
all other dependency HEAD/status records stayed unchanged; Ara has exactly
the two intended modified RTL files.

`target/ara_mask_tail_fix/verification.json` records results, source/patch hashes,
and dependency assertions. The actual complete decoded UART is
`target/ara_mask_tail_fix/rom/uart_actual.txt`. Detailed logs and CSV/JSON
results are in each regression directory. The initial reset-time unique-case
warning in `axi_inval_filter.sv` remains visible; no simulator errors or traps
were accepted as passing results.

The fix is committed in Ara on top of the stated base revision. Bender.lock is
unchanged; the protected build consumes the existing prepared checkout, and the
parent project carries the portable patch. No FPGA synthesis
or programming was run. An FPGA must be rebuilt to include the RTL fix; the
existing bitstream is not updated by these simulations.
