# Ara VID Repair Plan

Goal: remove unmatched VID ALU traffic and keep VFU accounting consistent,
without changing the existing MASKU datapath or software interface.

The user authorized implementing the repair after reviewing the root cause
and the RISC-V V 1.0 requirements. Work applies to the server's prepared Ara
dependency and Cheshire regression sources; unrelated dependencies stay intact.

- [x] Add a system regression with repeated unmasked VID, masked VID across
  SEW8/16/32/64, VL0/1/3/VLMAX-1/VLMAX, tu/mu and ta/ma, LMUL1/2,
  and neighboring mask instructions. Confirm its failure before the fix.
- [x] Exclude VID from VALU instruction acceptance in `hardware/src/lane/valu.sv`.
- [x] Exclude VID from ALU target/queue accounting in `hardware/src/ara_sequencer.sv`.
  Retain MASKU targeting, operand requests for masked execution, and completion.
- [x] Build fresh legacy and wide system models with the protected source-list
  wrapper. Run the exact previously failing overlap program and new regression
  on both. Observe zero VID ALU results and balanced VMSNE transfers.
- [x] Run Hello/buffer checks and focused dependency-protection unit tests.
- [x] Preserve the exact dependency delta in a main-repository patch and
  document result locations, hashes, known limitations and recovery procedure.

Do not expand queues, drop arbitrary MASKU operands, alter CVA6/router signals,
or disable masked operations. These alternatives do not repair ownership and
would hide or defer the failure. Nonzero-vstart implementation support is not
being expanded in this narrowly scoped repair.
