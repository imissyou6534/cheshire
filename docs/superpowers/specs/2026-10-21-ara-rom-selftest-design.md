# Ara ROM UART self-test

Run a deterministic Ara instruction self-test using the existing unified ROM/SPM
loader. No external program loading is used. Keep the complete ROM within 16 KiB
and preserve the prepared dependency repositories and hardware sources.

Each arithmetic case prints its instruction, SEW/LMUL, actual operands, result
read from memory, independent scalar expectation and PASS/FAIL for each displayed
element. Integer values use hexadecimal bit patterns; floating-point cases use
exactly representable inputs and print numeric values and IEEE bit patterns.
Print and flush START before submitting each case so a stalled instruction is
identifiable. Failures contribute to a nonzero main return and final summary.

Cover integer arithmetic/logic/shifts/comparisons, mask/merge, slide/gather,
reduction and scalar/vector moves; contiguous 8/16/32/64-bit loads/stores,
strided/indexed loads/stores, multi-strip processing and LMUL=2, tail/mask
preservation, and FP32/FP64 arithmetic. Use small printed examples plus a larger
checked load/store workload. This is representative coverage, not ISA compliance.

Disable scalar auto-vectorization for reference code, use the project's CVA6
writeback handoff before disabling D-cache, and fence vector stores before scalar
readback. Keep test buffers aligned in private SPM. Avoid mixing cached aliases.

An independent Python oracle produces exact expected UART bytes and a fixed
summary structure for external AXI readback. The supported multi-tile runner
checks ROM startup, return value, UART bytes, summary memory and Ara requests
with the FPGA wide profile. A deliberately corrupted expectation must fail.

User accepted the direction by adding the requirement to print actual operands,
results and expectations. Work is performed in the requested server checkout;
new files are mirrored locally without changing unrelated local work.
