// SPDX-License-Identifier: SHL-0.51
module shared_dma_pool import cheshire_dma_pkg::*; #(
  parameter int unsigned NumTiles = 4,
  parameter int unsigned NumDmas = 2,
  parameter int unsigned AxiAddrWidth = 32,
  parameter int unsigned AxiDataWidth = 64,
  parameter int unsigned AxiIdWidth = 4,
  parameter int unsigned AxiSlvIdWidth = 4,
  parameter int unsigned AxiUserWidth = 1,
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
  parameter type axi_rsp_t = logic
) (
  input logic clk_i, rst_ni, testmode_i,
  input tile_ctrl_req_t [NumTiles-1:0] tile_ctrl_req_i,
  output tile_ctrl_rsp_t [NumTiles-1:0] tile_ctrl_rsp_o,
  output axi_req_t [NumDmas-1:0] dma_axi_req_o,
  input axi_rsp_t [NumDmas-1:0] dma_axi_rsp_i,
  output logic [NumTiles-1:0] dma_irq_o
);
  `include "idma/typedef.svh"
  localparam int NumDim = 2;
  localparam int TileWidth = (NumTiles>1) ? $clog2(NumTiles) : 1;
  typedef logic [AxiAddrWidth-1:0] addr_t;
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef logic [31:0] len_t;
  `IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, len_t)
  `IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
  `IDMA_TYPEDEF_FULL_ND_REQ_T(idma_nd_req_t, idma_req_t, len_t, len_t)
  typedef struct packed { logic [31:0] job_id; idma_nd_req_t nd_req; } job_t;
  job_t [NumTiles-1:0] submit_job, tile_job;
  job_t [NumDmas-1:0] engine_job;
  logic [NumTiles-1:0] submit_valid, submit_ready, tile_valid, tile_ready, tile_active;
  logic [NumDmas-1:0] engine_valid, engine_ready, engine_active;
  logic [NumDmas-1:0][TileWidth-1:0] engine_tile, completion_tile;
  completion_t [NumDmas-1:0] engine_comp;
  logic [NumDmas-1:0] comp_valid, comp_ready, comp_fire;
  completion_t [NumTiles-1:0] tile_comp;
  logic [NumTiles-1:0] tile_comp_valid, tile_comp_ready;
  for (genvar t=0;t<NumTiles;t++) begin : gen_tiles
    dma_tile_frontend #(
      .AxiAddrWidth(AxiAddrWidth), .AxiDataWidth(AxiDataWidth),
      .AxiSlvIdWidth(AxiSlvIdWidth), .AxiUserWidth(AxiUserWidth),
      .CompletionDepth(CompletionDepth), .MemStart(MemStart), .MemEnd(MemEnd),
      .axi_req_t(tile_ctrl_req_t), .axi_rsp_t(tile_ctrl_rsp_t), .job_t(job_t)
    ) i_frontend (
      .clk_i, .rst_ni, .testmode_i, .axi_req_i(tile_ctrl_req_i[t]),
      .axi_rsp_o(tile_ctrl_rsp_o[t]), .job_o(submit_job[t]), .job_valid_o(submit_valid[t]),
      .job_ready_i(submit_ready[t]), .completion_i(tile_comp[t]),
      .completion_valid_i(tile_comp_valid[t]), .completion_ready_o(tile_comp_ready[t]),
      .tile_active_i(tile_active[t]), .irq_o(dma_irq_o[t])
    );
    stream_fifo #(.DEPTH(JobFifoDepth), .T(job_t)) i_jobs (
      .clk_i, .rst_ni, .testmode_i, .flush_i(1'b0), .usage_o(),
      .data_i(submit_job[t]), .valid_i(submit_valid[t]), .ready_o(submit_ready[t]),
      .data_o(tile_job[t]), .valid_o(tile_valid[t]), .ready_i(tile_ready[t])
    );
  end
  dma_job_scheduler #(.NumTiles(NumTiles), .NumDmas(NumDmas), .job_t(job_t)) i_scheduler (
    .clk_i, .rst_ni, .tile_job_i(tile_job), .tile_valid_i(tile_valid),
    .tile_ready_o(tile_ready), .engine_job_o(engine_job), .engine_tile_o(engine_tile),
    .engine_valid_o(engine_valid), .engine_ready_i(engine_ready),
    .completion_fire_i(comp_fire), .completion_tile_i(completion_tile),
    .tile_active_o(tile_active)
  );
  for (genvar d=0;d<NumDmas;d++) begin : gen_engines
    dma_engine_wrap #(
      .AxiAddrWidth(AxiAddrWidth), .AxiDataWidth(AxiDataWidth), .AxiIdWidth(AxiIdWidth),
      .AxiUserWidth(AxiUserWidth), .NumAxInFlight(NumAxInFlight),
      .MemSysDepth(MemSysDepth), .RAWCouplingAvail(RAWCouplingAvail), .EngineId(d),
      .TileWidth(TileWidth), .job_t(job_t), .idma_req_t(idma_req_t),
      .idma_rsp_t(idma_rsp_t), .idma_nd_req_t(idma_nd_req_t),
      .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t)
    ) i_engine (
      .clk_i, .rst_ni, .testmode_i, .job_i(engine_job[d]), .tile_i(engine_tile[d]),
      .job_valid_i(engine_valid[d]), .job_ready_o(engine_ready[d]),
      .completion_o(engine_comp[d]), .completion_tile_o(completion_tile[d]),
      .completion_valid_o(comp_valid[d]), .completion_ready_i(comp_ready[d]),
      .axi_req_o(dma_axi_req_o[d]), .axi_rsp_i(dma_axi_rsp_i[d]), .active_o(engine_active[d])
    );
  end
  // With one active job per tile, engines cannot contend for the same completion FIFO.
  always_comb begin
    tile_comp='0; tile_comp_valid='0; comp_ready='0;
    for (int d=0;d<NumDmas;d++) begin
      if (comp_valid[d]) begin
        tile_comp[completion_tile[d]]=engine_comp[d];
        tile_comp_valid[completion_tile[d]]=1;
        comp_ready[d]=tile_comp_ready[completion_tile[d]];
      end
    end
  end
  assign comp_fire=comp_valid & comp_ready;
  initial begin
    assert(NumTiles > 0 && NumDmas > 0 && NumDmas <= 65536);
    assert(JobFifoDepth > 0 && CompletionDepth > 0);
  end
  for (genvar a=0;a<NumDmas;a++) begin : gen_owner_assert
    for (genvar b=a+1;b<NumDmas;b++) begin : gen_pair
      assert property (@(posedge clk_i) disable iff (!rst_ni)
        !(engine_active[a] && engine_active[b] && completion_tile[a]==completion_tile[b]));
    end
  end
endmodule
