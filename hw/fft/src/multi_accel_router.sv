module multi_accel_router
  import fft_accel_pkg::*;
#(
  parameter type cva6_to_acc_t = logic,
  parameter type acc_to_cva6_t = logic
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  cva6_to_acc_t  acc_req_i,
  output acc_to_cva6_t  acc_resp_o,

  output cva6_to_acc_t  ara_req_o,
  input  acc_to_cva6_t  ara_resp_i,

  output cva6_to_acc_t  fft_req_o,
  input  acc_to_cva6_t  fft_resp_i
);

  typedef enum logic {OwnerAra, OwnerFft} owner_e;

  logic   fft_sel;
  logic   route_busy;
  owner_e owner_d, owner_q;
  logic   pending_d, pending_q;
  logic   req_accepted;
  logic   routed_req_accepted;
  logic   selected_resp_valid;
  logic   pending_resp_valid;
  logic   pending_resp_fire;
  logic   forward_resp_valid;
  logic   route_req_ready;
  owner_e selected_owner;

  assign fft_sel    = is_fft_namespace(acc_req_i.acc_req.insn);
  assign route_busy = pending_q;
  assign selected_owner = pending_q ? owner_q : (fft_sel ? OwnerFft : OwnerAra);
  assign selected_resp_valid =
      (selected_owner == OwnerFft) ? fft_resp_i.acc_resp.resp_valid :
                                     ara_resp_i.acc_resp.resp_valid;
  assign pending_resp_valid =
      (owner_q == OwnerFft) ? fft_resp_i.acc_resp.resp_valid :
                              ara_resp_i.acc_resp.resp_valid;
  assign pending_resp_fire = pending_q && pending_resp_valid && acc_req_i.acc_req.resp_ready;
  assign route_req_ready =
      route_busy ? 1'b0 :
      fft_sel    ? fft_resp_i.acc_resp.req_ready :
                   ara_resp_i.acc_resp.req_ready;
  assign forward_resp_valid = selected_resp_valid && (pending_q || req_accepted);

  always_comb begin
    ara_req_o = acc_req_i;
    fft_req_o = acc_req_i;

    ara_req_o.acc_req.req_valid = acc_req_i.acc_req.req_valid && !fft_sel && !route_busy;
    fft_req_o.acc_req.req_valid = acc_req_i.acc_req.req_valid &&  fft_sel && !route_busy;

    fft_req_o.acc_mmu_en   = 1'b0;
    fft_req_o.acc_mmu_resp = '0;
  end

  always_comb begin
    acc_resp_o = '0;
    acc_resp_o.acc_mmu_req = ara_resp_i.acc_mmu_req;

    if (selected_owner == OwnerFft) begin
      acc_resp_o.acc_resp.resp_valid = forward_resp_valid;
      acc_resp_o.acc_resp.result     = fft_resp_i.acc_resp.result;
      acc_resp_o.acc_resp.trans_id   = fft_resp_i.acc_resp.trans_id;
      acc_resp_o.acc_resp.exception  = fft_resp_i.acc_resp.exception;
      acc_resp_o.acc_resp.fflags_valid = fft_resp_i.acc_resp.fflags_valid;
      acc_resp_o.acc_resp.fflags       = fft_resp_i.acc_resp.fflags;
    end else begin
      acc_resp_o.acc_resp = ara_resp_i.acc_resp;
      acc_resp_o.acc_resp.resp_valid = forward_resp_valid;
    end

    acc_resp_o.acc_resp.req_ready = route_req_ready;

  end

  assign req_accepted = acc_req_i.acc_req.req_valid && route_req_ready;
  assign routed_req_accepted = req_accepted;

  always_comb begin
    pending_d           = pending_q;
    owner_d             = owner_q;

    if (pending_q) begin
      if (pending_resp_fire) begin
        pending_d = 1'b0;
      end
    end else if (routed_req_accepted && !selected_resp_valid) begin
      pending_d = 1'b1;
      owner_d   = fft_sel ? OwnerFft : OwnerAra;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_q           <= 1'b0;
      owner_q             <= OwnerAra;
    end else begin
      pending_q           <= pending_d;
      owner_q             <= owner_d;
`ifndef SYNTHESIS
      if (routed_req_accepted) begin
        $display("[multi_accel_router] accepted owner=%0d trans=%0d insn=%08x",
                 fft_sel ? OwnerFft : OwnerAra, acc_req_i.acc_req.trans_id,
                 acc_req_i.acc_req.insn);
      end
      if (selected_resp_valid) begin
        $display("[multi_accel_router] selected resp owner=%0d trans=%0d",
                 selected_owner, acc_resp_o.acc_resp.trans_id);
      end
`endif
    end
  end

endmodule
