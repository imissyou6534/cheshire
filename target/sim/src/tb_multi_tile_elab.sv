`timescale 1ns/1ps
`include "cheshire/typedef.svh"
module tb_multi_tile_elab;
  localparam int NumTiles=4, NumDmas=2;
  localparam cheshire_pkg::cheshire_cfg_t Cfg =
    cheshire_shared_dma_cfg_pkg::tile_cfg(cheshire_pkg::DefaultCfg);
  `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)
  typedef logic [$bits(tile_axi_llc_id_t)+$clog2(NumTiles+NumDmas)-1:0] ddr_id_t;
  `CHESHIRE_TYPEDEF_AXI_CT(ddr, tile_addr_t, ddr_id_t,
    tile_axi_data_t, tile_axi_strb_t, tile_axi_user_t)
  logic clk=0;
  always #5 clk=~clk;
  ddr_req_t req;
  multi_tile_top #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .Cfg(Cfg),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t)
  ) dut (
    .clk_i(clk), .rst_ni(1'b0), .testmode_i(1'b0), .rtc_i(1'b0),
    .boot_mode_i('0), .uart_rx_i('1), .uart_tx_o(),
    .jtag_tck_i('0), .jtag_trst_ni('0), .jtag_tms_i('0), .jtag_tdi_i('0),
    .jtag_tdo_o(), .dma_irq_o(), .ddr_req_o(req), .ddr_rsp_i('0)
  );
endmodule
