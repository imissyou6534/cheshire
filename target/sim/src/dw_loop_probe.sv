// SPDX-License-Identifier: SHL-0.51
`include "axi/typedef.svh"
package dw_loop_probe_pkg;
  typedef logic [47:0] addr_t;
  typedef logic [6:0] id_t;
  typedef logic [1:0] user_t;
  `AXI_TYPEDEF_ALL(wide, addr_t, id_t, logic [127:0], logic [15:0], user_t)
  `AXI_TYPEDEF_ALL(narrow, addr_t, id_t, logic [63:0], logic [7:0], user_t)
  typedef struct packed {
    addr_t addr;
    logic write;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic valid;
  } reg_req_t;
  typedef struct packed {
    logic [31:0] rdata;
    logic error;
    logic ready;
  } reg_rsp_t;
endpackage

module dw_loop_probe import dw_loop_probe_pkg::*; #(
  parameter bit DebugMode = 0,
  parameter bit CutBoundary = 0
) (
  input logic clk_i, rst_ni,
  input wide_req_t req_i,
  output wide_resp_t resp_o,
  output reg_req_t reg_req_o
);
  narrow_req_t converted_req, bridge_req;
  narrow_resp_t converted_rsp, bridge_rsp;
  cheshire_axi_dw_bridge #(
    .SlvDataWidth(128), .MstDataWidth(64), .AddrWidth(48), .IdWidth(7),
    .UserWidth(2), .MaxReads(DebugMode ? 4 : 8),
    .slv_req_t(wide_req_t), .slv_rsp_t(wide_resp_t),
    .mst_req_t(narrow_req_t), .mst_rsp_t(narrow_resp_t)
  ) i_converter (
    .clk_i, .rst_ni, .slv_req_i(req_i), .slv_rsp_o(resp_o),
    .mst_req_o(converted_req), .mst_rsp_i(converted_rsp)
  );
  axi_cut #(
    .Bypass(!CutBoundary), .aw_chan_t(narrow_aw_chan_t), .w_chan_t(narrow_w_chan_t),
    .b_chan_t(narrow_b_chan_t), .ar_chan_t(narrow_ar_chan_t), .r_chan_t(narrow_r_chan_t),
    .axi_req_t(narrow_req_t), .axi_resp_t(narrow_resp_t)
  ) i_boundary (
    .clk_i, .rst_ni, .slv_req_i(converted_req), .slv_resp_o(converted_rsp),
    .mst_req_o(bridge_req), .mst_resp_i(bridge_rsp)
  );
  if (DebugMode) begin : gen_debug
    logic mem_req, mem_rvalid;
    always_ff @(posedge clk_i or negedge rst_ni)
      if (!rst_ni) mem_rvalid <= 0;
      else mem_rvalid <= mem_req;
    axi_to_mem_interleaved #(
      .axi_req_t(narrow_req_t), .axi_resp_t(narrow_resp_t),
      .AddrWidth(48), .DataWidth(64), .IdWidth(7), .NumBanks(1), .BufDepth(4)
    ) i_bridge (
      .clk_i, .rst_ni, .test_i(1'b0), .busy_o(),
      .axi_req_i(bridge_req), .axi_resp_o(bridge_rsp), .mem_req_o(mem_req),
      .mem_gnt_i(mem_req), .mem_addr_o(), .mem_wdata_o(), .mem_strb_o(),
      .mem_atop_o(), .mem_we_o(), .mem_rvalid_i(mem_rvalid), .mem_rdata_i('0)
    );
    assign reg_req_o = '0;
  end else begin : gen_peripheral
    axi_to_reg_v2 #(
      .AxiAddrWidth(48), .AxiDataWidth(64), .AxiIdWidth(7), .AxiUserWidth(2),
      .RegDataWidth(32), .CutMemReqs(1), .axi_req_t(narrow_req_t),
      .axi_rsp_t(narrow_resp_t), .reg_req_t(reg_req_t), .reg_rsp_t(reg_rsp_t)
    ) i_bridge (
      .clk_i, .rst_ni, .axi_req_i(bridge_req), .axi_rsp_o(bridge_rsp),
      .reg_req_o, .reg_rsp_i('{rdata:'0,error:1'b0,ready:1'b1}), .reg_id_o(), .busy_o()
    );
  end
endmodule
