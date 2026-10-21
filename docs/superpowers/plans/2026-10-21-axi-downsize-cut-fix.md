# AXI Downsize Boundary Isolation

Goal: eliminate the two LUTLP-1 loops reported at the 128-to-64 peripheral
and debug interfaces without changing widths, address maps, or dependencies.
The user approved adding full AXI cuts at these boundaries.

- [x] Verify the failing baseline using the saved full-design DRC and an
  isolated Vivado probe with direct and registered boundary configurations.
- [x] In `hw/cheshire_soc.sv`, add intermediate peripheral/debug request and
  response pairs after the converters, and instantiate one non-bypassed
  `axi_cut` per boundary with the existing narrow-channel types.
- [x] Verify isolated Vivado LUTLP-1 results and synthesize the same cut
  implementation. Preserve all old FPGA build results.
- [x] Run fresh wide/legacy CVA6 system regressions and the FPGA-wrapper
  JTAG/SBA/UART/DMA smoke using protected dependency source lists.
- [x] Independently review the RTL diff, check dependency state unchanged,
  and document results and residual full-place-and-route verification.

The historical failed complete FPGA build remains intact. Tests create new
directories under `/tmp`. This repair does not waive DRC rules, change clock
constraints, alter FIFO internals, or overwrite old bitstreams.
