// SPDX-License-Identifier: SHL-0.51
module multi_tile_top #(
  parameter int unsigned NumTiles = 4,
  parameter int unsigned NumDmas = 2,
  parameter int unsigned DmaAxiDataWidth = 0,
  parameter int unsigned SharedAxiDataWidth = 0,
  parameter cheshire_pkg::cheshire_cfg_t Cfg =
    cheshire_shared_dma_cfg_pkg::tile_cfg(cheshire_pkg::DefaultCfg),
  parameter int unsigned CompletionDepth = 4,
  parameter logic [63:0] TileBootStride = 0,
  parameter type ddr_req_t = logic,
  parameter type ddr_rsp_t = logic,
  parameter type ext_mst_req_t = logic,
  parameter type ext_mst_rsp_t = logic
) (
  input logic clk_i, rst_ni, testmode_i, rtc_i,
  input logic [NumTiles-1:0][1:0] boot_mode_i,
  input logic [NumTiles-1:0] uart_rx_i,
  output logic [NumTiles-1:0] uart_tx_o,
  input logic [NumTiles-1:0] jtag_tck_i, jtag_trst_ni, jtag_tms_i, jtag_tdi_i,
  output logic [NumTiles-1:0] jtag_tdo_o,
  output logic [NumTiles-1:0] dma_irq_o,
  output ddr_req_t ddr_req_o,
  input ddr_rsp_t ddr_rsp_i,
  input ext_mst_req_t [NumTiles-1:0][cheshire_pkg::iomsb(Cfg.AxiExtNumMst):0] tile_ext_mst_req_i,
  output ext_mst_rsp_t [NumTiles-1:0][cheshire_pkg::iomsb(Cfg.AxiExtNumMst):0] tile_ext_mst_rsp_o
);
  `include "cheshire/typedef.svh"
  `CHESHIRE_TYPEDEF_ALL(tile_, Cfg)
  tile_axi_slv_req_t [NumTiles-1:0][0:0] ctrl_req;
  tile_axi_slv_rsp_t [NumTiles-1:0][0:0] ctrl_rsp;
  tile_axi_llc_req_t [NumTiles-1:0] mem_req;
  tile_axi_llc_rsp_t [NumTiles-1:0] mem_rsp;
  function automatic cheshire_pkg::cheshire_cfg_t tile_boot_cfg(input int unsigned tile);
    cheshire_pkg::cheshire_cfg_t cfg;
    cfg=Cfg;
    if (!Cfg.Bootrom) cfg.PlatformRom=Cfg.PlatformRom+TileBootStride*64'(tile);
    return cfg;
  endfunction
  for (genvar t=0;t<NumTiles;t++) begin : gen_tiles
    localparam cheshire_pkg::cheshire_cfg_t TileCfg=tile_boot_cfg(t);
    tile_axi_mst_req_t [cheshire_pkg::iomsb(Cfg.AxiExtNumMst):0] ext_req;
    tile_axi_mst_rsp_t [cheshire_pkg::iomsb(Cfg.AxiExtNumMst):0] ext_rsp;
    if (Cfg.AxiExtNumMst > 0) begin : gen_ext_master
      assign ext_req = tile_ext_mst_req_i[t];
      assign tile_ext_mst_rsp_o[t] = ext_rsp;
      initial assert($bits(ext_mst_req_t) == $bits(tile_axi_mst_req_t) &&
        $bits(ext_mst_rsp_t) == $bits(tile_axi_mst_rsp_t))
        else $fatal(1, "external tile master types must match the tile configuration");
    end else begin : gen_no_ext_master
      assign ext_req = '0;
      assign tile_ext_mst_rsp_o[t] = '0;
    end
    cheshire_soc #(
      .Cfg(TileCfg), .LlcSharedAtomics(1'b1),
      .axi_ext_llc_req_t(tile_axi_llc_req_t), .axi_ext_llc_rsp_t(tile_axi_llc_rsp_t),
      .axi_ext_mst_req_t(tile_axi_mst_req_t), .axi_ext_mst_rsp_t(tile_axi_mst_rsp_t),
      .axi_ext_slv_req_t(tile_axi_slv_req_t), .axi_ext_slv_rsp_t(tile_axi_slv_rsp_t),
      .reg_ext_req_t(tile_reg_req_t), .reg_ext_rsp_t(tile_reg_rsp_t)
    ) i_soc (
      .clk_i, .rst_ni, .test_mode_i(testmode_i), .boot_mode_i(boot_mode_i[t]), .rtc_i,
      .axi_llc_mst_req_o(mem_req[t]), .axi_llc_mst_rsp_i(mem_rsp[t]),
      .axi_ext_mst_req_i(ext_req), .axi_ext_mst_rsp_o(ext_rsp),
      .axi_ext_slv_req_o(ctrl_req[t]), .axi_ext_slv_rsp_i(ctrl_rsp[t]),
      .reg_ext_slv_req_o(), .reg_ext_slv_rsp_i('0),
      .intr_ext_i(dma_irq_o[t]), .intr_ext_o(), .xeip_ext_o(), .mtip_ext_o(), .msip_ext_o(),
      .dbg_active_o(), .dbg_ext_req_o(), .dbg_ext_unavail_i('0),
      .jtag_tck_i(jtag_tck_i[t]), .jtag_trst_ni(jtag_trst_ni[t]), .jtag_tms_i(jtag_tms_i[t]),
      .jtag_tdi_i(jtag_tdi_i[t]), .jtag_tdo_o(jtag_tdo_o[t]), .jtag_tdo_oe_o(),
      .uart_tx_o(uart_tx_o[t]), .uart_rx_i(uart_rx_i[t]), .uart_rts_no(), .uart_dtr_no(),
      .uart_cts_ni(1'b0), .uart_dsr_ni(1'b0), .uart_dcd_ni(1'b0), .uart_rin_ni(1'b1),
      .i2c_sda_o(), .i2c_sda_i(1'b1), .i2c_sda_en_o(), .i2c_scl_o(),
      .i2c_scl_i(1'b1), .i2c_scl_en_o(), .spih_sck_o(), .spih_sck_en_o(),
      .spih_csb_o(), .spih_csb_en_o(), .spih_sd_o(), .spih_sd_en_o(), .spih_sd_i('1),
      .gpio_i('0), .gpio_o(), .gpio_en_o(), .slink_rcv_clk_i('0), .slink_rcv_clk_o(),
      .slink_i('0), .slink_o(), .vga_hsync_o(), .vga_vsync_o(),
      .vga_red_o(), .vga_green_o(), .vga_blue_o(), .usb_clk_i(clk_i), .usb_rst_ni(rst_ni),
      .usb_dm_i('0), .usb_dm_o(), .usb_dm_oe_o(), .usb_dp_i('0), .usb_dp_o(), .usb_dp_oe_o()
    );
  end
  cheshire_shared_dma_subsystem #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .AxiAddrWidth(Cfg.AddrWidth),
    .AxiDataWidth(Cfg.AxiDataWidth), .AxiIdWidth($bits(tile_axi_llc_id_t)),
    .DmaAxiDataWidth(DmaAxiDataWidth), .SharedAxiDataWidth(SharedAxiDataWidth),
    .AxiSlvIdWidth($bits(tile_axi_slv_id_t)), .AxiUserWidth(Cfg.AxiUserWidth),
    .AxiUserAmoMsb(Cfg.AxiUserAmoMsb), .AxiUserAmoLsb(Cfg.AxiUserAmoLsb),
    .AxiLocalSourceWidth($bits(tile_axi_slv_id_t)-Cfg.AxiMstIdWidth),
    .AxiLocalSourceLsb(Cfg.AxiMstIdWidth),
    .JobFifoDepth(Cfg.DmaJobFifoDepth), .CompletionDepth(CompletionDepth),
    .NumAxInFlight(Cfg.DmaNumAxInFlight), .MemSysDepth(Cfg.DmaMemSysDepth),
    .RAWCouplingAvail(Cfg.DmaRAWCouplingAvail),
    .MemStart(Cfg.LlcOutRegionStart), .MemEnd(Cfg.LlcOutRegionEnd),
    .tile_ctrl_req_t(tile_axi_slv_req_t), .tile_ctrl_rsp_t(tile_axi_slv_rsp_t),
    .axi_req_t(tile_axi_llc_req_t), .axi_rsp_t(tile_axi_llc_rsp_t),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t)
  ) i_dma_subsystem (
    .clk_i, .rst_ni, .testmode_i, .tile_ctrl_req_i(ctrl_req), .tile_ctrl_rsp_o(ctrl_rsp),
    .tile_mem_req_i(mem_req), .tile_mem_rsp_o(mem_rsp), .ddr_req_o, .ddr_rsp_i, .dma_irq_o
  );
  initial begin
    assert(NumTiles>0 && NumDmas>0);
    assert(TileBootStride==0 || !Cfg.Bootrom);
    assert(!Cfg.Dma && Cfg.LlcOutConnect && Cfg.AxiExtNumSlv==1);
    assert(!Cfg.LlcNotBypass || Cfg.LlcSpmPrivate);
    assert(Cfg.RegExtNumSlv==0 && Cfg.NumExtInIntrs==1);
    assert(!Cfg.Usb && !Cfg.SerialLink && !Cfg.Vga && !Cfg.I2c && !Cfg.SpiHost && !Cfg.Gpio);
  end
endmodule
