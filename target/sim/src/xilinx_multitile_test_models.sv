// SPDX-License-Identifier: SHL-0.51
// Functional board models only; real IP is checked separately by Vivado.
`timescale 1ns/1ps
`include "phy_definitions.svh"
`include "axi/typedef.svh"
module IBUFDS #(parameter IBUF_LOW_PWR = "FALSE") (
  input wire I, IB, output wire O
);
  assign O = I;
endmodule

module clkwiz (
  input logic clk_in1, reset,
  output logic locked = 0,
  output wire clk_50, clk_48, clk_20, clk_10
);
  int unsigned divider = 0, lock_count = 0;
  always @(posedge clk_in1) begin
    if (reset) begin divider <= 0; lock_count <= 0; locked <= 0; end
    else begin
      divider <= divider == 4 ? 0 : divider+1;
      if (lock_count < 8) lock_count <= lock_count+1;
      else locked <= 1;
    end
  end
  assign clk_50 = divider < 2;
  assign clk_48 = 0;
  assign clk_20 = 0;
  assign clk_10 = 0;
endmodule

module vio (
  input wire clk,
  output wire probe_out0,
  output wire [1:0] probe_out1,
  output wire probe_out2
);
  assign probe_out0 = 0;
  // Match the existing IP's flash-boot setting: the new top must ignore it.
  assign probe_out1 = 2;
  assign probe_out2 = 1;
endmodule

module ddr4 (
  input logic sys_rst, c0_sys_clk_i, c0_ddr4_aresetn,
  output wire c0_ddr4_ui_clk,
  output logic c0_ddr4_ui_clk_sync_rst = 1,
  input logic [7:0] c0_ddr4_s_axi_awid,
  input logic [30:0] c0_ddr4_s_axi_awaddr,
  input logic [7:0] c0_ddr4_s_axi_awlen,
  input logic [2:0] c0_ddr4_s_axi_awsize,
  input logic [1:0] c0_ddr4_s_axi_awburst,
  input logic c0_ddr4_s_axi_awlock,
  input logic [3:0] c0_ddr4_s_axi_awcache,
  input logic [2:0] c0_ddr4_s_axi_awprot,
  input logic [3:0] c0_ddr4_s_axi_awqos,
  input logic c0_ddr4_s_axi_awvalid,
  output wire c0_ddr4_s_axi_awready,
  input logic [511:0] c0_ddr4_s_axi_wdata,
  input logic [63:0] c0_ddr4_s_axi_wstrb,
  input logic c0_ddr4_s_axi_wlast, c0_ddr4_s_axi_wvalid,
  output wire c0_ddr4_s_axi_wready,
  input logic c0_ddr4_s_axi_bready,
  output wire [7:0] c0_ddr4_s_axi_bid,
  output wire [1:0] c0_ddr4_s_axi_bresp,
  output wire c0_ddr4_s_axi_bvalid,
  input logic [7:0] c0_ddr4_s_axi_arid,
  input logic [30:0] c0_ddr4_s_axi_araddr,
  input logic [7:0] c0_ddr4_s_axi_arlen,
  input logic [2:0] c0_ddr4_s_axi_arsize,
  input logic [1:0] c0_ddr4_s_axi_arburst,
  input logic c0_ddr4_s_axi_arlock,
  input logic [3:0] c0_ddr4_s_axi_arcache,
  input logic [2:0] c0_ddr4_s_axi_arprot,
  input logic [3:0] c0_ddr4_s_axi_arqos,
  input logic c0_ddr4_s_axi_arvalid,
  output wire c0_ddr4_s_axi_arready,
  input logic c0_ddr4_s_axi_rready,
  output wire [7:0] c0_ddr4_s_axi_rid,
  output wire [511:0] c0_ddr4_s_axi_rdata,
  output wire [1:0] c0_ddr4_s_axi_rresp,
  output wire c0_ddr4_s_axi_rlast, c0_ddr4_s_axi_rvalid,
  output wire c0_init_calib_complete, addn_ui_clkout1, dbg_clk,
  output wire [511:0] dbg_bus,
  output wire c0_ddr4_reset_n,
  output wire [0:0] c0_ddr4_ck_t, c0_ddr4_ck_c,
  output wire c0_ddr4_act_n,
  output wire [16:0] c0_ddr4_adr,
  output wire [1:0] c0_ddr4_ba,
  output wire [0:0] c0_ddr4_bg, c0_ddr4_cke, c0_ddr4_odt, c0_ddr4_cs_n,
  inout wire [7:0] c0_ddr4_dm_dbi_n,
  inout wire [63:0] c0_ddr4_dq,
  inout wire [7:0] c0_ddr4_dqs_c, c0_ddr4_dqs_t
);
  `AXI_TYPEDEF_ALL(mig, logic [30:0], logic [7:0], logic [511:0], logic [63:0], logic)
  mig_req_t req;
  mig_resp_t rsp;
  int unsigned startup = 0;
  assign c0_ddr4_ui_clk = c0_sys_clk_i;
  always @(posedge c0_sys_clk_i) begin
    if (sys_rst) begin startup <= 0; c0_ddr4_ui_clk_sync_rst <= 1; end
    else if (startup < 32) startup <= startup+1;
    else c0_ddr4_ui_clk_sync_rst <= 0;
  end
  always_comb begin
    req = '0;
    req.aw.id = c0_ddr4_s_axi_awid;
    req.aw.addr = c0_ddr4_s_axi_awaddr;
    req.aw.len = c0_ddr4_s_axi_awlen;
    req.aw.size = c0_ddr4_s_axi_awsize;
    req.aw.burst = c0_ddr4_s_axi_awburst;
    req.aw.lock = c0_ddr4_s_axi_awlock;
    req.aw.cache = c0_ddr4_s_axi_awcache;
    req.aw.prot = c0_ddr4_s_axi_awprot;
    req.aw.qos = c0_ddr4_s_axi_awqos;
    req.aw_valid = c0_ddr4_s_axi_awvalid;
    req.w.data = c0_ddr4_s_axi_wdata;
    req.w.strb = c0_ddr4_s_axi_wstrb;
    req.w.last = c0_ddr4_s_axi_wlast;
    req.w_valid = c0_ddr4_s_axi_wvalid;
    req.b_ready = c0_ddr4_s_axi_bready;
    req.ar.id = c0_ddr4_s_axi_arid;
    req.ar.addr = c0_ddr4_s_axi_araddr;
    req.ar.len = c0_ddr4_s_axi_arlen;
    req.ar.size = c0_ddr4_s_axi_arsize;
    req.ar.burst = c0_ddr4_s_axi_arburst;
    req.ar.lock = c0_ddr4_s_axi_arlock;
    req.ar.cache = c0_ddr4_s_axi_arcache;
    req.ar.prot = c0_ddr4_s_axi_arprot;
    req.ar.qos = c0_ddr4_s_axi_arqos;
    req.ar_valid = c0_ddr4_s_axi_arvalid;
    req.r_ready = c0_ddr4_s_axi_rready;
  end
  assign c0_ddr4_s_axi_awready = rsp.aw_ready;
  assign c0_ddr4_s_axi_wready = rsp.w_ready;
  assign c0_ddr4_s_axi_bid = rsp.b.id;
  assign c0_ddr4_s_axi_bresp = rsp.b.resp;
  assign c0_ddr4_s_axi_bvalid = rsp.b_valid;
  assign c0_ddr4_s_axi_arready = rsp.ar_ready;
  assign c0_ddr4_s_axi_rid = rsp.r.id;
  assign c0_ddr4_s_axi_rdata = rsp.r.data;
  assign c0_ddr4_s_axi_rresp = rsp.r.resp;
  assign c0_ddr4_s_axi_rlast = rsp.r.last;
  assign c0_ddr4_s_axi_rvalid = rsp.r_valid;
  axi_sim_mem #(
    .AddrWidth(31), .DataWidth(512), .IdWidth(8), .UserWidth(1),
    .axi_req_t(mig_req_t), .axi_rsp_t(mig_resp_t),
    .UninitializedData("zeros"), .ApplDelay(1ns), .AcqDelay(2ns)
  ) memory (
    .clk_i(c0_ddr4_ui_clk), .rst_ni(c0_ddr4_aresetn && !c0_ddr4_ui_clk_sync_rst),
    .axi_req_i(req), .axi_rsp_o(rsp),
    .mon_w_valid_o(), .mon_w_addr_o(), .mon_w_data_o(), .mon_w_id_o(), .mon_w_user_o(),
    .mon_w_beat_count_o(), .mon_w_last_o(), .mon_r_valid_o(), .mon_r_addr_o(),
    .mon_r_data_o(), .mon_r_id_o(), .mon_r_user_o(), .mon_r_beat_count_o(), .mon_r_last_o()
  );
  assign c0_init_calib_complete = !c0_ddr4_ui_clk_sync_rst;
  assign addn_ui_clkout1 = c0_ddr4_ui_clk;
  assign dbg_clk = c0_ddr4_ui_clk;
  assign dbg_bus = 0;
  assign c0_ddr4_reset_n = !sys_rst;
  assign c0_ddr4_ck_t = c0_sys_clk_i;
  assign c0_ddr4_ck_c = !c0_sys_clk_i;
  assign c0_ddr4_act_n = 1;
  assign c0_ddr4_adr = 0;
  assign c0_ddr4_ba = 0;
  assign c0_ddr4_bg = 0;
  assign c0_ddr4_cke = 0;
  assign c0_ddr4_odt = 0;
  assign c0_ddr4_cs_n = '1;
  assign c0_ddr4_dm_dbi_n = 'z;
  assign c0_ddr4_dq = 'z;
  assign c0_ddr4_dqs_c = 'z;
  assign c0_ddr4_dqs_t = 'z;
endmodule
