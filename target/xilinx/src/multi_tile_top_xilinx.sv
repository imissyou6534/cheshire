// SPDX-License-Identifier: SHL-0.51
`include "cheshire/typedef.svh"
`include "phy_definitions.svh"

module multi_tile_top_xilinx import cheshire_pkg::*; #(
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
  function automatic cheshire_cfg_t fpga_cfg();
    cheshire_cfg_t cfg = DefaultCfg;
    cfg.RtcFreq = 1000000;
`ifdef ARA
    cfg.Ara = 1;
    cfg.AraNrLanes = `ifdef NR_LANES `NR_LANES `else 2 `endif;
    cfg.AraVLEN = `ifdef VLEN `VLEN `else 2048 `endif;
`endif
`ifdef FFT_ACCEL
    cfg.Fft = 1;
`endif
    return cheshire_shared_dma_cfg_pkg::private_spm_tile_cfg(cfg);
  endfunction

  localparam cheshire_cfg_t FPGACfg = fpga_cfg();
  `CHESHIRE_TYPEDEF_ALL(tile_, FPGACfg)
  typedef logic [$bits(tile_axi_llc_id_t)+$clog2(NumTiles+NumDmas)-1:0] ddr_id_t;
  `CHESHIRE_TYPEDEF_AXI_CT(ddr, tile_addr_t, ddr_id_t,
    tile_axi_data_t, tile_axi_strb_t, tile_axi_user_t)
  ddr_req_t ddr_req;
  ddr_rsp_t ddr_rsp;
  wire sys_clk, soc_clk, clocks_locked;
  logic sys_rst, rst_n;
  logic jtag_rst_n;
  logic vio_reset;
  logic [1:0] unused_vio_boot_mode;
  logic unused_vio_boot_select;

  IBUFDS #(.IBUF_LOW_PWR("FALSE")) i_bufds_sys_clk (
    .I(sys_clk_p), .IB(sys_clk_n), .O(sys_clk)
  );
  clkwiz i_clkwiz (
    .clk_in1(sys_clk), .reset(1'b0), .locked(clocks_locked),
    .clk_50(soc_clk), .clk_48(), .clk_20(), .clk_10()
  );
  // SPI/I2C boot devices are absent: keep every tile in passive ROM boot.
  vio i_vio (
    .clk(soc_clk), .probe_out0(vio_reset),
    .probe_out1(unused_vio_boot_mode), .probe_out2(unused_vio_boot_select)
  );
  assign sys_rst = sys_reset | vio_reset | !clocks_locked;
  rstgen i_rstgen (
    .clk_i(soc_clk), .rst_ni(!sys_rst), .test_mode_i(1'b0),
    .rst_no(rst_n), .init_no()
  );
  rstgen i_jtag_rstgen (
    .clk_i(jtag_tck_i), .rst_ni(rst_n), .test_mode_i(1'b0),
    .rst_no(jtag_rst_n), .init_no()
  );

  logic [4:0] rtc_count;
  logic rtc;
  always_ff @(posedge soc_clk or negedge rst_n) begin
    if (!rst_n) begin
      rtc_count <= '0;
      rtc <= 0;
    end else if (rtc_count == 24) begin
      rtc_count <= '0;
      rtc <= !rtc;
    end else rtc_count <= rtc_count + 1'b1;
  end

  logic [NumTiles-1:0] tile_uart_rx, tile_uart_tx;
  logic [NumTiles-1:0] tile_jtag_tdi, tile_jtag_tdo;
  logic [NumTiles-1:0] dma_irq;
  tile_axi_mst_req_t [NumTiles-1:0][iomsb(FPGACfg.AxiExtNumMst):0] ext_req;
  tile_axi_mst_rsp_t [NumTiles-1:0][iomsb(FPGACfg.AxiExtNumMst):0] ext_rsp;
  assign ext_req = '0;
  assign uart_tx_o = tile_uart_tx[0];
  assign jtag_tdo_o = tile_jtag_tdo[NumTiles-1];
  for (genvar t=0; t<NumTiles; t++) begin : gen_board_links
    if (t == 0) begin : gen_first
      assign tile_uart_rx[t] = uart_rx_i;
      assign tile_jtag_tdi[t] = jtag_tdi_i;
    end else begin : gen_rest
      assign tile_uart_rx[t] = 1'b1;
      assign tile_jtag_tdi[t] = tile_jtag_tdo[t-1];
    end
  end

  multi_tile_top #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .Cfg(FPGACfg),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t),
    .ext_mst_req_t(tile_axi_mst_req_t), .ext_mst_rsp_t(tile_axi_mst_rsp_t)
  ) i_multi_tile (
    .clk_i(soc_clk), .rst_ni(rst_n), .testmode_i(1'b0), .rtc_i(rtc),
    .boot_mode_i('0), .uart_rx_i(tile_uart_rx), .uart_tx_o(tile_uart_tx),
    .jtag_tck_i({NumTiles{jtag_tck_i}}), .jtag_trst_ni({NumTiles{jtag_rst_n}}),
    .jtag_tms_i({NumTiles{jtag_tms_i}}), .jtag_tdi_i(tile_jtag_tdi),
    .jtag_tdo_o(tile_jtag_tdo), .dma_irq_o(dma_irq),
    .tile_ext_mst_req_i(ext_req), .tile_ext_mst_rsp_o(ext_rsp),
    .ddr_req_o(ddr_req), .ddr_rsp_i(ddr_rsp)
  );

  dram_wrapper_xilinx #(
    .SyncDdrReset(1'b1),
    .axi_soc_aw_chan_t(ddr_aw_chan_t), .axi_soc_w_chan_t(ddr_w_chan_t),
    .axi_soc_b_chan_t(ddr_b_chan_t), .axi_soc_ar_chan_t(ddr_ar_chan_t),
    .axi_soc_r_chan_t(ddr_r_chan_t), .axi_soc_req_t(ddr_req_t), .axi_soc_resp_t(ddr_rsp_t),
    .Ddr4CsNWidth(1), .Ddr4DmDbiNWidth(8), .Ddr4DqWidth(64), .Ddr4DqsWidth(8)
  ) i_dram_wrapper (
    .sys_rst_i(sys_rst), .soc_resetn_i(rst_n), .soc_clk_i(soc_clk), .dram_clk_i(sys_clk),
    .soc_req_i(ddr_req), .soc_rsp_o(ddr_rsp), .*
  );

  initial begin
`ifndef TARGET_VCU118
    $fatal(1,"multi_tile_top_xilinx currently supports VCU118 only");
`endif
    assert(NumTiles > 0 && NumTiles <= 64 && NumDmas > 0 && NumDmas <= 65536);
    assert(FPGACfg.Bootrom && FPGACfg.LlcSpmPrivate && FPGACfg.LlcNotBypass);
  end
endmodule
