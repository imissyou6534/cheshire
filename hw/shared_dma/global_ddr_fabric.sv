// SPDX-License-Identifier: SHL-0.51
module global_ddr_fabric #(
  parameter int unsigned NumMasters = 6,
  parameter int unsigned AxiAddrWidth = 32,
  parameter int unsigned AxiDataWidth = 64,
  parameter int unsigned AxiIdWidth = 4,
  parameter int unsigned AxiUserWidth = 1,
  parameter int unsigned AxiUserAmoMsb = AxiUserWidth-1,
  parameter int unsigned AxiUserAmoLsb = 0,
  parameter int unsigned MaxTransactions = 32,
  parameter logic [63:0] MemStart = 64'h80000000,
  parameter logic [63:0] MemEnd = 64'h100000000,
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic,
  parameter type ddr_req_t = logic,
  parameter type ddr_rsp_t = logic
) (
  input logic clk_i, rst_ni, testmode_i,
  input axi_req_t [NumMasters-1:0] masters_req_i,
  output axi_rsp_t [NumMasters-1:0] masters_rsp_o,
  output ddr_req_t ddr_req_o,
  input ddr_rsp_t ddr_rsp_i
);
  `include "axi/typedef.svh"
  `include "axi/assign.svh"
  localparam int DdrIdWidth = AxiIdWidth + $clog2(NumMasters);
  typedef logic [AxiAddrWidth-1:0] addr_t;
  typedef logic [AxiDataWidth-1:0] data_t;
  typedef logic [AxiDataWidth/8-1:0] strb_t;
  typedef logic [AxiIdWidth-1:0] id_t;
  typedef logic [DdrIdWidth-1:0] ddr_id_t;
  typedef logic [AxiUserWidth-1:0] user_t;
  localparam int SourceWidth = (NumMasters>1) ? $clog2(NumMasters) : 1;
  localparam int HartWidth = AxiUserAmoMsb-AxiUserAmoLsb+1;
  localparam int AtomUserWidth = AxiUserWidth+SourceWidth+HartWidth;
  typedef logic [SourceWidth-1:0] source_t;
  typedef logic [HartWidth-1:0] hart_t;
  typedef logic [AtomUserWidth-1:0] atom_user_t;
  `AXI_TYPEDEF_ALL(slv, addr_t, id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(mst, addr_t, ddr_id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(atom, addr_t, ddr_id_t, data_t, strb_t, atom_user_t)
  // Keep 64-bit decode rules: an exclusive 4-GiB end cannot fit in a 32-bit addr_t.
  localparam axi_pkg::xbar_rule_64_t [0:0] Map = '{'{idx:0,start_addr:MemStart,end_addr:MemEnd}};
  localparam axi_pkg::xbar_cfg_t XbarCfg = '{
    NoSlvPorts:NumMasters, NoMstPorts:1, MaxMstTrans:MaxTransactions,
    MaxSlvTrans:MaxTransactions, FallThrough:0, LatencyMode:axi_pkg::CUT_ALL_PORTS,
    PipelineStages:0, AxiIdWidthSlvPorts:AxiIdWidth, AxiIdUsedSlvPorts:AxiIdWidth,
    UniqueIds:0, AxiAddrWidth:AxiAddrWidth, AxiDataWidth:AxiDataWidth, NoAddrRules:1
  };
  ddr_req_t [0:0] req;
  ddr_rsp_t [0:0] rsp;
  atom_req_t atom_slv_req, atom_mst_req;
  atom_resp_t atom_slv_rsp, atom_mst_rsp;
  // Reservation keys combine trusted physical master index with the local hart user
  // field. AXI transaction IDs alone need not match between a CPU's LR and SC.
  always_comb begin
    `AXI_SET_REQ_STRUCT(atom_slv_req, req[0])
    atom_slv_req.aw.user={source_t'(req[0].aw.id >> AxiIdWidth),
      hart_t'(user_t'(req[0].aw.user) >> AxiUserAmoLsb),req[0].aw.user};
    atom_slv_req.ar.user={source_t'(req[0].ar.id >> AxiIdWidth),
      hart_t'(user_t'(req[0].ar.user) >> AxiUserAmoLsb),req[0].ar.user};
    `AXI_SET_RESP_STRUCT(rsp[0], atom_slv_rsp)
    rsp[0].r.user=user_t'(atom_slv_rsp.r.user);
    rsp[0].b.user=user_t'(atom_slv_rsp.b.user);
    `AXI_SET_REQ_STRUCT(ddr_req_o, atom_mst_req)
    ddr_req_o.aw.user=user_t'(atom_mst_req.aw.user);
    ddr_req_o.ar.user=user_t'(atom_mst_req.ar.user);
    ddr_req_o.w.user=user_t'(atom_mst_req.w.user);
    `AXI_SET_RESP_STRUCT(atom_mst_rsp, ddr_rsp_i)
  end
  axi_riscv_atomics_structs #(
    .AxiAddrWidth(AxiAddrWidth), .AxiDataWidth(AxiDataWidth), .AxiIdWidth(DdrIdWidth),
    .AxiUserWidth(AtomUserWidth), .AxiMaxReadTxns(MaxTransactions),
    .AxiMaxWriteTxns(MaxTransactions), .AxiUserAsId(1),
    .AxiUserIdMsb(AtomUserWidth-1), .AxiUserIdLsb(AxiUserWidth),
    .RiscvWordWidth(64), .NAxiCuts(1), .axi_req_t(atom_req_t), .axi_rsp_t(atom_resp_t)
  ) i_shared_atomics (
    .clk_i, .rst_ni, .axi_slv_req_i(atom_slv_req), .axi_slv_rsp_o(atom_slv_rsp),
    .axi_mst_req_o(atom_mst_req), .axi_mst_rsp_i(atom_mst_rsp)
  );
  axi_xbar #(
    .Cfg(XbarCfg), .ATOPs(1), .slv_aw_chan_t(slv_aw_chan_t), .mst_aw_chan_t(mst_aw_chan_t),
    .w_chan_t(slv_w_chan_t), .slv_b_chan_t(slv_b_chan_t), .mst_b_chan_t(mst_b_chan_t),
    .slv_ar_chan_t(slv_ar_chan_t), .mst_ar_chan_t(mst_ar_chan_t), .slv_r_chan_t(slv_r_chan_t),
    .mst_r_chan_t(mst_r_chan_t), .slv_req_t(axi_req_t), .slv_resp_t(axi_rsp_t),
    .mst_req_t(ddr_req_t), .mst_resp_t(ddr_rsp_t), .rule_t(axi_pkg::xbar_rule_64_t)
  ) i_xbar (
    .clk_i, .rst_ni, .test_i(testmode_i), .slv_ports_req_i(masters_req_i),
    .slv_ports_resp_o(masters_rsp_o), .mst_ports_req_o(req), .mst_ports_resp_i(rsp),
    .addr_map_i(Map), .en_default_mst_port_i('0), .default_mst_port_i('0)
  );
  initial begin
    assert(NumMasters > 0);
    assert(AxiUserAmoMsb >= AxiUserAmoLsb && AxiUserAmoMsb < AxiUserWidth);
    assert($bits(ddr_req_o.aw.id)==DdrIdWidth && $bits(ddr_rsp_i.r.id)==DdrIdWidth)
      else $fatal(1,"DDR ID width must be AxiIdWidth + clog2(NumMasters)");
    assert($bits(masters_req_i[0].aw.id)==AxiIdWidth);
    assert($bits(masters_req_i[0])==$bits(slv_req_t) &&
           $bits(ddr_req_o)==$bits(mst_req_t));
  end
endmodule
