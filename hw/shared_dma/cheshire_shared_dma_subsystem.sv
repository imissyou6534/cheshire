// SPDX-License-Identifier: SHL-0.51
module cheshire_shared_dma_subsystem #(
  parameter int unsigned NumTiles = 4,
  parameter int unsigned NumDmas = 2,
  parameter int unsigned AxiAddrWidth = 32,
  parameter int unsigned AxiDataWidth = 64,
  parameter int unsigned DmaAxiDataWidth = 0,
  parameter int unsigned SharedAxiDataWidth = 0,
  parameter int unsigned AxiIdWidth = 4,
  parameter int unsigned AxiSlvIdWidth = 4,
  parameter int unsigned AxiUserWidth = 1,
  parameter int unsigned AxiUserAmoMsb = AxiUserWidth-1,
  parameter int unsigned AxiUserAmoLsb = 0,
  parameter int unsigned AxiLocalSourceWidth = 0,
  parameter int unsigned AxiLocalSourceLsb = 0,
  parameter int unsigned JobFifoDepth = 2,
  parameter int unsigned CompletionDepth = 4,
  parameter int unsigned NumAxInFlight = 16,
  parameter int unsigned MemSysDepth = 8,
  parameter bit RAWCouplingAvail = 1,
  parameter logic [63:0] MemStart = 64'h80000000,
  parameter logic [63:0] MemEnd = 64'h100000000,
  parameter type tile_ctrl_req_t = logic,
  parameter type tile_ctrl_rsp_t = logic,
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic,
  parameter type ddr_req_t = logic,
  parameter type ddr_rsp_t = logic
) (
  input logic clk_i, rst_ni, testmode_i,
  input tile_ctrl_req_t [NumTiles-1:0] tile_ctrl_req_i,
  output tile_ctrl_rsp_t [NumTiles-1:0] tile_ctrl_rsp_o,
  input axi_req_t [NumTiles-1:0] tile_mem_req_i,
  output axi_rsp_t [NumTiles-1:0] tile_mem_rsp_o,
  output ddr_req_t ddr_req_o,
  input ddr_rsp_t ddr_rsp_i,
  output logic [NumTiles-1:0] dma_irq_o
);
  `include "axi/typedef.svh"
  localparam int unsigned DmaDataWidth = DmaAxiDataWidth == 0 ? AxiDataWidth : DmaAxiDataWidth;
  localparam int unsigned SharedDataWidth =
    SharedAxiDataWidth == 0 ? AxiDataWidth : SharedAxiDataWidth;
  typedef logic [AxiAddrWidth-1:0] addr_t;
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef logic [AxiUserWidth-1:0] user_t;
  typedef logic [AxiDataWidth-1:0] tile_data_t;
  typedef logic [AxiDataWidth/8-1:0] tile_strb_t;
  typedef logic [DmaDataWidth-1:0] dma_data_t;
  typedef logic [DmaDataWidth/8-1:0] dma_strb_t;
  typedef logic [SharedDataWidth-1:0] shared_data_t;
  typedef logic [SharedDataWidth/8-1:0] shared_strb_t;
  `AXI_TYPEDEF_ALL(tile, addr_t, id_t, tile_data_t, tile_strb_t, user_t)
  `AXI_TYPEDEF_ALL(dma, addr_t, id_t, dma_data_t, dma_strb_t, user_t)
  `AXI_TYPEDEF_ALL(shared, addr_t, id_t, shared_data_t, shared_strb_t, user_t)
  dma_req_t [NumDmas-1:0] dma_req;
  dma_resp_t [NumDmas-1:0] dma_rsp;
  shared_req_t [NumTiles+NumDmas-1:0] masters_req;
  shared_resp_t [NumTiles+NumDmas-1:0] masters_rsp;
  // Convert each physical source before arbitration, retaining its local ID and USER.
  for (genvar t=0;t<NumTiles;t++) begin : gen_tile_width
    axi_dw_converter #(
      .AxiSlvPortDataWidth(AxiDataWidth), .AxiMstPortDataWidth(SharedDataWidth),
      .AxiMaxReads(NumAxInFlight), .AxiAddrWidth(AxiAddrWidth), .AxiIdWidth(AxiIdWidth),
      .aw_chan_t(tile_aw_chan_t), .ar_chan_t(tile_ar_chan_t), .b_chan_t(tile_b_chan_t),
      .slv_w_chan_t(tile_w_chan_t), .slv_r_chan_t(tile_r_chan_t),
      .mst_w_chan_t(shared_w_chan_t), .mst_r_chan_t(shared_r_chan_t),
      .axi_slv_req_t(axi_req_t), .axi_slv_resp_t(axi_rsp_t),
      .axi_mst_req_t(shared_req_t), .axi_mst_resp_t(shared_resp_t)
    ) i_converter (
      .clk_i, .rst_ni, .slv_req_i(tile_mem_req_i[t]), .slv_resp_o(tile_mem_rsp_o[t]),
      .mst_req_o(masters_req[t]), .mst_resp_i(masters_rsp[t])
    );
  end
  for (genvar d=0;d<NumDmas;d++) begin : gen_dma_width
    axi_dw_converter #(
      .AxiSlvPortDataWidth(DmaDataWidth), .AxiMstPortDataWidth(SharedDataWidth),
      .AxiMaxReads(NumAxInFlight), .AxiAddrWidth(AxiAddrWidth), .AxiIdWidth(AxiIdWidth),
      .aw_chan_t(dma_aw_chan_t), .ar_chan_t(dma_ar_chan_t), .b_chan_t(dma_b_chan_t),
      .slv_w_chan_t(dma_w_chan_t), .slv_r_chan_t(dma_r_chan_t),
      .mst_w_chan_t(shared_w_chan_t), .mst_r_chan_t(shared_r_chan_t),
      .axi_slv_req_t(dma_req_t), .axi_slv_resp_t(dma_resp_t),
      .axi_mst_req_t(shared_req_t), .axi_mst_resp_t(shared_resp_t)
    ) i_converter (
      .clk_i, .rst_ni, .slv_req_i(dma_req[d]), .slv_resp_o(dma_rsp[d]),
      .mst_req_o(masters_req[NumTiles+d]), .mst_resp_i(masters_rsp[NumTiles+d])
    );
  end
  shared_dma_pool #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .AxiAddrWidth(AxiAddrWidth),
    .AxiDataWidth(DmaDataWidth), .CtrlAxiDataWidth(AxiDataWidth),
    .AxiIdWidth(AxiIdWidth), .AxiSlvIdWidth(AxiSlvIdWidth),
    .AxiUserWidth(AxiUserWidth), .JobFifoDepth(JobFifoDepth), .CompletionDepth(CompletionDepth),
    .NumAxInFlight(NumAxInFlight), .MemSysDepth(MemSysDepth), .RAWCouplingAvail(RAWCouplingAvail),
    .MemStart(MemStart), .MemEnd(MemEnd), .tile_ctrl_req_t(tile_ctrl_req_t),
    .tile_ctrl_rsp_t(tile_ctrl_rsp_t), .axi_req_t(dma_req_t), .axi_rsp_t(dma_resp_t)
  ) i_pool (
    .clk_i, .rst_ni, .testmode_i, .tile_ctrl_req_i, .tile_ctrl_rsp_o,
    .dma_axi_req_o(dma_req), .dma_axi_rsp_i(dma_rsp), .dma_irq_o
  );
  global_ddr_fabric #(
    .NumMasters(NumTiles+NumDmas), .AxiAddrWidth(AxiAddrWidth), .AxiDataWidth(SharedDataWidth),
    .AxiIdWidth(AxiIdWidth), .AxiUserWidth(AxiUserWidth),
    .AxiUserAmoMsb(AxiUserAmoMsb), .AxiUserAmoLsb(AxiUserAmoLsb),
    .AxiLocalSourceWidth(AxiLocalSourceWidth), .AxiLocalSourceLsb(AxiLocalSourceLsb),
    .MaxTransactions(NumAxInFlight), .MemStart(MemStart), .MemEnd(MemEnd),
    .axi_req_t(shared_req_t), .axi_rsp_t(shared_resp_t),
    .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t)
  ) i_fabric (
    .clk_i, .rst_ni, .testmode_i, .masters_req_i(masters_req), .masters_rsp_o(masters_rsp),
    .ddr_req_o, .ddr_rsp_i
  );
  initial begin
    assert($bits(tile_mem_req_i[0].w.data)==AxiDataWidth &&
      $bits(tile_mem_rsp_o[0].r.data)==AxiDataWidth &&
      $bits(tile_ctrl_req_i[0].w.data)==AxiDataWidth &&
      $bits(tile_ctrl_rsp_o[0].r.data)==AxiDataWidth)
      else $fatal(1,"Tile control and memory ports must match AxiDataWidth");
    assert($bits(ddr_req_o.w.data)==SharedDataWidth &&
      $bits(ddr_rsp_i.r.data)==SharedDataWidth)
      else $fatal(1,"DDR port types must match the resolved SharedAxiDataWidth");
  end
endmodule
