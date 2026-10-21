// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`define VID_ARA tb_multitile.dut.gen_tiles[0].i_soc.gen_cva6_cores[0].gen_ara.i_ara
module tb_ara_vid_monitor #(parameter int NrLanes = 2);
  import ara_pkg::*;
  integer vid_requests = 0;
  initial assert (NrLanes == `VID_ARA.NrLanes)
    else $fatal(1, "VID monitor lane count does not match the DUT");
  always @(posedge tb_multitile.clk) if (tb_multitile.rst_n) begin
    if (`VID_ARA.ara_req_valid && `VID_ARA.ara_req_ready && `VID_ARA.ara_req.op == VID)
      vid_requests++;
    if (`VID_ARA.i_sequencer.accepted_insn && `VID_ARA.ara_req.op == VID &&
        `VID_ARA.i_sequencer.insn_queue_cnt_up[VFU_Alu])
      $fatal(1, "VID incorrectly occupies the global ALU instruction queue");
  end
  for (genvar lane = 0; lane < NrLanes; lane++) begin : gen_check
    `define VID_VALU `VID_ARA.gen_lanes[lane].i_lane.i_vfus.i_valu
    always @(posedge tb_multitile.clk) if (tb_multitile.rst_n) begin
      if (`VID_VALU.vfu_operation_valid_i && `VID_VALU.vfu_operation_i.op == VID &&
          `VID_VALU.vinsn_queue_d.accept_pnt != `VID_VALU.vinsn_queue_q.accept_pnt)
        $fatal(1, "VID incorrectly accepted into lane %0d ALU instruction queue", lane);
      if (`VID_VALU.vinsn_issue_valid && `VID_VALU.vinsn_issue_q.op == VID)
        $fatal(1, "VID incorrectly entered lane %0d ALU instruction queue", lane);
      if (`VID_VALU.valu_valid && `VID_VALU.vinsn_issue_q.op == VID)
        $fatal(1, "VID incorrectly generated an ALU result in lane %0d", lane);
    end
    `undef VID_VALU
  end
  final begin
    $display("VID_MONITOR requests=%0d lanes=%0d alu_queue=%0d", vid_requests,
      `VID_ARA.NrLanes, `VID_ARA.i_sequencer.insn_queue_cnt_q[VFU_Alu]);
  end
endmodule
`undef VID_ARA
