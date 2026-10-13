// SPDX-License-Identifier: SHL-0.51
module dma_engine_wrap import cheshire_dma_pkg::*; #(
  parameter int unsigned AxiAddrWidth = 32,
  parameter int unsigned AxiDataWidth = 64,
  parameter int unsigned AxiIdWidth = 4,
  parameter int unsigned AxiUserWidth = 1,
  parameter int unsigned NumAxInFlight = 16,
  parameter int unsigned MemSysDepth = 8,
  parameter bit RAWCouplingAvail = 1,
  parameter int unsigned EngineId = 0,
  parameter int unsigned TileWidth = 2,
  parameter type job_t = logic,
  parameter type idma_req_t = logic,
  parameter type idma_rsp_t = logic,
  parameter type idma_nd_req_t = logic,
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic
) (
  input logic clk_i, rst_ni, testmode_i,
  input job_t job_i,
  input logic [TileWidth-1:0] tile_i,
  input logic job_valid_i,
  output logic job_ready_o,
  output completion_t completion_o,
  output logic [TileWidth-1:0] completion_tile_o,
  output logic completion_valid_o,
  input logic completion_ready_i,
  output axi_req_t axi_req_o,
  input axi_rsp_t axi_rsp_i,
  output logic active_o
);
  `include "axi/typedef.svh"
  typedef logic [AxiAddrWidth-1:0] addr_t;
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef logic [AxiUserWidth-1:0] user_t;
  `AXI_TYPEDEF_AW_CHAN_T(aw_t, addr_t, id_t, user_t)
  `AXI_TYPEDEF_AR_CHAN_T(ar_t, addr_t, id_t, user_t)
  typedef struct packed { ar_t ar_chan; } axi_read_meta_t;
  typedef struct packed { axi_read_meta_t axi; } read_meta_t;
  typedef struct packed { aw_t aw_chan; } axi_write_meta_t;
  typedef struct packed { axi_write_meta_t axi; } write_meta_t;
  typedef enum logic [1:0] {Idle, Expand, WaitDone, Report} state_t;
  state_t state_q;
  job_t hold_q;
  logic [TileWidth-1:0] owner_q;
  logic [7:0] error_q, bus_error;
  idma_req_t burst_req;
  idma_rsp_t burst_rsp, nd_rsp;
  logic nd_ready, nd_valid, nd_rsp_valid;
  logic burst_valid, burst_ready, burst_rsp_valid, burst_rsp_ready;
  axi_req_t read_req, write_req;
  axi_rsp_t read_rsp, write_rsp;
  assign job_ready_o = state_q == Idle;
  assign active_o = state_q != Idle;
  assign nd_valid = state_q == Expand;
  assign completion_valid_o = state_q == Report;
  assign completion_tile_o = owner_q;
  assign completion_o = '{job_id:hold_q.job_id,engine_id:16'(EngineId),error_code:error_q};
  // Upstream NO_ERROR_HANDLING drains AXI errors without reporting them. Capture the
  // first error per whole ND job on bus handshakes, including intermediate rows.
  always_comb begin
    bus_error = Success;
    if (axi_rsp_i.b_valid && axi_req_o.b_ready && axi_rsp_i.b.resp[1])
      bus_error = WriteError;
    if (axi_rsp_i.r_valid && axi_req_o.r_ready && axi_rsp_i.r.resp[1])
      bus_error = ReadError;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Idle; hold_q <= '0; owner_q <= '0; error_q <= Success;
    end else begin
      if (state_q inside {Expand,WaitDone} && error_q == Success && bus_error != Success)
        error_q <= bus_error;
      case (state_q)
        Idle: if (job_valid_i) begin
          hold_q <= job_i; owner_q <= tile_i; error_q <= Success; state_q <= Expand;
        end
        Expand, WaitDone: begin
          if (nd_valid && nd_ready) state_q <= WaitDone;
          // A response may coincide with the last request handshake.
          if (nd_rsp_valid) begin
            if (error_q == Success && bus_error == Success && nd_rsp.error)
              error_q <= InvalidJob;
            state_q <= Report;
          end
        end
        Report: if (completion_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end
  end
  idma_nd_midend #(
    .NumDim(2), .addr_t(addr_t), .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t),
    .idma_nd_req_t(idma_nd_req_t), .RepWidths({32'd32,32'd32})
  ) i_nd (
    .clk_i, .rst_ni, .nd_req_i(hold_q.nd_req), .nd_req_valid_i(nd_valid),
    .nd_req_ready_o(nd_ready), .nd_rsp_o(nd_rsp), .nd_rsp_valid_o(nd_rsp_valid),
    .nd_rsp_ready_i(1'b1), .burst_req_o(burst_req), .burst_req_valid_o(burst_valid),
    .burst_req_ready_i(burst_ready), .burst_rsp_i(burst_rsp),
    .burst_rsp_valid_i(burst_rsp_valid), .burst_rsp_ready_o(burst_rsp_ready), .busy_o()
  );
  idma_backend_rw_axi #(
    .CombinedShifter(0), .DataWidth(AxiDataWidth), .AddrWidth(AxiAddrWidth),
    .AxiIdWidth(AxiIdWidth), .UserWidth(AxiUserWidth), .TFLenWidth(32),
    .MaskInvalidData(1), .BufferDepth(3), .RAWCouplingAvail(RAWCouplingAvail),
    .HardwareLegalizer(1), .RejectZeroTransfers(1), .ErrorCap(idma_pkg::NO_ERROR_HANDLING),
    .PrintFifoInfo(0), .NumAxInFlight(NumAxInFlight), .MemSysDepth(MemSysDepth),
    .idma_req_t(idma_req_t), .idma_rsp_t(idma_rsp_t),
    .idma_eh_req_t(idma_pkg::idma_eh_req_t), .idma_busy_t(idma_pkg::idma_busy_t),
    .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .write_meta_channel_t(write_meta_t), .read_meta_channel_t(read_meta_t)
  ) i_backend (
    .clk_i, .rst_ni, .testmode_i, .idma_req_i(burst_req), .req_valid_i(burst_valid),
    .req_ready_o(burst_ready), .idma_rsp_o(burst_rsp), .rsp_valid_o(burst_rsp_valid),
    .rsp_ready_i(burst_rsp_ready), .idma_eh_req_i('0), .eh_req_valid_i(1'b0),
    .eh_req_ready_o(), .axi_read_req_o(read_req), .axi_read_rsp_i(read_rsp),
    .axi_write_req_o(write_req), .axi_write_rsp_i(write_rsp), .busy_o()
  );
  axi_rw_join #(.axi_req_t(axi_req_t), .axi_resp_t(axi_rsp_t)) i_join (
    .clk_i, .rst_ni, .slv_read_req_i(read_req), .slv_read_resp_o(read_rsp),
    .slv_write_req_i(write_req), .slv_write_resp_o(write_rsp),
    .mst_req_o(axi_req_o), .mst_resp_i(axi_rsp_i)
  );
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    nd_valid && !nd_ready |=> nd_valid && $stable(hold_q.nd_req));
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    completion_valid_o && !completion_ready_i |=>
      completion_valid_o && $stable(completion_o) && $stable(completion_tile_o));
endmodule
