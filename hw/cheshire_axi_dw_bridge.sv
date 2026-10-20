// SPDX-License-Identifier: SHL-0.51
module cheshire_axi_dw_bridge #(
  parameter int unsigned SlvDataWidth = 64,
  parameter int unsigned MstDataWidth = 128,
  parameter int unsigned AddrWidth = 48,
  parameter int unsigned IdWidth = 2,
  parameter int unsigned UserWidth = 2,
  parameter int unsigned MaxReads = 8,
  parameter type slv_req_t = logic,
  parameter type slv_rsp_t = logic,
  parameter type mst_req_t = logic,
  parameter type mst_rsp_t = logic
) (
  input logic clk_i, rst_ni,
  input slv_req_t slv_req_i,
  output slv_rsp_t slv_rsp_o,
  output mst_req_t mst_req_o,
  input mst_rsp_t mst_rsp_i
);
  `include "axi/typedef.svh"
  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [IdWidth-1:0] id_t;
  typedef logic [UserWidth-1:0] user_t;
  `AXI_TYPEDEF_ALL(s, addr_t, id_t, logic [SlvDataWidth-1:0],
    logic [SlvDataWidth/8-1:0], user_t)
  `AXI_TYPEDEF_ALL(m, addr_t, id_t, logic [MstDataWidth-1:0],
    logic [MstDataWidth/8-1:0], user_t)
  axi_dw_converter #(
    .AxiMaxReads(MaxReads), .AxiSlvPortDataWidth(SlvDataWidth),
    .AxiMstPortDataWidth(MstDataWidth), .AxiAddrWidth(AddrWidth), .AxiIdWidth(IdWidth),
    .aw_chan_t(s_aw_chan_t), .b_chan_t(s_b_chan_t), .ar_chan_t(s_ar_chan_t),
    .slv_w_chan_t(s_w_chan_t), .slv_r_chan_t(s_r_chan_t),
    .mst_w_chan_t(m_w_chan_t), .mst_r_chan_t(m_r_chan_t),
    .axi_slv_req_t(slv_req_t), .axi_slv_resp_t(slv_rsp_t),
    .axi_mst_req_t(mst_req_t), .axi_mst_resp_t(mst_rsp_t)
  ) i_converter (
    .clk_i, .rst_ni, .slv_req_i, .slv_resp_o(slv_rsp_o),
    .mst_req_o, .mst_resp_i(mst_rsp_i)
  );
  initial begin
    assert(SlvDataWidth >= 8 && (SlvDataWidth & (SlvDataWidth-1)) == 0);
    assert(MstDataWidth >= 8 && (MstDataWidth & (MstDataWidth-1)) == 0);
    assert($bits(slv_req_i.w.data) == SlvDataWidth &&
      $bits(mst_req_o.w.data) == MstDataWidth);
  end
endmodule
