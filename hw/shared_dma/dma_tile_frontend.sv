// SPDX-License-Identifier: SHL-0.51
module dma_tile_frontend import cheshire_dma_pkg::*; #(
  parameter int unsigned AxiAddrWidth = 32,
  parameter int unsigned AxiDataWidth = 64,
  parameter int unsigned AxiSlvIdWidth = 4,
  parameter int unsigned AxiUserWidth = 1,
  parameter int unsigned CompletionDepth = 4,
  parameter logic [63:0] MemStart = 64'h80000000,
  parameter logic [63:0] MemEnd = 64'h100000000,
  parameter type axi_req_t = logic,
  parameter type axi_rsp_t = logic,
  parameter type job_t = logic
) (
  input logic clk_i, rst_ni, testmode_i,
  input axi_req_t axi_req_i,
  output axi_rsp_t axi_rsp_o,
  output job_t job_o,
  output logic job_valid_o,
  input logic job_ready_i,
  input completion_t completion_i,
  input logic completion_valid_i,
  output logic completion_ready_o,
  input logic tile_active_i,
  output logic irq_o
);
  `include "register_interface/typedef.svh"
  typedef logic [AxiAddrWidth-1:0] addr_t;
  typedef logic [AxiDataWidth-1:0] data_t;
  typedef logic [AxiDataWidth/8-1:0] strb_t;
  `REG_BUS_TYPEDEF_ALL(csr, addr_t, data_t, strb_t)
  csr_req_t req;
  csr_rsp_t rsp;
  localparam int CountWidth = $clog2(CompletionDepth+1);
  logic [CountWidth-1:0] outstanding_q;
  logic [31:0] conf_q, conf_d, last_id_q;
  logic [11:0][31:0] shadow_q, shadow_d;
  logic irq_enable_q, irq_enable_d;
  logic [7:0] submit_status_q;
  logic submit_cmd, pop_cmd, submit_fire, pop_fire, invalid, write_error;
  logic [7:0] submit_error;
  completion_t comp_head;
  logic comp_valid, comp_pop;
  logic [63:0] src_addr, dst_addr;
  logic [31:0] reps;
  logic [127:0] src_end, dst_end, addr_limit;

  axi_to_reg #(
    .ADDR_WIDTH(AxiAddrWidth), .DATA_WIDTH(AxiDataWidth), .ID_WIDTH(AxiSlvIdWidth),
    .USER_WIDTH(AxiUserWidth), .axi_req_t(axi_req_t), .axi_rsp_t(axi_rsp_t),
    .reg_req_t(csr_req_t), .reg_rsp_t(csr_rsp_t)
  ) i_axi_to_reg (
    .clk_i, .rst_ni, .testmode_i, .axi_req_i, .axi_rsp_o,
    .reg_req_o(req), .reg_rsp_i(rsp)
  );
  stream_fifo #(.DEPTH(CompletionDepth), .T(completion_t)) i_completions (
    .clk_i, .rst_ni, .testmode_i, .flush_i(1'b0), .usage_o(),
    .data_i(completion_i), .valid_i(completion_valid_i), .ready_o(completion_ready_o),
    .data_o(comp_head), .valid_o(comp_valid), .ready_i(comp_pop)
  );

  // 128-bit arithmetic prevents both 32-bit stride-product and 64-bit address overflow.
  assign src_addr = {shadow_q[3],shadow_q[2]};
  assign dst_addr = {shadow_q[1],shadow_q[0]};
  assign reps = conf_q[10] ? shadow_q[10] : 32'd1;
  assign src_end = 128'(src_addr) + 128'(reps-1) * 128'(shadow_q[8]) +
                   128'(shadow_q[4]);
  assign dst_end = 128'(dst_addr) + 128'(reps-1) * 128'(shadow_q[6]) +
                   128'(shadow_q[4]);
  assign addr_limit = 128'd1 << AxiAddrWidth;
  assign invalid = shadow_q[4] == 0 || shadow_q[5] != 0 || reps == 0 ||
    (conf_q[10] && (shadow_q[7] != 0 || shadow_q[9] != 0 || shadow_q[11] != 0)) ||
    src_addr < MemStart || dst_addr < MemStart || src_end > 128'(MemEnd) ||
    dst_end > 128'(MemEnd) || src_end > addr_limit || dst_end > addr_limit ||
    (128'(src_addr) < dst_end && 128'(dst_addr) < src_end) || conf_q[31:11] != 0;

  always_comb begin
    job_o = '0;
    job_o.job_id = last_id_q + 32'd1;
    job_o.nd_req.burst_req.src_addr = addr_t'(src_addr);
    job_o.nd_req.burst_req.dst_addr = addr_t'(dst_addr);
    job_o.nd_req.burst_req.length = shadow_q[4];
    job_o.nd_req.burst_req.opt.src_protocol = idma_pkg::AXI;
    job_o.nd_req.burst_req.opt.dst_protocol = idma_pkg::AXI;
    job_o.nd_req.burst_req.opt.src.burst = axi_pkg::BURST_INCR;
    job_o.nd_req.burst_req.opt.dst.burst = axi_pkg::BURST_INCR;
    job_o.nd_req.burst_req.opt.src.cache = axi_pkg::CACHE_MODIFIABLE;
    job_o.nd_req.burst_req.opt.dst.cache = axi_pkg::CACHE_MODIFIABLE;
    job_o.nd_req.burst_req.opt.beo.decouple_aw = conf_q[0];
    job_o.nd_req.burst_req.opt.beo.decouple_rw = conf_q[1];
    job_o.nd_req.burst_req.opt.beo.src_reduce_len = conf_q[2];
    job_o.nd_req.burst_req.opt.beo.dst_reduce_len = conf_q[3];
    job_o.nd_req.burst_req.opt.beo.src_max_llen = conf_q[6:4];
    job_o.nd_req.burst_req.opt.beo.dst_max_llen = conf_q[9:7];
    job_o.nd_req.burst_req.opt.last = 1'b1;
    job_o.nd_req.d_req[0].reps = reps;
    job_o.nd_req.d_req[0].src_strides = shadow_q[8];
    job_o.nd_req.d_req[0].dst_strides = shadow_q[6];
  end

  function automatic logic [31:0] read_word(input int unsigned offset);
    logic [31:0] value;
    value = '0;
    if (offset >= DstLo && offset <= 'h0fc) return shadow_q[(offset-DstLo)/4];
    case (offset)
      Conf: value = conf_q;
      Status: begin value[0] = tile_active_i; value[1] = outstanding_q != 0; end
      QueueStatus: begin
        value[0] = job_ready_i && int'(outstanding_q) < CompletionDepth;
        value[15:8] = 8'(outstanding_q);
        value[23:16] = 8'(CompletionDepth-outstanding_q);
      end
      CompValid: value[0] = comp_valid;
      CompJobId: value = comp_valid ? comp_head.job_id : '0;
      CompStatus: if (comp_valid) begin
        value[7:0] = comp_head.error_code;
        value[31:16] = comp_head.engine_id;
      end
      IrqEnable: value[0] = irq_enable_q;
      LastJobId: value = last_id_q;
      SubmitStatus: value[7:0] = submit_status_q;
      default: ;
    endcase
    return value;
  endfunction

  // AXI narrow accesses use their natural byte lanes, including the high word of 64-bit beats.
  always_comb begin
    int unsigned offset;
    logic [31:0] word_data;
    logic [3:0] mask;
    conf_d = conf_q;
    shadow_d = shadow_q;
    irq_enable_d = irq_enable_q;
    submit_cmd = 0; pop_cmd = 0; write_error = 0;
    rsp = '0;
    rsp.ready = 1;
    for (int lane = 0; lane < AxiDataWidth/32; lane++) begin
      offset = (int'(req.addr[11:0]) & ~(AxiDataWidth/8-1)) + lane*4;
      rsp.rdata[lane*32+:32] = read_word(offset);
      word_data = req.wdata[lane*32+:32];
      mask = req.wstrb[lane*4+:4];
      if (req.valid && req.write && |mask) begin
        if (offset >= DstLo && offset <= 'h0fc) begin
          for (int b=0;b<4;b++) if (mask[b])
            shadow_d[(offset-DstLo)/4][b*8+:8] = word_data[b*8+:8];
        end else case (offset)
          Conf: for (int b=0;b<4;b++) if (mask[b]) conf_d[b*8+:8]=word_data[b*8+:8];
          Submit: submit_cmd = mask[0] && word_data[0];
          CompPop: pop_cmd = mask[0] && word_data[0];
          IrqEnable: if (mask[0]) irq_enable_d = word_data[0];
          default: write_error = 1;
        endcase
      end
    end
    submit_error = invalid ? InvalidJob :
      ((!job_ready_i || int'(outstanding_q) == CompletionDepth) ? NoCapacity : Success);
    rsp.error = write_error || (submit_cmd && submit_error != Success);
  end
  assign submit_fire = req.valid && req.write && submit_cmd && !rsp.error;
  assign job_valid_o = submit_fire;
  assign comp_pop = req.valid && req.write && pop_cmd && !rsp.error;
  assign pop_fire = comp_pop && comp_valid;
  assign irq_o = irq_enable_q && comp_valid;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      conf_q <= '0; shadow_q <= '0; irq_enable_q <= 0;
      last_id_q <= '0; outstanding_q <= '0; submit_status_q <= Success;
    end else begin
      if (req.valid && req.write && !rsp.error) begin
        conf_q <= conf_d; shadow_q <= shadow_d; irq_enable_q <= irq_enable_d;
      end
      if (req.valid && req.write && submit_cmd)
        submit_status_q <= write_error ? InvalidJob : submit_error;
      if (submit_fire) last_id_q <= last_id_q + 32'd1;
      case ({submit_fire,pop_fire})
        2'b10: outstanding_q <= outstanding_q + 1'b1;
        2'b01: outstanding_q <= outstanding_q - 1'b1;
        default: ;
      endcase
    end
  end
  initial begin
    assert (AxiAddrWidth >= 32 && AxiAddrWidth <= 64);
    assert (AxiDataWidth >= 32 && AxiDataWidth <= 128 &&
            (AxiDataWidth & (AxiDataWidth-1)) == 0);
    assert (CompletionDepth > 0 && CompletionDepth <= 255);
    assert (MemStart < MemEnd && MemStart % 64'(AxiDataWidth/8) == 0 &&
            MemEnd % 64'(AxiDataWidth/8) == 0);
  end
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    int'(outstanding_q) <= CompletionDepth);
endmodule
