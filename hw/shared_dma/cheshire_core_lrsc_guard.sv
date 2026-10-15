// SPDX-License-Identifier: SHL-0.51
module cheshire_core_lrsc_guard #(
  parameter int unsigned AddrWidth = 48,
  parameter int unsigned IdWidth = 2,
  parameter int unsigned UserIdMsb = 1,
  parameter int unsigned UserIdLsb = 0,
  parameter int unsigned MaxTrans = 16,
  parameter logic [63:0] SpmBase = 64'h10000000,
  parameter logic [63:0] SpmUncachedBase = 64'h14000000,
  parameter logic [63:0] SpmRegionMask = 64'h03ffffff,
  parameter type aw_chan_t = logic,
  parameter type w_chan_t = logic,
  parameter type b_chan_t = logic,
  parameter type ar_chan_t = logic,
  parameter type r_chan_t = logic,
  parameter type req_t = logic,
  parameter type rsp_t = logic
) (
  input logic clk_i, rst_ni, test_i,
  input req_t slv_req_i,
  output rsp_t slv_rsp_o,
  output req_t mst_req_o,
  input rsp_t mst_rsp_i
);
  localparam int UserIdWidth = UserIdMsb-UserIdLsb+1;
  localparam int NumHarts = 1 << UserIdWidth;
  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [UserIdWidth-1:0] hart_t;
  logic [NumHarts-1:0] valid_q;
  addr_t [NumHarts-1:0] address_q;
  logic [NumHarts-1:0][2:0] size_q;
  logic [NumHarts-1:0][7:0] len_q;
  hart_t read_hart, write_hart;
  logic deny_sc, aw_locked_q, aw_deny_q;
  logic [0:0] aw_select;
  req_t [1:0] branch_req;
  rsp_t [1:0] branch_rsp;
  rsp_t failed_rsp;

  function automatic addr_t canonical(input addr_t address);
    if ((64'(address) & ~SpmRegionMask) == (SpmUncachedBase & ~SpmRegionMask))
      return addr_t'(SpmBase | (64'(address) & SpmRegionMask));
    return address;
  endfunction

  assign read_hart = hart_t'(slv_req_i.ar.user >> UserIdLsb);
  assign write_hart = hart_t'(slv_req_i.aw.user >> UserIdLsb);
  assign deny_sc = slv_req_i.aw.lock && (!valid_q[write_hart] ||
    canonical(slv_req_i.aw.addr) != address_q[write_hart] ||
    slv_req_i.aw.size != size_q[write_hart] || slv_req_i.aw.len != len_q[write_hart]);
  assign aw_select = aw_locked_q ? aw_deny_q : deny_sc;

  // Eligibility spans all targets; the target-specific adapters track interference.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_q <= '0; address_q <= '0; size_q <= '0; len_q <= '0;
      aw_locked_q <= 0; aw_deny_q <= 0;
    end else begin
      if (slv_req_i.ar_valid && slv_rsp_o.ar_ready && slv_req_i.ar.lock) begin
        valid_q[read_hart] <= 1;
        address_q[read_hart] <= canonical(slv_req_i.ar.addr);
        size_q[read_hart] <= slv_req_i.ar.size;
        len_q[read_hart] <= slv_req_i.ar.len;
      end
      if (slv_req_i.aw_valid && slv_rsp_o.aw_ready && slv_req_i.aw.lock)
        valid_q[write_hart] <= 0;
      if (!slv_req_i.aw_valid || slv_rsp_o.aw_ready) aw_locked_q <= 0;
      else if (!aw_locked_q) begin
        aw_locked_q <= 1;
        aw_deny_q <= deny_sc;
      end
    end
  end

  axi_demux #(
    .AxiIdWidth(IdWidth), .AtopSupport(1), .aw_chan_t(aw_chan_t),
    .w_chan_t(w_chan_t), .b_chan_t(b_chan_t), .ar_chan_t(ar_chan_t),
    .r_chan_t(r_chan_t), .axi_req_t(req_t), .axi_resp_t(rsp_t),
    .NoMstPorts(2), .MaxTrans(MaxTrans), .AxiLookBits(IdWidth),
    .SpillAw(0), .SpillW(0), .SpillB(0), .SpillAr(0), .SpillR(0)
  ) i_sc_route (
    .clk_i, .rst_ni, .test_i, .slv_req_i, .slv_resp_o(slv_rsp_o),
    .slv_aw_select_i(aw_select), .slv_ar_select_i(1'b0),
    .mst_reqs_o(branch_req), .mst_resps_i(branch_rsp)
  );
  assign mst_req_o = branch_req[0];
  assign branch_rsp[0] = mst_rsp_i;
  // OKAY, rather than EXOKAY, is an unsuccessful exclusive write, not an access fault.
  axi_err_slv #(
    .AxiIdWidth(IdWidth), .axi_req_t(req_t), .axi_resp_t(rsp_t),
    .Resp(axi_pkg::RESP_SLVERR), .ATOPs(0), .MaxTrans(MaxTrans)
  ) i_failed_sc (
    .clk_i, .rst_ni, .test_i, .slv_req_i(branch_req[1]), .slv_resp_o(failed_rsp)
  );
  always_comb begin
    branch_rsp[1] = failed_rsp;
    branch_rsp[1].b.resp = axi_pkg::RESP_OKAY;
  end
  assert property (@(posedge clk_i) disable iff(!rst_ni)
    branch_req[1].aw_valid |-> branch_req[1].aw.lock && branch_req[1].aw.atop == 0)
    else $fatal(1, "only unsuccessful SC requests may enter the SC sink");
  initial assert(UserIdMsb >= UserIdLsb && UserIdWidth <= 8);
  assert property (@(posedge clk_i) disable iff(!rst_ni)
    slv_req_i.aw_valid && !slv_rsp_o.aw_ready |=> $stable(aw_select))
    else $fatal(1, "core SC route changed under backpressure");
endmodule
