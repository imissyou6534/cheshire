// SPDX-License-Identifier: SHL-0.51
`include "phy_definitions.svh"
module multi_tile_rom_top_xilinx #(
  parameter int unsigned NumTiles = `ifdef CHS_NUM_TILES `CHS_NUM_TILES `else 1 `endif,
  parameter int unsigned NumDmas = `ifdef CHS_NUM_DMAS `CHS_NUM_DMAS `else 1 `endif
) (
  input logic sys_clk_p,
  input logic sys_clk_n,
  input logic sys_reset,
  input logic jtag_tck_i,
  input logic jtag_tms_i,
  input logic jtag_tdi_i,
  output logic jtag_tdo_o,
  `DDR4_INTF(1, 8, 64, 8)
  input logic uart_rx_i,
  output logic uart_tx_o
);
  // ROM content is selected by the rom_autoboot Bender target, not by VIO.
  (* keep_hierarchy = "yes" *)
  multi_tile_top_xilinx #(.NumTiles(NumTiles), .NumDmas(NumDmas)) i_platform (.*);
endmodule
