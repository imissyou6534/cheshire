// SPDX-License-Identifier: SHL-0.51
module cheshire_shared_dma_subsystem #(
  parameter int unsigned NumTiles = 4,
  parameter int unsigned NumDmas = 2,
  parameter int unsigned AxiAddrWidth = 32,
  parameter int unsigned AxiDataWidth = 64,
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
  axi_req_t [NumDmas-1:0] dma_req;
  axi_rsp_t [NumDmas-1:0] dma_rsp;
  axi_req_t [NumTiles+NumDmas-1:0] masters_req;
  axi_rsp_t [NumTiles+NumDmas-1:0] masters_rsp;
  assign masters_req={dma_req,tile_mem_req_i};
  assign {dma_rsp,tile_mem_rsp_o}=masters_rsp;
  shared_dma_pool #(
    .NumTiles(NumTiles), .NumDmas(NumDmas), .AxiAddrWidth(AxiAddrWidth),
    .AxiDataWidth(AxiDataWidth), .AxiIdWidth(AxiIdWidth), .AxiSlvIdWidth(AxiSlvIdWidth),
    .AxiUserWidth(AxiUserWidth), .JobFifoDepth(JobFifoDepth), .CompletionDepth(CompletionDepth),
    .NumAxInFlight(NumAxInFlight), .MemSysDepth(MemSysDepth), .RAWCouplingAvail(RAWCouplingAvail),
    .MemStart(MemStart), .MemEnd(MemEnd), .tile_ctrl_req_t(tile_ctrl_req_t),
    .tile_ctrl_rsp_t(tile_ctrl_rsp_t), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t)
  ) i_pool (
    .clk_i, .rst_ni, .testmode_i, .tile_ctrl_req_i, .tile_ctrl_rsp_o,
    .dma_axi_req_o(dma_req), .dma_axi_rsp_i(dma_rsp), .dma_irq_o
  );
  global_ddr_fabric #(
    .NumMasters(NumTiles+NumDmas), .AxiAddrWidth(AxiAddrWidth), .AxiDataWidth(AxiDataWidth),
    .AxiIdWidth(AxiIdWidth), .AxiUserWidth(AxiUserWidth),
    .AxiUserAmoMsb(AxiUserAmoMsb), .AxiUserAmoLsb(AxiUserAmoLsb),
    .AxiLocalSourceWidth(AxiLocalSourceWidth), .AxiLocalSourceLsb(AxiLocalSourceLsb),
    .MaxTransactions(NumAxInFlight), .MemStart(MemStart), .MemEnd(MemEnd),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t), .ddr_req_t(ddr_req_t), .ddr_rsp_t(ddr_rsp_t)
  ) i_fabric (
    .clk_i, .rst_ni, .testmode_i, .masters_req_i(masters_req), .masters_rsp_o(masters_rsp),
    .ddr_req_o, .ddr_rsp_i
  );
endmodule
